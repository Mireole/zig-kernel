const std = @import("std");
const kernel = @import("kernel");

pub const init = @import("init.zig");

pub const Error = error{
    OutOfMemory,
    MappingAlreadyExists,
};
