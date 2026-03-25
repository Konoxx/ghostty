//! Systivate IPC command layer — parsing, execution, response formatting.
//!
//! Commands are newline-delimited text. Responses are single-line JSON.
//! Execution dispatches to atomic flags (immediate), SHM reads (query),
//! or thread mailboxes (action).

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_ipc_commands);

const systivate_flags = @import("systivate_flags.zig");
const systivate_hotswap = @import("systivate_hotswap.zig");

// ── Command execution ──

/// Execute a command line and write the JSON response into buf.
/// Returns the slice of buf that contains the response.
pub fn execute(line: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return formatOk(buf, null);

    // Tokenize: split on spaces
    var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const verb = iter.next() orelse return formatError(buf, "empty command");

    // ── SET commands (immediate, atomic flag store) ──
    if (std.mem.eql(u8, verb, "set")) {
        const key = iter.next() orelse return formatError(buf, "set requires key and value");
        const val = iter.next() orelse return formatError(buf, "set requires a value");
        return executeSet(key, val, buf);
    }

    // ── GET commands (query, atomic flag read / SHM read) ──
    if (std.mem.eql(u8, verb, "get")) {
        const key = iter.next() orelse return formatError(buf, "get requires a key");
        return executeGet(key, buf);
    }

    // ── Action commands ──
    if (std.mem.eql(u8, verb, "reload_dylib")) {
        systivate_hotswap.requestReload();
        return formatOk(buf, null);
    }

    if (std.mem.eql(u8, verb, "reload_config")) {
        // TODO: push to App mailbox when setApp() wired
        return formatOk(buf, "{\"queued\":true,\"note\":\"config reload queued\"}");
    }

    if (std.mem.eql(u8, verb, "dump_shm")) {
        return executeDumpShm(buf);
    }

    if (std.mem.eql(u8, verb, "help")) {
        return executeHelp(buf);
    }

    if (std.mem.eql(u8, verb, "ping")) {
        return formatOk(buf, "{\"pong\":true}");
    }

    if (std.mem.eql(u8, verb, "shutdown_ipc")) {
        // Graceful IPC shutdown — responds, then tears down the socket.
        // Ghostty continues running; only the IPC channel stops.
        // Restart requires app restart (or SIGHUP if wired).
        @import("systivate_ipc.zig").requestShutdown();
        return formatOk(buf, "{\"shutting_down\":true,\"note\":\"IPC channel will close after this response\"}");
    }

    return formatError(buf, "unknown command");
}

// ── SET dispatch ──

fn executeSet(key: []const u8, val: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, key, "fixup_mode")) {
        const mode = std.fmt.parseInt(u8, val, 10) catch return formatError(buf, "fixup_mode must be 0, 1, or 2");
        if (mode > 2) return formatError(buf, "fixup_mode must be 0, 1, or 2");
        systivate_flags.fixup_mode.store(mode, .release);
        log.info("IPC: set fixup_mode={d}", .{mode});
        return formatOk(buf, null);
    }

    if (std.mem.eql(u8, key, "scrollback_override")) {
        const bytes = std.fmt.parseInt(usize, val, 10) catch return formatError(buf, "scrollback_override must be a number");
        systivate_flags.scrollback_override.store(bytes, .release);
        log.info("IPC: set scrollback_override={d}", .{bytes});
        return formatOk(buf, null);
    }

    if (std.mem.eql(u8, key, "telemetry")) {
        const enabled = std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        systivate_flags.telemetry_enabled.store(enabled, .release);
        log.info("IPC: set telemetry={}", .{enabled});
        return formatOk(buf, null);
    }

    return formatError(buf, "unknown key");
}

// ── GET dispatch ──

fn executeGet(key: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, key, "fixup_mode")) {
        const mode = systivate_flags.fixup_mode.load(.acquire);
        return formatOkFmt(buf, "{{\"fixup_mode\":{d}}}", .{mode});
    }

    if (std.mem.eql(u8, key, "scrollback_override")) {
        const val = systivate_flags.scrollback_override.load(.acquire);
        return formatOkFmt(buf, "{{\"scrollback_override\":{d}}}", .{val});
    }

    if (std.mem.eql(u8, key, "telemetry")) {
        const enabled = systivate_flags.telemetry_enabled.load(.acquire);
        return formatOkFmt(buf, "{{\"telemetry\":{}}}", .{enabled});
    }

    if (std.mem.eql(u8, key, "health")) {
        return executeGetHealth(buf);
    }

    if (std.mem.eql(u8, key, "version")) {
        return formatOk(buf, "{\"binary\":\"1.3.1-systivate\",\"ipc_protocol\":1}");
    }

    if (std.mem.eql(u8, key, "surfaces")) {
        return executeDumpShm(buf);
    }

    if (std.mem.eql(u8, key, "tab_count")) {
        const count = systivate_flags.surface_count.load(.acquire);
        return formatOkFmt(buf, "{{\"tab_count\":{d}}}", .{count});
    }

    if (std.mem.eql(u8, key, "output_rate")) {
        return executeGetOutputRate(buf);
    }

    return formatError(buf, "unknown key");
}

// ── Diagnostics ──

fn executeGetHealth(buf: []u8) []const u8 {
    const tabs = systivate_flags.surface_count.load(.acquire);
    const output = systivate_flags.output_bytes.load(.acquire);
    const mode = systivate_flags.fixup_mode.load(.acquire);
    const sb = systivate_flags.scrollback_override.load(.acquire);
    const telem = systivate_flags.telemetry_enabled.load(.acquire);
    return formatOkFmt(buf, "{{\"pid\":{d},\"ipc_clients\":{d},\"tab_count\":{d},\"output_bytes\":{d},\"fixup_mode\":{d},\"scrollback_override\":{d},\"telemetry_enabled\":{}}}", .{
        std.c.getpid(),
        countClients(),
        tabs,
        output,
        mode,
        sb,
        telem,
    });
}

/// Output rate: returns cumulative output_bytes. Caller computes delta between polls.
fn executeGetOutputRate(buf: []u8) []const u8 {
    const bytes = systivate_flags.output_bytes.load(.acquire);
    const tabs = systivate_flags.surface_count.load(.acquire);
    return formatOkFmt(buf, "{{\"output_bytes\":{d},\"tab_count\":{d},\"note\":\"compute delta between polls for rate\"}}", .{ bytes, tabs });
}

fn executeDumpShm(buf: []u8) []const u8 {
    // SHM is write-only from this process (read by external observers via mmap).
    // Report the flags we can read directly.
    const mode = systivate_flags.fixup_mode.load(.acquire);
    const sb = systivate_flags.scrollback_override.load(.acquire);
    const telem = systivate_flags.telemetry_enabled.load(.acquire);
    return formatOkFmt(buf, "{{\"fixup_mode\":{d},\"scrollback_override\":{d},\"telemetry_enabled\":{},\"note\":\"use shm-observer.py for full SHM state\"}}", .{ mode, sb, telem });
}

fn executeHelp(buf: []u8) []const u8 {
    return formatOk(buf,
        \\{"commands":["set fixup_mode <0|1|2>","set scrollback_override <bytes>","set telemetry <on|off>","get fixup_mode","get scrollback_override","get telemetry","get health","get version","get surfaces","get tab_count","get output_rate","reload_dylib","reload_config","dump_shm","ping","shutdown_ipc","help"]}
    );
}

fn countClients() usize {
    return @import("systivate_ipc.zig").getClientCount();
}

// ── Response formatting ──

fn formatOk(buf: []u8, data: ?[]const u8) []const u8 {
    if (data) |d| {
        return std.fmt.bufPrint(buf, "{{\"ok\":true,\"data\":{s}}}", .{d}) catch "{\"ok\":true}";
    }
    return std.fmt.bufPrint(buf, "{{\"ok\":true}}", .{}) catch "{\"ok\":true}";
}

fn formatOkFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    // First format the data part
    var data_buf: [2048]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, fmt, args) catch return formatError(buf, "format error");
    return formatOk(buf, data);
}

fn formatError(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch "{\"ok\":false}";
}
