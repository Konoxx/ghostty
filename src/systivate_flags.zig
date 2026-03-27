//! Systivate runtime behavior flags.
//!
//! Atomic flags that control viewport and resource behavior at runtime.
//! Set by the hot-swap system when a dylib is loaded or by the scrollback
//! override file reader. Read by PageList each frame.
//!
//! Default (0) = v2 "keep pin" — prevents both rubber-band and snap-to-top.
//! Hot-swap can override to other modes for testing or rollback.

const std = @import("std");

/// Viewport fixup strategy when a pin drifts into the active area
/// or a page is pruned under the viewport.
///
///   0 = v2_keep_pin   — keep .pin, don't snap anywhere (default)
///   1 = v1_snap_top   — snap to .top (legacy Systivate)
///   2 = v0_snap_active — snap to .active (original Ghostty, rubber-band)
pub var fixup_mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Scrollback override limit in bytes. Set by ProcessRhythm via
/// ~/.ccs/ghostty-scrollback-override when CPU pressure is detected.
///
///   0 = no override (use configured explicit_max_size)
///   >0 = cap scrollback to this many bytes in PageList.maxSize()
///
/// PageList's existing page pruning in grow() handles shrinking naturally.
pub var scrollback_override: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Telemetry emission toggle. Set via IPC: "set telemetry off".
/// Checked by systivate_telemetry.zig emit functions for early-return.
///   true  = telemetry active (default)
///   false = telemetry suppressed (events not written to JSONL)
pub var telemetry_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

/// Cumulative PTY output bytes. Incremented by termio thread on each write batch.
/// IPC reads this to compute output rate (bytes/sec) for generating/idle detection.
pub var output_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Active surface (tab) count. Updated by the app when surfaces are added/removed.
/// Authoritative tab count — replaces osascript-based counting.
pub var surface_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
