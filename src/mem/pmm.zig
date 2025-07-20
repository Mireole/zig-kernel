// Simple buddy allocator
// TODO PERF

const std = @import("std");
const kernel = @import("kernel");

const limine = kernel.limine;
const vmm = kernel.vmm;
const mem = kernel.mem;
const smp = kernel.smp;
const paging = kernel.paging;
const types = kernel.types;
const heap = kernel.heap;

const Spinlock = smp.Spinlock;
const PageSize = paging.PageSize;
const PageOptions = paging.PageOptions;
const Page = paging.Page;
const VirtAddr = types.VirtAddr;
const PhysAddr = types.PhysAddr;

const assert = std.debug.assert;

const Error = error {
    OutOfMemory,
};

const smallest_block_size = PageSize.default().get();
const min_block_order = std.math.log2(smallest_block_size);
pub const max_order = 9; // 2 MiB blocks

const Block = struct {
    next: ?*Block,
    prev: ?*Block,

    pub inline fn buddy(block: *Block, order: usize) *Block {
        var addr = VirtAddr.from(block);
        // The bit that should be inverted to get the buddy's address
        // Could be a LUT but I doubt this could positively impact performance
        const shift: u6 = @intCast(min_block_order + order);
        const bit = @as(usize, 1) << shift;
        addr.v ^= bit;
        return addr.to(*Block);
    }

    pub inline fn parent(block: *Block, current_order: usize) *Block {
        var addr = VirtAddr.from(block);
        const shift: u6 = @intCast(min_block_order + current_order);
        const bit = @as(usize, 1) << shift;
        addr.v &= ~bit;
        return addr.to(*Block);
    }

    pub inline fn page(block: *Block) *Page {
        return VirtAddr.from(block).page();
    }
};

const BlockList = struct {
    first: ?*Block,
};

var blocks: [max_order + 1]BlockList = @splat(.{ .first = null });
var lock: Spinlock = .{};

/// Initialization of the PMM
pub fn init() void {
    // Update the memory map pointers for the new HHDM
    limine.updateMemoryMap();

    std.log.debug("Initialising PMM...", .{});
    const page_list = &mem.init.page_list;
    const memmap = limine.getMemoryMap();
    const memmap_entries = memmap.entries[0..memmap.entry_count];
    for (memmap_entries, 0..) |entry_ptr, index| {
        const entry = entry_ptr.*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);
        // Used pages in this entry
        var current_page: usize = 0;

        switch (entry_type) {
            .usable => {
                if (index < page_list.memmap_index) continue;
                if (index == page_list.memmap_index) current_page = page_list.memmap_entry_index;
            },
            // Can't reclaim the memory map because we are iterating over it right now
            .bootloader_reclaimable => continue,
            else => continue,
        }

        const total_pages = entry.length / smallest_block_size;
        while (current_page < total_pages) {
            // Directly using freeBlock so we avoid taking the lock for no reason
            // TODO Perf merge free memory before inserting
            const block = PhysAddr.from(entry.base + current_page * smallest_block_size).hhdm().to(*Block);
            freeBlock(block, 0);
            current_page += 1;
        }
    }
    std.log.debug("PMM init... OK", .{});
    logStats();
}

pub fn logMemmap() void {
    const memmap = limine.getMemoryMap();
    std.log.debug("Memory map:", .{});
    const memmap_entries = memmap.entries[0..memmap.entry_count];
    for (memmap_entries, 0..) |entry_ptr, i| {
        const entry = entry_ptr.*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);
        std.log.debug("Entry 0x{X:0>2}: Base=0x{X:0>16}, Length=0x{X:0>16}, End=0x{X:0>16}, Type={s}", .{
            i,
            entry.base,
            entry.length,
            entry.base + entry.length,
            @tagName(entry_type),
        });
    }
}

pub fn freeBlocks() [max_order + 1]usize {
    var block_count: [max_order + 1]usize = undefined;
    for (blocks, 0..) |block_list, order| {
        var node = block_list.first;
        var count: usize = 0;
        while (node) |block| {
            count += 1;
            node = block.next;
        }
        block_count[order] = count;
    }
    return block_count;
}

pub fn logStats() void {
    std.log.debug("Buddy statistics:", .{});
    for (blocks, 0..) |block_list, order| {
        var node = block_list.first;
        var count: usize = 0;
        while (node) |block| {
            count += 1;
            node = block.next;
        }
        std.log.debug("\tOrder={} (Size=0x{x}), Count={}", .{ order, smallest_block_size << @intCast(order), count });
    }
}

const order_shift = std.math.log2(PageSize.default().get());
pub inline fn getOrder(size: usize) usize {
    const shifted = (size - 1) >> order_shift;
    return @sizeOf(usize) * 8 - @clz(shifted);
}

/// Allocates a single physical page
pub fn allocPage(options: PageOptions) Error!*Page {
    return allocPages(0, options);
}

/// Allocates 2^order contiguous physical pages
pub fn allocPages(order: usize, options: PageOptions) Error!*Page {
    assert(order <= max_order);
    // For now, just lock unconditionally
    const interrupts = lock.lock();
    defer lock.unlock(interrupts);

    const block = try getFreeBlock(order, options);
    return block.page();
}

/// The internal memory block allocation function
/// Assumes the order is sane (<= max_order), and that the lock was previously acquired
fn getFreeBlock(order: usize, options: PageOptions) Error!*Block {
    const maybeBlock = blocks[order].first;

    if (maybeBlock) |block| {
        // A valid block was found, update the BlockList and return it
        blocks[order].first = block.next;
        if (block.next) |next| {
            next.prev = null;
        }
        block.page().page_type = .default;
        return block;
    }
    // No valid block was found
    if (order == max_order) {
        // No more blocks to split, OOM
        return Error.OutOfMemory;
    }

    // Split (recursive)
    const bigger_block = try getFreeBlock(order + 1, options);
    const buddy = VirtAddr.from(bigger_block).to(*Block).buddy(order);
    buddy.next = null;
    buddy.prev = null;
    blocks[order].first = buddy;

    const buddy_page = buddy.page();
    buddy_page.page_type = .buddy;
    buddy_page.buddy_order = @intCast(order);

    bigger_block.page().page_type = .default;

    return bigger_block;
}

/// Frees a single physical page
pub fn freePage(page: *Page) void {
    return freePages(page, 0);
}

/// Frees 2^order contiguous physical pages
pub fn freePages(pages: *Page, order: usize) void {
    assert(order <= max_order);
    // For now, just lock unconditionally
    const interrupts = lock.lock();
    defer lock.unlock(interrupts);

    const block = pages.get().hhdm().to(*Block);
    freeBlock(block, order);
}

/// The internal memory block freeing function
/// Assumes the order is sane (<= max_order), and that the lock was previously acquired
fn freeBlock(block: *Block, order: usize) void {
    var expanded_block = block;
    var loop_order = order;

    // Merging free blocks
    while (loop_order < max_order) {
        const buddy = expanded_block.buddy(loop_order);
        const buddy_page = buddy.page();
        if (buddy_page.page_type != .buddy or buddy_page.buddy_order != loop_order) break;

        // Remove the buddy from the freelist
        if (buddy.prev) |prev| {
            prev.next = buddy.next;
        }
        else {
            blocks[loop_order].first = buddy.next;
        }
        if (buddy.next) |next| {
            next.prev = buddy.prev;
        }

        expanded_block = expanded_block.parent(loop_order);
        loop_order += 1;
    }

    const page = expanded_block.page();
    page.page_type = .buddy;
    page.buddy_order = @intCast(loop_order);

    // Insert the new block into the freelist
    const old = blocks[loop_order].first;
    expanded_block.next = old;
    expanded_block.prev = null;
    if (old) |old_block| {
        old_block.prev = expanded_block;
    }
    blocks[loop_order].first = expanded_block;
}