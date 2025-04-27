const std = @import("std");
const root = @import("root");

pub const serial = @import("serial.zig");
pub const paging = @import("paging.zig");
pub const interrupts = @import("interrupts.zig");
pub const cpuid = @import("cpuid.zig");

const types = root.types;
const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;

pub fn init() void {
    cpuid.init();
}