import Foundation

enum AgentSource: String, Codable, Sendable {
    case launchd
    case hermes
}

enum AgentType: String, Codable, Sendable {
    case schedule
    case loop
    case session
    case gateway
}

enum AgentRunStatus: String, Codable, Sendable {
    case idle
    case running
    case success
    case error
}

struct AgentInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let source: AgentSource
    let type: AgentType
    let status: AgentRunStatus
    let schedule: String?
    let lastRun: Date?
    let nextRun: Date?
    let project: String?
    let prompt: String?
    let duration: Double?
    let error: String?
}

struct AgentStatusFile: Codable, Sendable {
    let updatedAt: Date
    let agents: [AgentInfo]
}
