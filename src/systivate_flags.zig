//! Systivate runtime behavior flags.
//!
//! Atomic flags that control viewport behavior at runtime. Set by the
//! hot-swap system when a dylib is loaded, read by PageList each time
//! fixupViewport runs. This allows viewport strategy changes without
//! restarting Ghostty.
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
