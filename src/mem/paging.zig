const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const arch = kernel.arch;
const paging = arch.paging;
const mem = kernel.mem;
const limine = kernel.limine;
const vmm = kernel.vmm;
const pmm = kernel.pmm;

const PhysAddr = kernel.types.PhysAddr;
const VirtAddr = kernel.types.VirtAddr;
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
        var addr = VirtAddr.from(page);
        addr.v -= vmm.virt_map_start;
        addr.v /= @sizeOf(Page);
        addr.v *= PageSize.default().get();
        return PhysAddr.from(addr.v);
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

pub fn mapIntervalAlloc(
    start: VirtAddr,
    end: VirtAddr,
    vm_opt: ?paging.VMBase,
    options: paging.Options
) !void {
    std.debug.assert(start.v < end.v);
    var virt = start;
    var new_options = options;
    // Prevent having to retrieve the base in every paging.map call
    const vm_base = vm_opt orelse paging.VMBase.current();

    while (virt.v < end.v) {
        var page_size = PageSize.alignedAllocable(start);
        while (virt.v + page_size.get() > end.v) page_size = page_size.lower().?; // Safe to unwrap as the start and end should be page aligned
        // NOTE: this could result in an OOM even though pages of a lower order are still available
        const page = try pmm.allocPages(page_size.order(), .{});
        new_options.page_size = page_size;
        try paging.map(page.get(), virt, vm_base, new_options);
        virt.v += page_size.get();
    }
}