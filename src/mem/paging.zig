const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const arch = root.arch;
const paging = arch.paging;
const mem = root.mem;
const limine = root.limine;
const vmm = root.vmm;

const PhysAddr = root.types.PhysAddr;
const VirtAddr = root.types.VirtAddr;
const Error = mem.Error;

pub const PageSize = paging.PageSize;
pub const Caching = paging.Caching;
pub const VMBase = paging.VMBase;

const assert = std.debug.assert;

// Due to the empty sections of the virtual memory map being mapped with zeroed out pages,
// a Page struct with all fields set to 0 must represent a page that cannot be used anywhere
pub const Page = struct {
    pub const Type = enum(u8) {
        default = 0,
        /// A free page in the Buddy allocator
        buddy = 1,
    };

    page_type: Type = .default,
    /// The order of the page in the Buddy allocator
    buddy_order: u8 = undefined,

    pub inline fn get(page: *Page) PhysAddr {
        var addr = PhysAddr.from(page);
        addr.v -= vmm.virt_map_start;
        addr.v /= @sizeOf(Page);
        addr.v *= PageSize.default();
        return addr;
    }
};

pub const PageOptions = struct {};

// TODO replace this with flags ?
pub const Options = struct {
    page_size: PageSize = PageSize.default(),
    read_only: bool = false,
    executable: bool = true,
    user: bool = false,
    caching: Caching = .default,
    global: bool = false,
    /// If set to false, errors when a mapping already exists, otherwise ignores it
    allow_existing: bool = false,
    /// Whether the limine HHDM and early PMM should be used
    /// TODO PERF: extract early functions / add branch hints
    early: bool = false,
};

/// Creates paging structures to map the virtual address to the physical address.
/// If vm_opt is null, the current virtual memory base is used.
pub const map = paging.map;

/// Creates paging structures to map the virtual address to read-only zeroed out pages.
/// If vm_opt is null, the current virtual memory base is used.
pub const mapZero = paging.mapZero;