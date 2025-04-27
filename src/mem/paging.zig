const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const arch = root.arch;
const paging = arch.paging;
const mem = root.mem;
const limine = root.limine;

const PhysAddr = root.types.PhysAddr;
const VirtAddr = root.types.VirtAddr;
const Error = mem.Error;

pub const PageSize = paging.PageSize;
pub const Caching = paging.Caching;
pub const VMBase = paging.VMBase;

const assert = std.debug.assert;

pub const Options = struct {
    page_size: PageSize = PageSize.default(),
    read_only: bool = false,
    executable: bool = true,
    user: bool = false,
    caching: Caching = .default,
    global: bool = false,
    /// Whether the limine HHDM and early PMM should be used
    early: bool = false,
};

pub const map = paging.map;

pub fn mapInterval(start: PhysAddr, end: PhysAddr, virt_start: VirtAddr, vm_opt: ?VMBase, options: Options) Error!void {
    // This function could be implemented in an arch specific way to improve performance a bit (mostly reduce redundant
    // checks in map calls)
    assert(start.v < end.v);
    const page_size = @intFromEnum(options.page_size);
    var phys = start;
    var virt = virt_start;

    while (phys.v < end.v) {
        try map(phys, virt, vm_opt, options);
        phys.v += page_size;
        virt.v += page_size;
    }
}