import SwiftUI

@main
struct AgentPulseApp: App {
    var body: some Scene {
        MenuBarExtra("Agent Pulse", systemImage: "waveform.circle.fill") {
            PanelView()
        }
        .menuBarExtraStyle(.window)
    }
}
