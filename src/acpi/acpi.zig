const std = @import("std");
const zuacpi = @import("zuacpi");

const impl = @import("impl.zig");

const uacpi = zuacpi.uacpi;

// TODO use a real allocator
var buffer: [32768]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
pub const allocator = fba.threadSafeAllocator();

comptime {
    _ = impl;
}

pub const initialize = uacpi.initialize;