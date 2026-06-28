import SwiftUI

struct PanelView: View {
    @State private var monitor = AgentMonitor()

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().opacity(0.3)
            summaryBar
            Divider().opacity(0.3)
            agentList
            Divider().opacity(0.3)
            footerSection
        }
        .frame(width: 360)
        .task { monitor.start() }
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: monitor.agents.contains { $0.status == .running })
            Text("Agent Pulse")
                .font(.headline)

            Spacer()

            if monitor.usingDemoData {
                Text("Demo")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .rotationEffect(.degrees(monitor.isLoading ? 360 : 0))
            .animation(.easeInOut(duration: 0.5), value: monitor.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            SummaryPill(
                count: monitor.agents.filter { $0.status == .running }.count,
                label: "Running",
                color: .blue
            )
            SummaryPill(
                count: monitor.agents.filter { $0.status == .success }.count,
                label: "OK",
                color: .green
            )
            SummaryPill(
                count: monitor.agents.filter { $0.status == .error }.count,
                label: "Error",
                color: .red
            )
            SummaryPill(
                count: monitor.agents.filter { $0.status == .idle }.count,
                label: "Idle",
                color: .secondary
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var agentList: some View {
        if monitor.agents.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(monitor.agents) { agent in
                        AgentCard(agent: agent) {
                            monitor.triggerLaunchdAgent(label: agent.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minHeight: 200, maxHeight: 420)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No agents running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Scheduled agents will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footerSection: some View {
        HStack {
            if let updated = monitor.lastUpdated {
                Text("Updated \(updated, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Open Claude Code") {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-a", "Terminal"]
                try? task.run()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SummaryPill: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.caption.monospacedDigit().bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }
}

struct AgentCard: View {
    let agent: AgentInfo
    var onRun: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot
                Text(agent.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if agent.source == .launchd && agent.status != .running {
                    Button {
                        onRun?()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help("Run now")
                }
                sourceBadge
                typeBadge
            }

            if let prompt = agent.prompt {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                if let lastRun = agent.lastRun {
                    Label {
                        Text(lastRun, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
                if let duration = agent.duration {
                    Label {
                        Text(formatDuration(duration))
                    } icon: {
                        Image(systemName: "stopwatch")
                    }
                }
                if let schedule = agent.schedule {
                    Label {
                        Text(humanCron(schedule))
                    } icon: {
                        Image(systemName: "calendar.badge.clock")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let error = agent.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = switch agent.status {
        case .running: .blue
        case .success: .green
        case .error: .red
        case .idle: .gray
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(agent.status == .running ? 0.6 : 0), radius: 4)
            .symbolEffect(.pulse, isActive: agent.status == .running)
    }

    private var sourceBadge: some View {
        Text(agent.source == .hermes ? "⚗ Hermes" : "⚙ launchd")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(agent.source == .hermes ? .purple : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                (agent.source == .hermes ? Color.purple : Color.gray).opacity(0.15),
                in: Capsule()
            )
    }

    private var typeBadge: some View {
        Text(agent.type.rawValue)
            .font(.system(size: 9, weight: .medium))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }

    private func humanCron(_ cron: String) -> String {
        let parts = cron.split(separator: " ")
        guard parts.count >= 5 else { return cron }
        let (min, hour, _, _, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])

        if dow != "*" {
            let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            if let d = Int(String(dow)), d < 7 {
                return "\(days[d]) \(hour):\(min.count == 1 ? "0\(min)" : String(min))"
            }
        }
        if hour == "*" && min == "0" { return "Every hour" }
        if hour.hasPrefix("*/") { return "Every \(hour.dropFirst(2))h" }
        return "\(hour):\(min.count == 1 ? "0\(min)" : String(min))"
    }
}

