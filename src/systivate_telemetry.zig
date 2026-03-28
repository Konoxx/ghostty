const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_telemetry);

/// Emit a rubber-band scroll event to ~/.ccs/ghostty-events.jsonl.
/// Fire-and-forget: catches all errors internally, never disrupts the caller.
/// Rate-limited to at most 1 write per second.
pub fn emitRubberBandEvent(trigger: []const u8) void {
    // Rate limit: 1 event/second
    const now = std.time.milliTimestamp();
    const state = struct {
        var last_emit: i64 = 0;
    };
    if (now - state.last_emit < 1000) return;
    state.last_emit = now;

    emitRubberBandEventInner(trigger) catch |err| {
        log.debug("telemetry write failed: {}", .{err});
    };
}

fn emitRubberBandEventInner(trigger: []const u8) !void {
    const home = posix.getenv("HOME") orelse return;

    // Build path: $HOME/.ccs/ghostty-events.jsonl
    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    // Ensure parent directory exists
    ensureDir(home) catch {};

    // Build JSONL line
    var buf: [1024]u8 = undefined;
    const pid = @as(i64, @intCast(std.c.getpid()));
    const ts = std.time.timestamp();
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"rubber_band_scroll\",\"severity\":\"error\",\"trigger\":\"{s}\",\"pid\":{d}}}\n", .{ ts, trigger, pid }) catch return;

    // Open with O_APPEND | O_CREAT | O_WRONLY
    const fd = posix.open(path_z, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644) catch return;
    defer posix.close(fd);

    _ = posix.write(fd, line) catch return;
}

/// Emit a watchdog event when viewport transitions from not-at-bottom to at-bottom.
/// This catches scroll-to-bottom from ANY source, including unknown code paths.
/// Now includes snap_reason from PageList to attribute the specific code path.
/// Separate rate limit from emitRubberBandEvent (5s) to reduce noise from
/// intentional user scrolling while still catching rapid rubber-band patterns.
pub fn emitWatchdogEvent(scroll_to_bottom_on_output: bool, snap_reason: []const u8) void {
    const now = std.time.milliTimestamp();
    const watchdog_state = struct {
        var last_emit: i64 = 0;
    };
    if (now - watchdog_state.last_emit < 5000) return;
    watchdog_state.last_emit = now;

    emitWatchdogEventInner(scroll_to_bottom_on_output, snap_reason) catch |err| {
        log.debug("watchdog telemetry write failed: {}", .{err});
    };
}

fn emitWatchdogEventInner(scroll_to_bottom_on_output: bool, snap_reason: []const u8) !void {
    const home = posix.getenv("HOME") orelse return;

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    ensureDir(home) catch {};

    var buf: [1024]u8 = undefined;
    const pid = @as(i64, @intCast(std.c.getpid()));
    const ts = std.time.timestamp();
    const output_scroll = if (scroll_to_bottom_on_output) "true" else "false";
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"viewport_watchdog\",\"severity\":\"warn\",\"trigger\":\"snap_to_bottom\",\"snap_reason\":\"{s}\",\"scroll_on_output\":{s},\"pid\":{d}}}\n", .{ ts, snap_reason, output_scroll, pid }) catch return;

    const fd = posix.open(path_z, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644) catch return;
    defer posix.close(fd);

    _ = posix.write(fd, line) catch return;
}

/// Emit a top-watchdog event when viewport transitions to .top unexpectedly.
/// Mirrors emitWatchdogEvent but for snap-to-top transitions.
/// Rate-limited to 5s to reduce noise from intentional scrolling.
pub fn emitTopWatchdogEvent(snap_reason: []const u8) void {
    const now = std.time.milliTimestamp();
    const top_state = struct {
        var last_emit: i64 = 0;
    };
    if (now - top_state.last_emit < 5000) return;
    top_state.last_emit = now;

    emitTopWatchdogEventInner(snap_reason) catch |err| {
        log.debug("top watchdog telemetry write failed: {}", .{err});
    };
}

fn emitTopWatchdogEventInner(snap_reason: []const u8) !void {
    const home = posix.getenv("HOME") orelse return;

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    ensureDir(home) catch {};

    var buf: [1024]u8 = undefined;
    const pid = @as(i64, @intCast(std.c.getpid()));
    const ts = std.time.timestamp();
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"viewport_watchdog\",\"severity\":\"warn\",\"trigger\":\"snap_to_top\",\"snap_reason\":\"{s}\",\"pid\":{d}}}\n", .{ ts, snap_reason, pid }) catch return;

    const fd = posix.open(path_z, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644) catch return;
    defer posix.close(fd);

    _ = posix.write(fd, line) catch return;
}

/// Emit a page pruning event when scrollback pages are recycled.
/// Rate-limited to 10s — pruning can happen rapidly during high output.
pub fn emitPagePruneEvent(prune_count: u32, viewport_state: []const u8) void {
    const now = std.time.milliTimestamp();
    const prune_state = struct {
        var last_emit: i64 = 0;
    };
    if (now - prune_state.last_emit < 10000) return;
    prune_state.last_emit = now;

    emitPagePruneEventInner(prune_count, viewport_state) catch |err| {
        log.debug("page prune telemetry write failed: {}", .{err});
    };
}

fn emitPagePruneEventInner(prune_count: u32, viewport_state: []const u8) !void {
    const home = posix.getenv("HOME") orelse return;

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    ensureDir(home) catch {};

    var buf: [1024]u8 = undefined;
    const pid = @as(i64, @intCast(std.c.getpid()));
    const ts = std.time.timestamp();
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"page_prune\",\"severity\":\"info\",\"prune_count\":{d},\"viewport\":\"{s}\",\"pid\":{d}}}\n", .{ ts, prune_count, viewport_state, pid }) catch return;

    const fd = posix.open(path_z, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644) catch return;
    defer posix.close(fd);

    _ = posix.write(fd, line) catch return;
}

/// Emit a critical diagnostic event — something that should never happen
/// but we want to capture instead of crashing silently.
/// Uses async-signal-safe write (no allocator, no locks).
/// Emit a diagnostic event for true integrity violations (viewport/pin corruption).
/// Used by PageList null-guard traps.
pub fn emitCrashDiagnostic(reason: [*:0]const u8, detail: usize) void {
    emitDiagnosticEvent("integrity_violation", "error", reason, detail);
}

/// Emit a diagnostic event for subsystem init/health (not a corruption signal).
/// Used by SHM init, IPC init, etc. — informational, not a crash indicator.
pub fn emitInitDiagnostic(reason: [*:0]const u8, detail: usize) void {
    emitDiagnosticEvent("init_diagnostic", "info", reason, detail);
}

fn emitDiagnosticEvent(event_type: [*:0]const u8, severity: [*:0]const u8, reason: [*:0]const u8, detail: usize) void {
    const home = posix.getenv("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    const fd = std.c.open(path_z, @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }), @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var buf: [512]u8 = undefined;
    const ts = @as(i64, @intCast(std.time.timestamp()));
    const pid = std.c.getpid();
    const len = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"{s}\",\"severity\":\"{s}\",\"reason\":\"{s}\",\"detail\":{d},\"pid\":{d}}}\n", .{
        ts, event_type, severity, reason, detail, pid,
    }) catch return;
    _ = std.c.write(fd, &buf, len.len);
}

fn ensureDir(home: []const u8) !void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.ccs", .{home}) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
