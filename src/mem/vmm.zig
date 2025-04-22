const std = @import("std");
const root = @import("root");

const PhysAddr = root.types.PhysAddr;

const hhdm_start = 0xffff800000000000;
const hhdm_size = 0x400000000000; // 64 TiB

const assert = std.debug.assert;

pub inline fn get(T: anytype, addr: PhysAddr) T {
    assert(addr.v < hhdm_size);
    addr.v += hhdm_start;
    return addr.to(T);
}