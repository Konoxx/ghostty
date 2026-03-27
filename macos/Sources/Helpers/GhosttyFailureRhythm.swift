// GhosttyFailureRhythm.swift
// Crash logging for Ghostty-Systivate macOS app.
// Modeled after FailureRhythm (iOS) — adapted for AppKit lifecycle.
//
// Layers:
//   1. Breadcrumbs — last-known state written to disk every 10s
//   2. Signal handlers — catch fatal signals, write crash marker before death
//   3. Exception handler — catch uncaught NSExceptions with stack trace
//   4. Next-launch reporter — detect pending crash files, POST to FailureRhythm
//   5. JSONL telemetry — emit events to SystivateTelemetry for LogRhythm

import AppKit
import OSLog

final class GhosttyFailureRhythm: @unchecked Sendable {
    static let shared = GhosttyFailureRhythm()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "FailureRhythm"
    )

    private let crashDir: URL
    private let breadcrumbFile: URL
    private let markerFile: URL
    private let queue = DispatchQueue(label: "com.systivate.ghostty.failurerhythm", qos: .utility)

    private var breadcrumbs: [String: String] = [:]
    private var breadcrumbTimer: Timer?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        crashDir = home.appendingPathComponent(".ccs/ghostty-crashes")
        breadcrumbFile = crashDir.appendingPathComponent("breadcrumbs.json")
        markerFile = crashDir.appendingPathComponent("crash-marker.json")
        try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Call once at app launch, before NSApplicationMain.
    func install() {
        installSignalHandlers()
        installExceptionHandler()

        setBreadcrumb("app_state", value: "launching")
        setBreadcrumb("launch_time", value: ISO8601DateFormatter().string(from: Date()))
        setBreadcrumb("os_version", value: ProcessInfo.processInfo.operatingSystemVersionString)
        setBreadcrumb("app_version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        setBreadcrumb("memory_mb", value: "\(currentMemoryMB())")
        setBreadcrumb("thermal_state", value: thermalStateString())
        setBreadcrumb("pid", value: "\(ProcessInfo.processInfo.processIdentifier)")
        flushBreadcrumbs()

        startBreadcrumbTimer()
        reportPendingCrashes()
        observeLifecycle()

        SystivateTelemetry.emit(event: "failurerhythm_installed", severity: "info", details: [
            "crash_dir": crashDir.path
        ])
        Self.logger.info("Installed — pid=\(ProcessInfo.processInfo.processIdentifier) crash_dir=\(self.crashDir.path)")
        Self.logger.info("Signal handlers: SIGABRT SIGSEGV SIGBUS SIGFPE SIGILL SIGTRAP SIGTERM SIGHUP")
    }

    /// Set a breadcrumb value (survives crashes via periodic disk flush).
    func setBreadcrumb(_ key: String, value: String) {
        queue.async { [weak self] in
            self?.breadcrumbs[key] = value
        }
    }

    /// Record a significant event in the breadcrumb trail.
    func recordEvent(_ event: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var events = (self.breadcrumbs["recent_events"] ?? "").split(separator: "\n").map(String.init)
            let ts = Self.compactTimestamp()
            events.append("\(ts) \(event)")
            if events.count > 30 { events = Array(events.suffix(30)) }
            self.breadcrumbs["recent_events"] = events.joined(separator: "\n")
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        GhosttyFailureGlobals.crashDirPath = crashDir.path

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP, SIGTERM, SIGHUP]
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u = unsafeBitCast(
                GhosttyFailureGlobals.handleSignalSiginfo as @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void,
                to: __sigaction_u.self
            )
            action.sa_flags = Int32(SA_RESETHAND | SA_SIGINFO)
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let report: [String: Any] = [
                "type": "uncaught_exception",
                "platform": "macos",
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "name": exception.name.rawValue,
                "reason": exception.reason ?? "unknown",
                "call_stack": exception.callStackSymbols,
                "return_addresses": exception.callStackReturnAddresses.map { String(describing: $0) },
                "pid": ProcessInfo.processInfo.processIdentifier,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let dir = GhosttyFailureGlobals.crashDirPath {
                let filename = "crash-\(Int(Date().timeIntervalSince1970)).json"
                let path = (dir as NSString).appendingPathComponent(filename)
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Breadcrumbs

    private func startBreadcrumbTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.breadcrumbTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.setBreadcrumb("memory_mb", value: "\(self.currentMemoryMB())")
                self.setBreadcrumb("thermal_state", value: self.thermalStateString())
                self.setBreadcrumb("uptime_s", value: "\(Int(ProcessInfo.processInfo.systemUptime))")
                self.setBreadcrumb("window_count", value: "\(NSApp?.windows.count ?? 0)")
                self.flushBreadcrumbs()
            }
        }
    }

    private func flushBreadcrumbs() {
        queue.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONSerialization.data(withJSONObject: self.breadcrumbs, options: [.sortedKeys]) {
                try? data.write(to: self.breadcrumbFile, options: .atomic)
            }
        }
    }

    // MARK: - Crash Reporting

    private func reportPendingCrashes() {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default

            // Consolidate signal crash marker with breadcrumbs
            if fm.fileExists(atPath: self.markerFile.path) {
                var report: [String: Any] = [:]
                if let data = try? Data(contentsOf: self.markerFile),
                   let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    report = marker
                }
                if let data = try? Data(contentsOf: self.breadcrumbFile),
                   let crumbs = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    report["breadcrumbs"] = crumbs
                }
                report["type"] = report["type"] ?? "signal_crash"
                report["platform"] = "macos"
                report["reported_at"] = ISO8601DateFormatter().string(from: Date())

                let ts = report["timestamp"] as? String ?? "\(Int(Date().timeIntervalSince1970))"
                let filename = "crash-\(ts).json"
                let reportURL = self.crashDir.appendingPathComponent(filename)
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: reportURL)
                }
                try? fm.removeItem(at: self.markerFile)
            }

            // Log pending crash files via telemetry
            guard let files = try? fm.contentsOfDirectory(at: self.crashDir, includingPropertiesForKeys: nil) else { return }
            let crashFiles = files.filter {
                $0.pathExtension == "json"
                && $0.lastPathComponent.hasPrefix("crash-")
                && $0.lastPathComponent != "crash-marker.json"
            }

            guard !crashFiles.isEmpty else { return }
            Self.logger.warning("Found \(crashFiles.count) pending crash report(s) from previous run")

            for file in crashFiles {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                // Emit to JSONL for LogRhythm
                var details: [String: String] = [
                    "crash_file": file.lastPathComponent,
                    "crash_type": json["type"] as? String ?? "unknown",
                ]
                if let sig = json["signal"] as? String { details["signal"] = sig }
                if let reason = json["reason"] as? String { details["reason"] = String(reason.prefix(200)) }
                if let name = json["name"] as? String { details["exception_name"] = name }
                if let ts = json["timestamp"] as? String { details["crash_timestamp"] = ts }

                SystivateTelemetry.emit(event: "previous_crash_detected", severity: "error", details: details)

                // Archive to reported/
                let reported = self.crashDir.appendingPathComponent("reported")
                try? fm.createDirectory(at: reported, withIntermediateDirectories: true)
                let dest = reported.appendingPathComponent(file.lastPathComponent)
                try? fm.moveItem(at: file, to: dest)
                Self.logger.info("Archived crash report: \(file.lastPathComponent)")
            }
        }
    }

    // MARK: - Lifecycle Observers

    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        setBreadcrumb("app_state", value: "active")
        recordEvent("app_became_active")
        flushBreadcrumbs()
        Self.logger.info("App became active (pid=\(ProcessInfo.processInfo.processIdentifier))")
    }

    @objc private func appWillResignActive() {
        setBreadcrumb("app_state", value: "inactive")
        recordEvent("app_resigned_active")
        flushBreadcrumbs()
        Self.logger.info("App resigned active")
    }

    @objc private func appWillTerminate() {
        Self.logger.warning("App will terminate (pid=\(ProcessInfo.processInfo.processIdentifier))")
        setBreadcrumb("app_state", value: "terminating")
        recordEvent("app_will_terminate")
        // Synchronous flush — we're about to exit
        if let data = try? JSONSerialization.data(withJSONObject: breadcrumbs, options: [.sortedKeys]) {
            try? data.write(to: breadcrumbFile, options: .atomic)
        }
        SystivateTelemetry.emit(event: "clean_shutdown", severity: "info")
    }

    @objc private func thermalStateChanged() {
        let state = thermalStateString()
        setBreadcrumb("thermal_state", value: state)
        recordEvent("thermal_state_changed to \(state)")
        if state == "serious" || state == "critical" {
            SystivateTelemetry.emit(event: "thermal_warning", severity: "warn", details: ["state": state])
        }
        flushBreadcrumbs()
    }

    // MARK: - Helpers

    private func currentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 0
    }

    private func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func compactTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

// MARK: - Signal Handler Globals (async-signal-safe)

enum GhosttyFailureGlobals {
    nonisolated(unsafe) static var crashDirPath: String?

    /// SA_SIGINFO handler — receives siginfo_t with sender PID.
    static let handleSignalSiginfo: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { sig, info, _ in
        guard let dirPath = crashDirPath else {
            signal(sig, SIG_DFL)
            raise(sig)
            return
        }

        // Extract sender PID and UID from siginfo_t
        let senderPid: pid_t = info?.pointee.si_pid ?? 0
        let senderUid: uid_t = info?.pointee.si_uid ?? 0

        let sigName: String
        switch sig {
        case SIGABRT: sigName = "SIGABRT"
        case SIGSEGV: sigName = "SIGSEGV"
        case SIGBUS:  sigName = "SIGBUS"
        case SIGFPE:  sigName = "SIGFPE"
        case SIGILL:  sigName = "SIGILL"
        case SIGTRAP: sigName = "SIGTRAP"
        case SIGTERM: sigName = "SIGTERM"
        case SIGHUP:  sigName = "SIGHUP"
        default:      sigName = "SIG\(sig)"
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let pid = getpid()
        let json = """
        {"type":"signal_crash","platform":"macos","signal":"\(sigName)","signal_number":\(sig),"timestamp":"\(timestamp)","pid":\(pid),"sender_pid":\(senderPid),"sender_uid":\(senderUid)}
        """

        let markerPath = (dirPath as NSString).appendingPathComponent("crash-marker.json")
        if let fd = fopen(markerPath, "w") {
            json.withCString { ptr in
                _ = fputs(ptr, fd)
            }
            fclose(fd)
        }

        // Re-raise with default handler so macOS generates a system crash report too
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
