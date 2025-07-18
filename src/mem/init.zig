const std = @import("std");
const root = @import("root");

const paging = root.paging;
const limine = root.limine;
const types = root.types;
const vmm = root.vmm;
const pmm = root.pmm;
const arch = root.arch;
const mem = root.mem;
const heap = root.heap;

const PageSize = paging.PageSize;
const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;
const Page = paging.Page;
const Error = mem.Error;

pub var page_list = TemporaryPageList{};

/// This is a linked list where each node contains a list of pages that were used during the initialization of the first
/// VMM. It prevents relying on arbitrarily sized buffers.
/// Only supports adding entries, not removing them.
const TemporaryPageList = struct {
    const pages_per_node = PageSize.default().get() / @sizeOf(PhysAddr) - @sizeOf(?*Node);
    first: ?*Node = null,
    last: ?*Node = null,
    pages_in_last_node: usize = undefined,
    memmap_index: usize = 0,
    memmap_entry_index: usize = 0,

    /// One Node takes up at most the space available in a default page
    const Node = extern struct {
        next: ?*Node,
        /// Physical addresses of pages
        pages: [pages_per_node]PhysAddr,

        comptime {
            std.debug.assert(@sizeOf(Node) <= PageSize.default().get());
        }
    };

    /// Finds an usable page, adds it to the list and returns it
    pub fn getPage(this: *TemporaryPageList) PhysAddr {
        const default_page_size = PageSize.default().get();
        const memmap = limine.getMemoryMap();
        const entries = memmap.entries[0..memmap.entry_count];

        var current_entry = entries[this.memmap_index].*;
        var page: PhysAddr = undefined;

        if (current_entry.type != @intFromEnum(limine.MemmapType.usable) or this.memmap_entry_index * default_page_size >= current_entry.length) {
            this.memmap_entry_index = 0;
            this.memmap_index += 1;
            // Iterate through the memmap entries until we find the next usable one
            while (entries[this.memmap_index].*.type != @intFromEnum(limine.MemmapType.usable)) {
                this.memmap_index += 1;
                if (this.memmap_index >= memmap.entry_count)
                    @panic("Ran out of memory during initialization of the first VMM");
            }

            current_entry = entries[this.memmap_index].*;
        }
        // Current memmap is (now) usable memory and we've not already used up all its pages
        page = PhysAddr.from(current_entry.base + this.memmap_entry_index * default_page_size);
        this.memmap_entry_index += 1;

        if (this.pages_in_last_node >= pages_per_node or this.last == null) {
            // Use the page as a new node
            const node = limine.get(page).to(*Node);
            node.next = null;

            if (this.last) |last| {
                last.next = node;
            } else {
                this.first = node;
            }
            this.last = node;
            this.pages_in_last_node = 0;

            return this.getPage();
        }

        // Add the page to the list and return
        this.last.?.pages[this.pages_in_last_node] = page;
        this.pages_in_last_node += 1;
        return page;
    }

    /// Returns the number of pages contained in the list
    pub fn usedPages(this: TemporaryPageList) usize {
        var node = this.first orelse return 0;
        var count: usize = 0;

        while (node.next) |new_node| {
            count += pages_per_node;
            node = new_node;
        }

        count += this.pages_in_last_node;
        return count;
    }
};

/// Create the first VMM and switch to it
/// Also switches to the relevant kernel stack then jumps to the provided address
pub fn init(next: VirtAddr) !noreturn {
    const memmap = limine.getMemoryMap();
    pmm.logMemmap();

    // New VMBase
    const vmbase_pg = page_list.getPage();
    const bytes = limine.get(vmbase_pg).toSlice(u8, PageSize.default().get());
    @memset(bytes, 0);
    const base = paging.VMBase.current().copy(vmbase_pg);

    // Identity map + kernel
    const entries = memmap.entries[0..memmap.entry_count];
    for (entries) |memmap_entry| {
        const entry = memmap_entry.*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);

        const start = PhysAddr.from(entry.base);
        const end = PhysAddr.from(entry.base + entry.length);
        if (end.v >= vmm.hhdm_size) {
            std.log.warn("Memory found above 64TiB, will not be mapped", .{});
            break;
        }

        const virt = VirtAddr.from(entry.base + vmm.hhdm_start);

        switch (entry_type) {
            .reserved, .bad_memory => continue,
            .executable_and_modules => {
                try mapInterval(start, end, virt, base, .{
                    .global = true,
                    .early = true,
                });

                // Map the kernel code
                const kernel_virt = VirtAddr.from(vmm.kernel_start);
                try mapInterval(start, end, kernel_virt, base, .{
                    .global = true,
                    .early = true,
                });
            },
            .framebuffer => try mapInterval(start, end, virt, base, .{
                .caching = .write_combining,
                .global = true,
                .early = true,
            }),
            else => try mapInterval(start, end, virt, base, .{
                .global = true,
                .early = true,
            }),
        }
    }

    // Map the new stack
    var current_stack_page = VirtAddr.from(vmm.stack_region_start); // Stack end
    const stack_start = VirtAddr.from(vmm.stack_region_start + vmm.stack_size);
    const page_size = PageSize.default().get();
    std.debug.assert(vmm.stack_size % page_size == 0);

    while (current_stack_page.v < stack_start.v) {
        const stack_page = page_list.getPage();
        try paging.map(stack_page, current_stack_page, base, .{
            .global = true,
            .early = true,
        });
        current_stack_page.v += page_size;
    }

    // Virtual memory map
    var last_addr: usize = 0;
    var last_mapped_page: VirtAddr = VirtAddr.from(0);
    for (entries) |memmap_entry| {
        const entry = memmap_entry.*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);

        switch (entry_type) {
            .usable, .bootloader_reclaimable, .acpi_reclaimable => {
                if (entry.base > last_addr) {
                    // Fill the hole with zeroed-out pages to prevent VMM page checks (for example from the PMM)
                    // resulting in page faults
                    const start = VirtAddr.from(PhysAddr.from(last_addr).page()).alignUp2(page_size);
                    const end = VirtAddr.from(PhysAddr.from(entry.base).page()).alignDown2(page_size);
                    try paging.mapZero(start, end, base, .{
                        .early = true,
                        .executable = false,
                        .global = true,
                        .read_only = true,
                        .user = false,
                    });
                }

                const start = VirtAddr.from(PhysAddr.from(entry.base).page()).alignDown2(page_size);
                const end = VirtAddr.from(PhysAddr.from(entry.base + entry.length).page()).add(@sizeOf(Page)).alignUp2(page_size);
                var current = start;
                // Prevent mapping an already mapped page
                if (current.v == last_mapped_page.v) current = current.add(page_size);
                while (current.v < end.v) {
                    const new_page = page_list.getPage();
                    @memset(limine.get(new_page).toSlice(u8, page_size), 0);
                    try paging.map(new_page, current, base, .{
                        .early = true,
                        .executable = false,
                        .global = true,
                        .user = false,
                    });
                    current = current.add(page_size);
                }
                last_addr = entry.base + entry.length;
                last_mapped_page = end.sub(page_size);
            },
            else => {},
        }
    }
    const end = VirtAddr.from(vmm.virt_map_start + vmm.virt_map_size);
    const start = VirtAddr.from(PhysAddr.from(last_addr).page()).alignUp2(page_size);
    std.debug.assert(start.v <= end.v);
    // Fill the last hole
    try paging.mapZero(start, end, base, .{
        .early = true,
        .executable = false,
        .global = true,
        .read_only = true,
        .user = false,
    });

    // Switch to the new VMBase, set the stack and jump to the next function
    base.enable(stack_start, next);
}

pub fn mapInterval(
    start: PhysAddr,
    end: PhysAddr,
    virt_start: VirtAddr,
    vm_opt: ?paging.VMBase,
    options: paging.Options
) !void {
    // This function could be implemented in an arch specific way to improve performance a bit (mostly reduce redundant
    // checks in map calls)
    std.debug.assert(start.v < end.v);
    const page_size = @intFromEnum(options.page_size);
    var phys = start;
    var virt = virt_start;

    while (phys.v < end.v) {
        try paging.map(phys, virt, vm_opt, options);
        phys.v += page_size;
        virt.v += page_size;
    }
}
