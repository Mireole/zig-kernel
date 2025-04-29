const std = @import("std");
const root = @import("root");

const arch = root.arch;
const paging = root.paging;

const PhysAddr = root.types.PhysAddr;
const PageSize = paging.PageSize;

pub const hhdm_start = 0xffff800000000000;
// Only for testing purposes, to make sure that we aren't accidentally using something from Limine
// pub const hhdm_start = 0xffff000000000000;
pub const hhdm_size = 0x400000000000; // 64 TiB
pub const kernel_start = 0xffffffff80000000;
/// Start of the kernel stack memory region
pub const stack_region_start = 0xffffffff40000000;
pub const stack_size = 0x10000; // 64 KiB
pub extern const __kernel_end: u8;

const assert = std.debug.assert;
const divCeil = std.math.divCeil;

pub inline fn get(T: anytype, addr: PhysAddr) T {
    assert(addr.v < hhdm_size);
    addr.v += hhdm_start;
    return addr.to(T);
}