//! Systivate hot-swap: loads telemetry functions from a dynamic library
//! so they can be replaced at runtime without restarting Ghostty.
//!
//! The renderer calls through function pointers in a vtable. When a new
//! dylib is detected (via atomic reload flag), the renderer swaps it in
//! on its own thread — no cross-thread synchronization needed.
//!
//! Reload trigger: kill -USR1 $(pgrep -f ghostty)
//! Dylib location: ~/.ccs/systivate-telemetry.dylib

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_hotswap);

// Fallback: direct import for when no dylib is loaded
const builtin_telemetry = @import("systivate_telemetry.zig");
const systivate_flags = @import("systivate_flags.zig");

// ── VTable: the interface between renderer and telemetry implementation ──

pub const TelemetryVTable = struct {
    emitRubberBandEvent: *const fn ([*:0]const u8) void,
    emitWatchdogEvent: *const fn (bool, [*:0]const u8) void,
    emitTopWatchdogEvent: *const fn ([*:0]const u8) void,
    emitPagePruneEvent: *const fn (u32, [*:0]const u8) void,
};

/// Builtin vtable — calls the compiled-in telemetry functions directly.
/// Used as fallback when no dylib is loaded or dylib fails to load.
const builtin_vtable = TelemetryVTable{
    .emitRubberBandEvent = &builtinRubberBand,
    .emitWatchdogEvent = &builtinWatchdog,
    .emitTopWatchdogEvent = &builtinTopWatchdog,
    .emitPagePruneEvent = &builtinPagePrune,
};

// Wrappers that adapt Zig slice API to C-string API
fn builtinRubberBand(trigger: [*:0]const u8) void {
    builtin_telemetry.emitRubberBandEvent(std.mem.sliceTo(trigger, 0));
}
fn builtinWatchdog(scroll_on_output: bool, snap_reason: [*:0]const u8) void {
    builtin_telemetry.emitWatchdogEvent(scroll_on_output, std.mem.sliceTo(snap_reason, 0));
}
fn builtinTopWatchdog(snap_reason: [*:0]const u8) void {
    builtin_telemetry.emitTopWatchdogEvent(std.mem.sliceTo(snap_reason, 0));
}
fn builtinPagePrune(prune_count: u32, viewport_state: [*:0]const u8) void {
    builtin_telemetry.emitPagePruneEvent(prune_count, std.mem.sliceTo(viewport_state, 0));
}

// ── Hot-swap state ──

var current_vtable: TelemetryVTable = builtin_vtable;
var reload_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var dylib_handle: ?*anyopaque = null;
var dylib_path_buf: [512]u8 = undefined;
var dylib_version: u64 = 0;

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;

const RTLD_NOW: c_int = 0x2;
const RTLD_LOCAL: c_int = 0x4;

/// Get the active vtable. Called from the renderer each frame.
/// Checks the reload flag and swaps if needed (on the renderer thread).
/// Also checks the scrollback override file (rate-limited to every 5s).
pub fn vtable() *const TelemetryVTable {
    if (reload_requested.load(.acquire)) {
        reload_requested.store(false, .release);
        performReload();
    }
    checkScrollbackOverride();
    return &current_vtable;
}

/// Request a reload. Can be called from any thread (e.g., signal handler,
/// file watcher, or external trigger).
pub fn requestReload() void {
    reload_requested.store(true, .release);
}

/// Initialize the hot-swap system. Tries to load an existing dylib.
/// If none exists, falls back to builtin telemetry (zero-cost).
pub fn init() void {
    // Install SIGUSR1 handler for external reload trigger
    installSignalHandler();

    // Try loading the dylib
    if (getDylibPath()) |path| {
        loadDylib(path);
    } else {
        log.info("no telemetry dylib found, using builtin telemetry", .{});
    }
}

fn getDylibPath() ?[*:0]const u8 {
    const home = posix.getenv("HOME") orelse return null;
    const path = std.fmt.bufPrintZ(&dylib_path_buf, "{s}/.ccs/systivate-telemetry.dylib", .{home}) catch return null;
    // Check if file exists by trying to access it
    std.fs.accessAbsolute(std.mem.sliceTo(path, 0), .{}) catch return null;
    return path;
}

fn loadDylib(path: [*:0]const u8) void {
    const handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) orelse {
        if (dlerror()) |err| {
            log.warn("dlopen failed: {s}", .{std.mem.sliceTo(err, 0)});
        }
        return;
    };

    // Resolve all symbols — each returns ?*anyopaque, we cast to the typed fn pointer
    const new_vtable = TelemetryVTable{
        .emitRubberBandEvent = @ptrCast(@alignCast(dlsym(handle, "systivate_emitRubberBandEvent") orelse {
            log.warn("missing symbol: systivate_emitRubberBandEvent", .{});
            _ = dlclose(handle);
            return;
        })),
        .emitWatchdogEvent = @ptrCast(@alignCast(dlsym(handle, "systivate_emitWatchdogEvent") orelse {
            log.warn("missing symbol: systivate_emitWatchdogEvent", .{});
            _ = dlclose(handle);
            return;
        })),
        .emitTopWatchdogEvent = @ptrCast(@alignCast(dlsym(handle, "systivate_emitTopWatchdogEvent") orelse {
            log.warn("missing symbol: systivate_emitTopWatchdogEvent", .{});
            _ = dlclose(handle);
            return;
        })),
        .emitPagePruneEvent = @ptrCast(@alignCast(dlsym(handle, "systivate_emitPagePruneEvent") orelse {
            log.warn("missing symbol: systivate_emitPagePruneEvent", .{});
            _ = dlclose(handle);
            return;
        })),
    };

    // Swap vtable and handle BEFORE closing old dylib.
    // The renderer thread reads current_vtable every frame (~120fps).
    // If we dlclose first, the renderer could call through stale function
    // pointers into unmapped memory → SIGSEGV.
    //
    // Intentionally leak the old dylib handle rather than closing it:
    // dlclose would unmap code pages, but the renderer may still be
    // mid-call through a function pointer from the old vtable. The struct
    // copy of current_vtable is not atomic (32 bytes on arm64), so even
    // swapping before dlclose leaves a tiny race. Leaking eliminates it
    // entirely — cost is ~one dylib's worth of mapped pages per reload.
    const old_handle = dylib_handle;
    _ = old_handle; // intentionally leaked

    dylib_handle = handle;
    current_vtable = new_vtable;
    dylib_version += 1;

    // Load behavioral flags from the dylib (optional symbols).
    // systivate_getFixupMode returns the viewport fixup strategy:
    //   0 = v2_keep_pin (default), 1 = v1_snap_top, 2 = v0_snap_active
    if (dlsym(handle, "systivate_getFixupMode")) |sym| {
        const getMode: *const fn () u8 = @ptrCast(@alignCast(sym));
        const mode = getMode();
        systivate_flags.fixup_mode.store(mode, .release);
        log.info("dylib set fixup_mode={d}", .{mode});
    }

    log.info("loaded telemetry dylib v{d} from {s}", .{ dylib_version, std.mem.sliceTo(path, 0) });
}

fn performReload() void {
    if (getDylibPath()) |path| {
        log.info("hot-swap: reloading telemetry dylib", .{});
        loadDylib(path);
    } else {
        // No dylib found — revert to builtin.
        // Swap vtable first, then leak old handle (same rationale as loadDylib).
        current_vtable = builtin_vtable;
        dylib_handle = null;
        systivate_flags.fixup_mode.store(0, .release);
        log.info("hot-swap: reverted to builtin telemetry (fixup_mode=0)", .{});
    }
}

fn installSignalHandler() void {
    // SIGUSR1 triggers telemetry dylib reload
    const handler = posix.Sigaction{
        .handler = .{ .handler = sigusr1Handler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.USR1, &handler, null);
}

fn sigusr1Handler(_: c_int) callconv(.c) void {
    // Signal-safe: just set the atomic flag
    reload_requested.store(true, .release);
}

// ── Scrollback override file reader ──

var override_path_buf: [512]u8 = undefined;

/// Check ~/.ccs/ghostty-scrollback-override for a scrollback byte limit.
/// Rate-limited: reads the file at most once every 5 seconds.
/// File format: a single decimal number (bytes), or empty/missing to clear.
/// Called from vtable() on the renderer thread each frame.
fn checkScrollbackOverride() void {
    const S = struct {
        var last_check_ms: i64 = 0;
    };
    const now_ms = std.time.milliTimestamp();
    if (now_ms - S.last_check_ms < 5000) return;
    S.last_check_ms = now_ms;

    const home = posix.getenv("HOME") orelse return;
    const path_z = std.fmt.bufPrintZ(&override_path_buf, "{s}/.ccs/ghostty-scrollback-override", .{home}) catch return;

    // Open the file. If missing, clear the override (normal state).
    const fd = posix.open(path_z, .{ .ACCMODE = .RDONLY }, 0) catch {
        const prev = systivate_flags.scrollback_override.load(.acquire);
        if (prev != 0) {
            systivate_flags.scrollback_override.store(0, .release);
            log.info("scrollback override cleared (file removed)", .{});
        }
        return;
    };
    defer posix.close(fd);

    var buf: [64]u8 = undefined;
    const n = posix.read(fd, &buf) catch {
        systivate_flags.scrollback_override.store(0, .release);
        return;
    };

    const trimmed = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (trimmed.len == 0) {
        systivate_flags.scrollback_override.store(0, .release);
        return;
    }

    const value = std.fmt.parseInt(usize, trimmed, 10) catch {
        log.warn("scrollback override: invalid value '{s}'", .{trimmed});
        return;
    };

    const prev = systivate_flags.scrollback_override.load(.acquire);
    if (value != prev) {
        systivate_flags.scrollback_override.store(value, .release);
        log.info("scrollback override updated: {d} bytes", .{value});
    }
}

/// Clean up. Called at process exit.
pub fn deinit() void {
    if (dylib_handle) |handle| {
        _ = dlclose(handle);
        dylib_handle = null;
    }
    current_vtable = builtin_vtable;
}
