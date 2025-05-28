const std = @import("std");
const root = @import("root");

const paging = root.paging;
const limine = root.limine;
const types = root.types;
const vmm = root.vmm;
const arch = root.arch;

const PageSize = paging.PageSize;
const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;

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

        if (current_entry.type != @intFromEnum(limine.MemmapType.usable)
            or this.memmap_entry_index * default_page_size >= current_entry.length)
        {
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
            }
            else {
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
pub fn init(next: VirtAddr) noreturn {
    const memmap = limine.getMemoryMap();

    // New VMBase
    const page = page_list.getPage();
    const bytes = limine.get(page).toSlice(u8, PageSize.default().get());
    @memset(bytes, 0);
    const base = paging.VMBase.current().copy(page);

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
                paging.mapInterval(start, end, virt, base, .{
                    .global = true,
                    .early = true,
                }) catch |err| std.debug.panic("VMM initialization failed, {}", .{ err });

                // Map the kernel code
                const kernel_virt = VirtAddr.from(vmm.kernel_start);
                paging.mapInterval(start, end, kernel_virt, base, .{
                    .global = true,
                    .early = true,
                }) catch |err| std.debug.panic("VMM initialization failed, {}", .{ err });
            },
            .framebuffer => paging.mapInterval(start, end, virt, base, .{
                .caching = .write_combining,
                .global = true,
                .early = true,
            }) catch |err| std.debug.panic("VMM initialization failed, {}", .{ err }),
            else => paging.mapInterval(start, end, virt, base, .{
                .global = true,
                .early = true,
            }) catch |err| std.debug.panic("VMM initialization failed, {}", .{ err }),
        }
    }

    // Map the new stack
    var current_stack_page = VirtAddr.from(vmm.stack_region_start); // Stack end
    const stack_start = VirtAddr.from(vmm.stack_region_start + vmm.stack_size);
    const page_size = PageSize.default().get();
    std.debug.assert(vmm.stack_size % page_size == 0);

    while (current_stack_page.v < stack_start.v) {
        const stack_page = page_list.getPage();
        paging.map(stack_page, current_stack_page, base, .{
            .global = true,
            .early = true,
        }) catch |err| std.debug.panic("VMM initialization failed, {}", .{ err });
        current_stack_page.v += page_size;
    }

    // Switch to the new VMBase, set the stack (use has to be inlined) and jump to the next function
    base.use(stack_start, next);
}