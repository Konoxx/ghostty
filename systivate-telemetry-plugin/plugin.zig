//! Systivate telemetry plugin — hot-swappable dynamic library.
//!
//! This is the telemetry implementation that gets loaded by Ghostty's
//! hot-swap system. It exports C-ABI functions that the renderer calls
//! through function pointers.
//!
//! Build:  zig build-lib -dynamic -O ReleaseFast plugin.zig \
//!           -femit-bin=~/.ccs/systivate-telemetry.dylib
//!
//! Reload: kill -USR1 $(pgrep -f ghostty)
//!    or:  touch ~/.ccs/telemetry-reload

const std = @import("std");
const posix = std.posix;

// ── Rate limiting state ──

var rubber_band_last: i64 = 0;
var watchdog_last: i64 = 0;
var top_watchdog_last: i64 = 0;
var prune_last: i64 = 0;

// ── Exported symbols (C ABI) ──

export fn systivate_emitRubberBandEvent(trigger: [*:0]const u8) void {
    const now = std.time.milliTimestamp();
    if (now - rubber_band_last < 1000) return;
    rubber_band_last = now;

    writeEvent(
        "rubber_band_scroll",
        "error",
        trigger,
        null,
        null,
    ) catch {};
}

export fn systivate_emitWatchdogEvent(scroll_on_output: bool, snap_reason: [*:0]const u8) void {
    const now = std.time.milliTimestamp();
    if (now - watchdog_last < 5000) return;
    watchdog_last = now;

    const output_scroll: [*:0]const u8 = if (scroll_on_output) "true" else "false";
    writeEventFull(
        "viewport_watchdog",
        "warn",
        "snap_to_bottom",
        snap_reason,
        output_scroll,
        null,
    ) catch {};
}

export fn systivate_emitTopWatchdogEvent(snap_reason: [*:0]const u8) void {
    const now = std.time.milliTimestamp();
    if (now - top_watchdog_last < 5000) return;
    top_watchdog_last = now;

    writeEventFull(
        "viewport_watchdog",
        "warn",
        "snap_to_top",
        snap_reason,
        null,
        null,
    ) catch {};
}

export fn systivate_emitPagePruneEvent(prune_count: u32, viewport_state: [*:0]const u8) void {
    const now = std.time.milliTimestamp();
    if (now - prune_last < 10000) return;
    prune_last = now;

    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrintZ(&count_buf, "{d}", .{prune_count}) catch return;

    writeEventFull(
        "page_prune",
        "info",
        null,
        null,
        null,
        .{ .prune_count = count_str, .viewport = viewport_state },
    ) catch {};
}

// ── Version identifier (useful for verifying which dylib is loaded) ──

export fn systivate_pluginVersion() u32 {
    return 1;
}

// ── Internal helpers ──

const ExtraFields = struct {
    prune_count: ?[*:0]const u8 = null,
    viewport: ?[*:0]const u8 = null,
};

fn writeEvent(
    event: [*:0]const u8,
    severity: [*:0]const u8,
    trigger: ?[*:0]const u8,
    snap_reason: ?[*:0]const u8,
    scroll_on_output: ?[*:0]const u8,
) !void {
    return writeEventFull(event, severity, trigger, snap_reason, scroll_on_output, null);
}

fn writeEventFull(
    event: [*:0]const u8,
    severity: [*:0]const u8,
    trigger: ?[*:0]const u8,
    snap_reason: ?[*:0]const u8,
    scroll_on_output: ?[*:0]const u8,
    extra: ?ExtraFields,
) !void {
    const home = posix.getenv("HOME") orelse return;

    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return;

    // Ensure directory
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.ccs", .{home}) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const pid = @as(i64, @intCast(std.c.getpid()));
    const ts = std.time.timestamp();

    try w.print("{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"{s}\",\"severity\":\"{s}\"", .{ ts, event, severity });

    if (trigger) |t| try w.print(",\"trigger\":\"{s}\"", .{t});
    if (snap_reason) |r| try w.print(",\"snap_reason\":\"{s}\"", .{r});
    if (scroll_on_output) |s| try w.print(",\"scroll_on_output\":{s}", .{s});

    if (extra) |e| {
        if (e.prune_count) |pc| try w.print(",\"prune_count\":{s}", .{pc});
        if (e.viewport) |vp| try w.print(",\"viewport\":\"{s}\"", .{vp});
    }

    try w.print(",\"pid\":{d},\"plugin\":true}}\n", .{pid});

    const line = fbs.getWritten();

    const fd = posix.open(path_z, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644) catch return;
    defer posix.close(fd);

    _ = posix.write(fd, line) catch return;
}
