const std = @import("std");
const root = @import("root");

pub const init = @import("init.zig");

pub const Error = error{
    OutOfMemory,
    MappingAlreadyExists,
};
