# Agent Pulse

macOS menu bar app for monitoring [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)

## What it does

Agent Pulse sits in your menu bar and gives you a live overview of every Claude agent running on your Mac:

- **launchd agents** — discovers `com.claude.*` plist files, shows schedule, PID, exit status, and log errors
- **Hermes agents** — monitors gateway status, cron jobs, and active sessions
- **Run button** — instantly trigger any launchd agent with one click (`launchctl start`)
- **Auto-refresh** — polls every 30 seconds, with manual refresh available

## Install

```bash
git clone https://github.com/shint-mcguff/agent-pulse.git
cd agent-pulse
swift build
```

## Run

```bash
.build/arm64-apple-macosx/debug/AgentPulse
```

The app appears as a waveform icon in your menu bar. Click to open the panel.

## Requirements

- macOS 26 (Tahoe) or later
- Swift 6.2+
- Claude Code agents registered as `com.claude.*` LaunchAgents (optional — app shows demo data if none found)

## Architecture

```
Sources/AgentPulse/
  App.swift      — SwiftUI entry point (MenuBarExtra)
  Models.swift   — AgentInfo, AgentSource, AgentRunStatus
  Monitor.swift  — Agent discovery, launchctl queries, log parsing
  Views.swift    — PanelView, AgentCard, SummaryPill
```

~790 lines. No dependencies.

## License

MIT
