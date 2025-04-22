const std = @import("std");
const root = @import("root");

pub const Error = error {
    OutOfMemory,
    MappingAlreadyExists,
};