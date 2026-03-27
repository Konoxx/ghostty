//! Systivate crash handler — cross-platform (macOS + Linux).
//!
//! Complements the existing Sentry crash system (macOS-only) by:
//!   1. Installing signal handlers for fatal signals
//!   2. Writing a crash marker to ~/.ccs/ghostty-crashes/ (async-signal-safe)
//!   3. Emitting a JSONL event to ~/.ccs/ghostty-events.jsonl
//!
//! On macOS this runs alongside Sentry (SA_RESETHAND chains to default).
//! On Linux headless this is the ONLY crash capture.
//!
//! All signal handler code uses ONLY async-signal-safe functions:
//! open, write, close, getpid, _exit. No allocations, no locks, no stdio.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_crash);

// ── Paths (populated at init, read-only after) ──

var crash_dir_buf: [512]u8 = undefined;
var crash_dir_len: usize = 0;
var marker_path_buf: [512]u8 = undefined;
var marker_path_len: usize = 0;
var events_path_buf: [512]u8 = undefined;
var events_path_len: usize = 0;
var initialized: bool = false;

/// Call once at startup. Sets up paths and installs signal handlers.
/// Safe to call multiple times (idempotent).
pub fn init() void {
    if (initialized) return;

    const home = posix.getenv("HOME") orelse {
        log.warn("HOME not set, crash handler disabled", .{});
        return;
    };

    // Build ~/.ccs/ghostty-crashes/
    crash_dir_len = (std.fmt.bufPrint(&crash_dir_buf, "{s}/.ccs/ghostty-crashes", .{home}) catch return).len;

    // Ensure dir exists
    const crash_dir_z = std.fmt.bufPrintZ(&crash_dir_buf, "{s}/.ccs/ghostty-crashes", .{home}) catch return;
    std.fs.makeDirAbsolute(crash_dir_z) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("cannot create crash dir: {}", .{err});
            return;
        },
    };

    // Build marker path
    marker_path_len = (std.fmt.bufPrint(&marker_path_buf, "{s}/.ccs/ghostty-crashes/crash-marker.json", .{home}) catch return).len;

    // Build events path
    events_path_len = (std.fmt.bufPrint(&events_path_buf, "{s}/.ccs/ghostty-events.jsonl", .{home}) catch return).len;

    // Ensure ~/.ccs/ exists for events
    const ccs_dir_z = std.fmt.bufPrintZ(&crash_dir_buf, "{s}/.ccs", .{home}) catch return;
    std.fs.makeDirAbsolute(ccs_dir_z) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };
    // Restore crash_dir_buf
    crash_dir_len = (std.fmt.bufPrint(&crash_dir_buf, "{s}/.ccs/ghostty-crashes", .{home}) catch return).len;

    installSignalHandlers();
    initialized = true;
    log.info("crash handler installed", .{});
}

// ── Signal handling (async-signal-safe only) ──

const fatal_signals = [_]u6{
    posix.SIG.ABRT,
    posix.SIG.SEGV,
    posix.SIG.BUS,
    posix.SIG.FPE,
    posix.SIG.ILL,
    posix.SIG.TRAP,
    posix.SIG.TERM,
    posix.SIG.HUP,
};

// Global storage for sender info (written by sigaction handler, read by write functions)
var g_sender_pid: std.c.pid_t = 0;
var g_sender_uid: std.c.uid_t = 0;

fn installSignalHandlers() void {
    for (fatal_signals) |sig| {
        const act = posix.Sigaction{
            .handler = .{ .sigaction = signalHandlerSiginfo },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESETHAND | posix.SA.SIGINFO, // SA_SIGINFO gives us sender PID
        };
        posix.sigaction(sig, &act, null);
    }
}

fn signalHandlerSiginfo(sig: c_int, info: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // Everything here must be async-signal-safe.
    // No allocations, no locks, no stdio.

    // Extract sender PID and UID from siginfo_t
    g_sender_pid = info.fields.common.first.piduid.pid;
    g_sender_uid = info.fields.common.first.piduid.uid;

    writeCrashMarker(sig);
    writeEventLine(sig);

    // Clean up IPC socket (unlink is async-signal-safe)
    @import("systivate_ipc.zig").crashCleanup();

    // Re-raise with default handler to produce a core dump / system crash report
    // SA_RESETHAND already restored default, just re-raise.
    _ = std.c.raise(sig);
}

fn writeCrashMarker(sig: c_int) void {
    if (marker_path_len == 0) return;

    // Null-terminate the path
    var path_z: [512:0]u8 = undefined;
    if (marker_path_len >= path_z.len) return;
    @memcpy(path_z[0..marker_path_len], marker_path_buf[0..marker_path_len]);
    path_z[marker_path_len] = 0;

    const fd = std.c.open(&path_z, @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }), @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    // Build JSON manually — no allocator
    var buf: [512]u8 = undefined;
    const pid = std.c.getpid();
    const ts = @as(i64, @intCast(std.time.timestamp()));
    const sig_name = signalName(sig);

    const len = sigSafeFmt(&buf, sig_name, sig, ts, pid);
    if (len > 0) {
        _ = std.c.write(fd, &buf, len);
    }
}

fn writeEventLine(sig: c_int) void {
    if (events_path_len == 0) return;

    var path_z: [512:0]u8 = undefined;
    if (events_path_len >= path_z.len) return;
    @memcpy(path_z[0..events_path_len], events_path_buf[0..events_path_len]);
    path_z[events_path_len] = 0;

    const fd = std.c.open(&path_z, @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }), @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var buf: [512]u8 = undefined;
    const pid = std.c.getpid();
    const ts = @as(i64, @intCast(std.time.timestamp()));
    const sig_name = signalName(sig);

    const len = eventLineFmt(&buf, sig_name, sig, ts, pid);
    if (len > 0) {
        _ = std.c.write(fd, &buf, len);
    }
}

// ── Async-signal-safe formatting ──

fn sigSafeFmt(buf: []u8, sig_name: []const u8, sig: c_int, ts: i64, pid: std.c.pid_t) usize {
    const platform = comptime if (@import("builtin").os.tag == .macos) "macos" else "linux";
    const result = std.fmt.bufPrint(buf, "{{\"type\":\"signal_crash\",\"platform\":\"{s}\",\"signal\":\"{s}\",\"signal_number\":{d},\"timestamp\":\"{d}\",\"pid\":{d},\"sender_pid\":{d},\"sender_uid\":{d}}}", .{
        platform, sig_name, sig, ts, pid, g_sender_pid, g_sender_uid,
    }) catch return 0;
    return result.len;
}

fn eventLineFmt(buf: []u8, sig_name: []const u8, sig: c_int, ts: i64, pid: std.c.pid_t) usize {
    const platform = comptime if (@import("builtin").os.tag == .macos) "macos" else "linux";
    const result = std.fmt.bufPrint(buf, "{{\"ts\":{d},\"source\":\"ghostty\",\"event\":\"fatal_signal\",\"severity\":\"error\",\"signal\":\"{s}\",\"signal_number\":{d},\"platform\":\"{s}\",\"pid\":{d},\"sender_pid\":{d},\"sender_uid\":{d}}}\n", .{
        ts, sig_name, sig, platform, pid, g_sender_pid, g_sender_uid,
    }) catch return 0;
    return result.len;
}

fn signalName(sig: c_int) []const u8 {
    return switch (sig) {
        posix.SIG.ABRT => "SIGABRT",
        posix.SIG.SEGV => "SIGSEGV",
        posix.SIG.BUS => "SIGBUS",
        posix.SIG.FPE => "SIGFPE",
        posix.SIG.ILL => "SIGILL",
        posix.SIG.TRAP => "SIGTRAP",
        posix.SIG.TERM => "SIGTERM",
        posix.SIG.HUP => "SIGHUP",
        else => "UNKNOWN",
    };
}
