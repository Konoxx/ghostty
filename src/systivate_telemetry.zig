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

fn ensureDir(home: []const u8) !void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.ccs", .{home}) catch return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
