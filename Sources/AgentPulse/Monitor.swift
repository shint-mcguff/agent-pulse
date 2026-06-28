import Foundation
import Observation

@Observable
@MainActor
final class AgentMonitor {
    var agents: [AgentInfo] = []
    var lastUpdated: Date? = nil
    var isLoading = false
    var usingDemoData = false

    private var timer: Timer?
    private let launchAgentsDir: String
    private let labelPrefix = "com.claude."
    private let hermesDir: String
    private let homePath: String

    init() {
        homePath = FileManager.default.homeDirectoryForCurrentUser.path()
        launchAgentsDir = "\(homePath)/Library/LaunchAgents"
        hermesDir = "\(homePath)/.hermes"
    }

    func start() {
        loadAll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadAll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        loadAll()
    }

    func triggerLaunchdAgent(label: String) {
        guard label.hasPrefix(labelPrefix),
              label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["start", label]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.loadAll()
        }
    }

    // MARK: - Combined loader

    private func loadAll() {
        isLoading = true
        defer { isLoading = false }

        var result: [AgentInfo] = []
        result.append(contentsOf: loadLaunchdAgents())
        result.append(contentsOf: loadHermesAgents())

        usingDemoData = result.isEmpty

        result.sort { a, b in
            let order: [AgentRunStatus] = [.running, .error, .success, .idle]
            let ai = order.firstIndex(of: a.status) ?? 99
            let bi = order.firstIndex(of: b.status) ?? 99
            if ai != bi { return ai < bi }
            return (a.lastRun ?? .distantPast) > (b.lastRun ?? .distantPast)
        }

        agents = result
        lastUpdated = Date()
    }

    // MARK: - Launchd agents

    private func loadLaunchdAgents() -> [AgentInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: launchAgentsDir) else { return [] }

        let plists = files.filter { $0.hasPrefix(labelPrefix) && $0.hasSuffix(".plist") }
        return plists.compactMap { parseLaunchdAgent(plistPath: "\(launchAgentsDir)/\($0)") }
    }

    private func parseLaunchdAgent(plistPath: String) -> AgentInfo? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else {
            return nil
        }

        let displayName = label
            .replacingOccurrences(of: labelPrefix, with: "")
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        let schedule = formatLaunchdSchedule(plist)
        let logPath = plist["StandardOutPath"] as? String
        let project = plist["WorkingDirectory"] as? String
        let prompt = extractLaunchdPrompt(plist)

        let (pid, exitStatus) = queryLaunchctl(label: label)
        let (lastRun, lastError, duration) = parseLogFile(path: logPath)

        let status: AgentRunStatus
        if pid != nil {
            status = .running
        } else if exitStatus != nil && exitStatus != 0 {
            status = .error
        } else if lastRun != nil {
            status = .success
        } else {
            status = .idle
        }

        let nextRun = computeLaunchdNextRun(plist, after: lastRun ?? Date())

        return AgentInfo(
            id: label,
            name: displayName,
            source: .launchd,
            type: pid != nil ? .session : .schedule,
            status: status,
            schedule: schedule,
            lastRun: lastRun,
            nextRun: nextRun,
            project: project?.replacingOccurrences(of: homePath, with: "~"),
            prompt: prompt,
            duration: duration,
            error: lastError
        )
    }

    private func formatLaunchdSchedule(_ plist: [String: Any]) -> String? {
        if let interval = plist["StartInterval"] as? Int {
            if interval < 3600 { return "Every \(interval / 60)m" }
            return "Every \(interval / 3600)h"
        }
        if let cal = plist["StartCalendarInterval"] as? [String: Any] {
            let h = cal["Hour"] as? Int
            let m = cal["Minute"] as? Int
            let dow = cal["Weekday"] as? Int
            let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let time = String(format: "%02d:%02d", h ?? 0, m ?? 0)
            if let dow, dow < 7 { return "\(days[dow]) \(time)" }
            return "Daily \(time)"
        }
        return nil
    }

    private func extractLaunchdPrompt(_ plist: [String: Any]) -> String? {
        guard let args = plist["ProgramArguments"] as? [String] else { return nil }
        if let script = args.last {
            let name = (script as NSString).lastPathComponent
            return name
                .replacingOccurrences(of: ".sh", with: "")
                .replacingOccurrences(of: "-", with: " ")
        }
        return nil
    }

    private func queryLaunchctl(label: String) -> (pid: Int?, exitStatus: Int?) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, nil)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var pid: Int?
        var exitStatus: Int?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\"PID\"") {
                pid = Int(trimmed.components(separatedBy: "= ").last?.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces) ?? "")
            }
            if trimmed.contains("\"LastExitStatus\"") {
                exitStatus = Int(trimmed.components(separatedBy: "= ").last?.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces) ?? "")
            }
        }

        return (pid, exitStatus)
    }

    private func computeLaunchdNextRun(_ plist: [String: Any], after: Date) -> Date? {
        if let interval = plist["StartInterval"] as? Int {
            return after.addingTimeInterval(Double(interval))
        }
        if let cal = plist["StartCalendarInterval"] as? [String: Any] {
            let h = cal["Hour"] as? Int ?? 0
            let m = cal["Minute"] as? Int ?? 0
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = h
            components.minute = m
            if let next = calendar.date(from: components), next > Date() {
                return next
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) {
                components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
                components.hour = h
                components.minute = m
                return calendar.date(from: components)
            }
        }
        return nil
    }

    // MARK: - Hermes agents

    private func loadHermesAgents() -> [AgentInfo] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hermesDir) else { return [] }

        var result: [AgentInfo] = []

        result.append(buildHermesGateway())
        result.append(contentsOf: loadHermesCronJobs())
        result.append(contentsOf: loadHermesSessions())

        return result
    }

    private func buildHermesGateway() -> AgentInfo {
        let (gwStatus, gwError) = queryHermesGateway()
        let logPath = "\(hermesDir)/logs/agent.log"
        let (lastRun, lastError, _) = parseLogFile(path: logPath)

        return AgentInfo(
            id: "hermes.gateway",
            name: "Hermes Gateway",
            source: .hermes,
            type: .gateway,
            status: gwStatus,
            schedule: nil,
            lastRun: lastRun,
            nextRun: nil,
            project: nil,
            prompt: "Messaging gateway",
            duration: nil,
            error: gwError ?? lastError
        )
    }

    private func queryHermesGateway() -> (AgentRunStatus, String?) {
        let pipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["hermes", "gateway", "status"]
        process.standardOutput = pipe
        process.standardError = errPipe
        process.environment = [
            "PATH": "\(homePath)/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": homePath
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (.idle, nil)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lower = output.lowercased()

        if lower.contains("running") || lower.contains("active") {
            return (.running, nil)
        } else if lower.contains("error") || lower.contains("failed") {
            let errorLine = output.components(separatedBy: "\n").first { $0.lowercased().contains("error") }
            return (.error, errorLine.map { String($0.prefix(120)) })
        } else if lower.contains("stopped") || lower.contains("inactive") {
            return (.idle, nil)
        }
        return (.idle, nil)
    }

    private func loadHermesCronJobs() -> [AgentInfo] {
        let cronDir = "\(hermesDir)/cron"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cronDir) else { return [] }

        let cronFiles = files.filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") || $0.hasSuffix(".json") }
        return cronFiles.compactMap { parseHermesCron(path: "\(cronDir)/\($0)") }
    }

    private func parseHermesCron(path: String) -> AgentInfo? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let fileName = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".yaml", with: "")
            .replacingOccurrences(of: ".yml", with: "")
            .replacingOccurrences(of: ".json", with: "")

        var name = fileName
        var schedule: String?
        var prompt: String?

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            }
            if trimmed.hasPrefix("schedule:") || trimmed.hasPrefix("cron:") {
                schedule = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            }
            if trimmed.hasPrefix("prompt:") {
                prompt = trimmed.replacingOccurrences(of: "prompt:", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            }
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date

        return AgentInfo(
            id: "hermes.cron.\(fileName)",
            name: name,
            source: .hermes,
            type: .schedule,
            status: .idle,
            schedule: schedule,
            lastRun: modified,
            nextRun: nil,
            project: nil,
            prompt: prompt,
            duration: nil,
            error: nil
        )
    }

    private func loadHermesSessions() -> [AgentInfo] {
        let sessionsDir = "\(hermesDir)/sessions"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        return files.suffix(5).compactMap { sessionName -> AgentInfo? in
            let sessionPath = "\(sessionsDir)/\(sessionName)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionPath, isDirectory: &isDir), isDir.boolValue else { return nil }

            let attrs = try? fm.attributesOfItem(atPath: sessionPath)
            let modified = attrs?[.modificationDate] as? Date

            let displayName = sessionName
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")

            let recentThreshold = Date().addingTimeInterval(-300)
            let isActive = modified != nil && modified! > recentThreshold

            return AgentInfo(
                id: "hermes.session.\(sessionName)",
                name: displayName.prefix(1).uppercased() + displayName.dropFirst(),
                source: .hermes,
                type: .session,
                status: isActive ? .running : .success,
                schedule: nil,
                lastRun: modified,
                nextRun: nil,
                project: nil,
                prompt: nil,
                duration: nil,
                error: nil
            )
        }
    }

    // MARK: - Shared utilities

    private func parseLogFile(path: String?) -> (lastRun: Date?, lastError: String?, duration: Double?) {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return (nil, nil, nil)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date

        var lastError: String?
        if let data = FileManager.default.contents(atPath: path),
           let content = String(data: data, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").suffix(20)
            for line in lines.reversed() {
                let lower = line.lowercased()
                if lower.contains("error") || lower.contains("fail") || lower.contains("fatal") {
                    lastError = String(line.prefix(120))
                    break
                }
            }
        }

        return (modified, lastError, nil)
    }
}
