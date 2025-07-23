const std = @import("std");
const zuacpi = @import("zuacpi");

const impl = @import("impl.zig");

const uacpi = zuacpi.uacpi;

comptime {
    _ = impl;
}

pub const initialize = uacpi.initialize;
