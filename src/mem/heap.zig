// General purpose kernel memory allocator
// Currently only a simple first-fit freelist
// TODO PERF: better allocator (slab ?) / nuke the stupid lock out of orbit / don't use the zig allocator when possible
const std = @import("std");
const kernel = @import("kernel");

const paging = kernel.paging;
const types = kernel.types;
const mem = kernel.mem;
const smp = kernel.smp;
const pmm = kernel.pmm;
const vmm = kernel.vmm;

const VirtAddr = types.VirtAddr;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageSize = paging.PageSize;
const Spinlock = smp.Spinlock;
const Page = paging.Page;

const assert = std.debug.assert;

const Error = error {
    OutOfMemory
};

/// A Zig allocator that can be used with the Zig standard library.
/// The allocation functions in this file should be preferred over this when possible due to performance concerns.
pub const allocator = Allocator{ .ptr = undefined, .vtable = &.{
    .alloc = rawAlloc,
    .resize = rawResize,
    .remap = rawRemap,
    .free = rawFree,
} };

/// Minimum size (in bytes) for allocations. All allocations sizes also have to be a multiple of it
const min_alloc = Alignment.@"16";
/// How many pages (2^refill_order) will be requested from the PMM each time the allocator runs out of memory
const refill_order = 2;
const refill_size = PageSize.default().get() * (1 << refill_order);

const FreeBlock = struct {
    next: ?*FreeBlock = null,
    size: usize,

    comptime {
        assert(@sizeOf(FreeBlock) <= min_alloc.toByteUnits());
    }
};

const BlockList = struct {
    /// First free block in the freelist
    first: ?*FreeBlock = null,
    lock: Spinlock = .{},
};

var free_blocks = BlockList{};

pub fn create(T: type) Error!*T {
    return allocator.create(T);
}

pub fn destroy(ptr: anytype) void {
    allocator.destroy(ptr);
}

pub fn alloc(T: type, n: usize) Error![]T {
    return allocator.alloc(T, n);
}

pub fn free(memory: anytype) void {
    allocator.free(memory);
}

fn splitFreeBlock(
    node: *FreeBlock,
    aligned_address: usize,
    previous: ?*FreeBlock,
    alloc_size: usize,
) void {
    var prev_node = previous;
    // Split the free block if needed
    // | FREE | ALLOCATED | FREE |
    // ^      ^           ^      ^
    // |   aligned        |  address + node.size
    // address       aligned + size
    var size = node.size;
    const address = @intFromPtr(node);
    if (address != aligned_address) {
        // Resize the old node
        const new_size = aligned_address - address;
        assert(new_size >= min_alloc.toByteUnits());
        node.size = new_size;
        prev_node = node;
        size -= new_size;
    }
    size -= alloc_size;
    if (size > 0) {
        // Insert a new node
        assert(size >= min_alloc.toByteUnits());
        const new_node: *FreeBlock = @ptrFromInt(address + node.size - size);
        new_node.size = size;
        new_node.next = node.next;

        if (prev_node) |prev| {
            prev.next = new_node;
        } else {
            free_blocks.first = new_node;
        }
    }
    else {
        if (prev_node) |prev| {
            prev.next = node.next;
        }
        else {
            free_blocks.first = node.next;
        }
    }
}

fn insertFreeBlock(
    address: usize,
    size: usize,
    prev: ?*FreeBlock,
    next: ?*FreeBlock,
) *FreeBlock {
    var node: *FreeBlock = undefined;
    if (prev) |prev_node| {
        if (@intFromPtr(prev_node) + prev_node.size == address) {
            // Merge
            prev_node.size += size;
            node = prev_node;
        }
        else {
            node = @ptrFromInt(address);
            node.size = size;
            prev_node.next = node;
        }
    }
    else {
        node = @ptrFromInt(address);
        node.size = size;
        free_blocks.first = node;
    }

    if (next) |next_node| {
        if (address + size == @intFromPtr(next_node)) {
            // Merge
            node.size += next_node.size;
            node.next = next_node.next;
        }
        else {
            node.next = next_node;
        }
    }
    else {
        node.next = null;
    }
    return node;
}

// Zig allocator implementation
fn rawAlloc(_: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const size = min_alloc.forward(n);
    if (size >= PageSize.default().get()) {
        const order = pmm.getOrder(size);
        const pages = pmm.allocPages(order, .{}) catch return null;
        return vmm.get(pages.get()).to([*]u8);
    }
    // Acquire the lock
    const interrupts = free_blocks.lock.lock();
    defer free_blocks.lock.unlock(interrupts);
    // Scan the freelist
    var curr_node = free_blocks.first;
    var prev_node: ?*FreeBlock = null;
    while (curr_node) |node| : ({
        prev_node = curr_node;
        curr_node = node.next;
    }) {
        if (node.size < size) continue;

        const address = @intFromPtr(node);
        const aligned = alignment.forward(address);
        const aligned_size = node.size - (aligned - address);
        if (aligned_size < size) continue;

        // We found a valid free block!
        splitFreeBlock(node, aligned, prev_node, size);

        return @ptrFromInt(aligned);
    }

    // No valid free block was found, get more pages
    const pages = pmm.allocPages(refill_order, .{}) catch return null;

    // As we don't know where in the HHDM this page will be, we need to insert the new free node in the right place
    const address = vmm.get(pages.get()).to(usize);

    // We now have a valid free block, we just need to insert it in the right location then split it again
    const new_node = insert: {
        // Fast paths
        if (prev_node == null) {
            // No node in the freelist
            break :insert insertFreeBlock(address, refill_size, null, null);
        }
        const last_node = prev_node.?;
        if (@intFromPtr(last_node) + last_node.size <= address) {
            // The new node should be inserted after the last
            break :insert insertFreeBlock(address, refill_size, last_node, null);
        }

        // Slow path, scan the freelist to find the right interval
        curr_node = free_blocks.first;
        prev_node = null;
        while (curr_node) |node| : ({
            prev_node = curr_node;
            curr_node = node.next;
        }) {
            if (@intFromPtr(node) > address) {
                break :insert insertFreeBlock(address, refill_size, prev_node, curr_node);
            }
        }
        // We should never be able to reach the end of this loop as the right interval has to be inside the freelist
        unreachable;
    };

    const aligned = alignment.forward(address);
    splitFreeBlock(new_node, aligned, prev_node, size);

    return @ptrFromInt(aligned);
}

fn rawResize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    // TODO proper resize
    return false;
}

fn rawRemap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, stack: usize) ?[*]u8 {
    // TODO proper remap
    const new = rawAlloc(context, new_len, alignment, stack) orelse return null;
    const size = if(memory.len < new_len) memory.len else new_len;
    @memcpy(new[0..size], memory[0..size]);
    rawFree(context, memory, alignment, stack);
    return new;
}

fn rawFree(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const address = @intFromPtr(memory.ptr);
    const size = min_alloc.forward(memory.len);

    if (size >= PageSize.default().get()) {
        const order = pmm.getOrder(size);
        const page = VirtAddr.from(address).page();
        pmm.freePages(page, order);
        return;
    }

    // Acquire the lock
    const interrupts = free_blocks.lock.lock();
    defer free_blocks.lock.unlock(interrupts);
    // Scan the freelist to find the right interval
    var curr_node = free_blocks.first;
    var prev_node: ?*FreeBlock = null;
    while (curr_node) |node| : ({
        prev_node = curr_node;
        curr_node = node.next;
    }) {
        if (@intFromPtr(node) > address) {
            _ = insertFreeBlock(address, size, prev_node, curr_node);
            return;
        }
    }
    // We should never be able to reach the end of this loop as the right interval has to be inside the freelist
    unreachable;
}
