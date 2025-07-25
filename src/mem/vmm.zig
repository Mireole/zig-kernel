const std = @import("std");
const kernel = @import("kernel");

const arch = kernel.arch;
const paging = kernel.paging;

const PhysAddr = kernel.types.PhysAddr;
const VirtAddr = kernel.types.VirtAddr;
const PageSize = paging.PageSize;

pub const hhdm_start = 0xffff800000000000;
pub const hhdm_size = 0x400000000000; // 64 TiB
pub const kernel_start = 0xffffffff80000000;
pub const virt_map_start = 0xffffc00000000000;
pub const virt_map_size = 0x10000000000; // 1 TiB
pub const virt_alloc_start = 0xffffc10000000000;
pub const virt_alloc_size = 0x10000000000; // 1 TiB
/// Start of the kernel stack memory region
// TODO just use the HHDM (requires a refactor of the temp page list to allocate contiguous mem)
pub const stack_region_start = 0xffffffff40000000;
pub const stack_size = 0x10000; // 64 KiB
pub extern const __kernel_end: u8;

const assert = std.debug.assert;

// Very simple watermark allocator for now (we have 1TiB anyway, surely that won't run out :^) )
var last_alloc: usize = virt_alloc_start;

pub fn alloc(size: usize) !VirtAddr {
    const start = VirtAddr.from(last_alloc);
    const end = start.add(size).alignUp2(PageSize.default().get());
    try paging.mapIntervalAlloc(start, end, null, .{
        .global = true,
        .executable = false,
    });
    return start;
}

pub inline fn get(addr: PhysAddr) VirtAddr {
    assert(addr.v < hhdm_size);
    return VirtAddr.from(addr.v + hhdm_start);
}
