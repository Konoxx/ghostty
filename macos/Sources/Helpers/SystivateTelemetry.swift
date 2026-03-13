// SystivateTelemetry.swift
// Lightweight telemetry writer for Systivate observability stack.
// Appends JSONL events to ~/.ccs/ghostty-events.jsonl for LogRhythm ingestion.

import Foundation

enum SystivateTelemetry {
    private static let eventsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ccs/ghostty-events.jsonl"
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Emit a telemetry event to the JSONL log file.
    /// - Parameters:
    ///   - event: Event type name (e.g., "rubber_band_scroll")
    ///   - severity: "info", "warn", "error"
    ///   - details: Key-value pairs with additional context
    static func emit(event: String, severity: String = "warn", details: [String: String] = [:]) {
        var payload: [String: Any] = [
            "ts": dateFormatter.string(from: Date()),
            "source": "ghostty",
            "event": event,
            "severity": severity,
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        for (k, v) in details {
            payload[k] = v
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        // Append atomically — create file if missing
        let url = URL(fileURLWithPath: eventsPath)
        if FileManager.default.fileExists(atPath: eventsPath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            }
        } else {
            // Ensure parent directory exists
            try? FileManager.default.createDirectory(
                atPath: (eventsPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? line.write(toFile: eventsPath, atomically: true, encoding: .utf8)
        }
    }

    /// Log a rubber-band scroll event
    static func rubberBandScroll(trigger: String, surfaceTitle: String? = nil) {
        var details = ["trigger": trigger]
        if let title = surfaceTitle {
            details["surface"] = title
        }
        emit(event: "rubber_band_scroll", severity: "error", details: details)
    }
}
