const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const arch = root.arch;
const paging = arch.paging;
const mem = root.mem;

const PhysAddr = root.types.PhysAddr;
const VirtAddr = root.types.VirtAddr;
const Error = mem.Error;
const PageSize = paging.PageSize;
const Caching = paging.Caching;

pub const Options = struct {
    page_size: PageSize = .default,
    read_only: bool = false,
    executable: bool = true,
    user: bool = false,
    caching: Caching = .default,
    global: bool = false,
    /// Whether the limine HHDM should be used instead of our own and pmm.alloc called with the early option
    comptime early: bool = false,
};

pub const map = paging.map;