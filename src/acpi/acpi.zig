const std = @import("std");
const uacpi = @import("uacpi");

pub const initialize = uacpi.initialize;

comptime {
    _ = @import("impl.zig");
}