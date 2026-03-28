//! Systivate shared memory telemetry surface.
//!
//! Exports live viewport state to a memory-mapped region that external
//! observers can read without IPC overhead. Uses a seqlock for lock-free
//! single-writer / multi-reader safety.
//!
//! Observer opens: shm_open("/ghostty_systivate", O_RDONLY) + mmap
//! Writer (renderer): calls update() each frame (~120fps)

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_shm);

// ── Shared state struct (extern for stable C ABI) ──

pub const TelemetryState = extern struct {
    /// Seqlock counter. Odd = write in progress, even = consistent.
    /// Reader must check seq before AND after reading — if different or odd, retry.
    seq: std.atomic.Value(u64) align(8) = std.atomic.Value(u64).init(0),

    // ── Viewport ──
    /// 0 = active (bottom), 1 = top, 2 = pin (scrolled somewhere in between)
    viewport: u8 = 0,
    /// Last SnapReason (bottom) enum value. See PageList.SnapReason.
    last_snap_reason: u8 = 0,
    /// Last TopSnapReason enum value. See PageList.TopSnapReason.
    last_top_snap_reason: u8 = 0,
    _pad1: u8 = 0,

    // ── Counters ──
    /// Cumulative page prunes since process start.
    prune_count: u32 = 0,
    /// Total renderer frames since process start.
    frame_count: u64 = 0,

    // ── Timestamps (unix epoch seconds) ──
    last_snap_to_bottom_ts: i64 = 0,
    last_snap_to_top_ts: i64 = 0,
    last_prune_ts: i64 = 0,

    // ── Config ──
    scroll_on_output: u8 = 0,
    _pad2: [3]u8 = .{ 0, 0, 0 },

    /// Number of active terminal surfaces in this process.
    surface_count: u32 = 0,

    // ── Identity ──
    pid: i64 = 0,

    /// Which surface last wrote this state (hash of surface pointer).
    surface_id: u64 = 0,
};

comptime {
    // Ensure struct has predictable size for cross-process reads.
    if (@sizeOf(TelemetryState) > 256) @compileError("TelemetryState too large");
}

// ── Shared memory handle ──

const SHM_NAME = "/ghostty_systivate";

var shm_ptr: ?*TelemetryState = null;
var shm_fd: ?posix.fd_t = null;

extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: posix.mode_t) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) c_int;

/// Initialize the shared memory telemetry surface.
/// Called once at process startup. Idempotent — safe to call multiple times.
pub fn init() void {
    // Systivate: diagnostic before any early exit
    const ptr_val: usize = if (shm_ptr) |p| @intFromPtr(p) else 0;
    @import("systivate_telemetry.zig").emitInitDiagnostic("shm_init_entry", ptr_val);
    if (shm_ptr != null) return;

    const O_CREAT: c_int = 0x0200;
    const O_RDWR: c_int = 0x0002;
    const fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0o644);
    if (fd < 0) {
        const errno_val = std.c._errno().*;
        log.warn("shm_open failed: errno={d}", .{errno_val});
        @import("systivate_telemetry.zig").emitInitDiagnostic("shm_open_failed", @as(usize, @intCast(errno_val)));
        return;
    }

    posix.ftruncate(@intCast(fd), @sizeOf(TelemetryState)) catch |err| {
        log.debug("ftruncate failed: {}", .{err});
        _ = posix.close(@intCast(fd));
        return;
    };

    const mapped = posix.mmap(
        null,
        @sizeOf(TelemetryState),
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    ) catch |err| {
        log.debug("mmap failed: {}", .{err});
        _ = posix.close(@intCast(fd));
        return;
    };

    const ptr: *TelemetryState = @ptrCast(@alignCast(mapped));
    ptr.* = .{}; // zero-initialize
    ptr.pid = @as(i64, @intCast(std.c.getpid()));

    shm_ptr = ptr;
    shm_fd = @intCast(fd);

    log.info("shared memory telemetry surface initialized at {s}", .{SHM_NAME});
    @import("systivate_telemetry.zig").emitInitDiagnostic("shm_init_ok", @as(usize, @intCast(fd)));
}

/// Write current viewport state to shared memory.
/// Called from the renderer thread each frame. Lock-free via seqlock.
pub fn update(state: struct {
    viewport: u8,
    snap_reason: u8,
    top_snap_reason: u8,
    prune_count: u32,
    scroll_on_output: bool,
    surface_id: u64,
}) void {
    const ptr = shm_ptr orelse return;

    // Seqlock: increment to odd (write in progress)
    const seq = ptr.seq.load(.acquire);
    ptr.seq.store(seq +% 1, .release);

    // Write state — capture old prune_count BEFORE overwriting for timestamp comparison
    const old_prune_count = ptr.prune_count;
    ptr.viewport = state.viewport;
    ptr.last_snap_reason = state.snap_reason;
    ptr.last_top_snap_reason = state.top_snap_reason;
    ptr.prune_count = state.prune_count;
    ptr.scroll_on_output = if (state.scroll_on_output) 1 else 0;
    ptr.surface_id = state.surface_id;
    ptr.surface_count = 1; // At least 1 surface is active if update() is called
    ptr.frame_count +%= 1;

    const now = std.time.timestamp();
    if (state.snap_reason != 0 and state.viewport == 0) {
        ptr.last_snap_to_bottom_ts = now;
    }
    if (state.top_snap_reason != 0 and state.viewport == 1) {
        ptr.last_snap_to_top_ts = now;
    }
    if (state.prune_count != old_prune_count) {
        ptr.last_prune_ts = now;
    }

    // Seqlock: increment to even (write complete)
    ptr.seq.store(seq +% 2, .release);
}

/// Clean up shared memory. Called at process exit.
pub fn deinit() void {
    if (shm_ptr) |ptr| {
        posix.munmap(@ptrCast(ptr), @sizeOf(TelemetryState));
        shm_ptr = null;
    }
    if (shm_fd) |fd| {
        _ = posix.close(fd);
        shm_fd = null;
    }
    _ = shm_unlink(SHM_NAME);
}

/// Async-signal-safe crash cleanup. Only calls shm_unlink (which is signal-safe).
/// Prevents stale SHM segments that block future processes with EACCES.
pub fn crashCleanup() void {
    _ = shm_unlink(SHM_NAME);
}
