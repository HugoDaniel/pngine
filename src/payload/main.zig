//! Payload module: the carrier-agnostic envelope (FROZEN v1, X0/02.C1) and
//! the kind registry it anchors. Zero dependencies; compiles standalone.

pub const envelope = @import("envelope.zig");
