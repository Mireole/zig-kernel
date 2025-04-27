// Simple buddy allocator

const std = @import("std");
const root = @import("root");

const limine = root.limine;
const vmm = root.vmm;

const min_block_size = 0x4000; // 4 KiB
const max_block_size = 0x40000000; // 1 GiB
const orders = @log2(@as(comptime_float, @floatFromInt(max_block_size / min_block_size))) + 1;

const Block = struct {
    next: *Block,
};

const BlockList = struct {
    first: ?*Block,
    free: []usize,
};

const MemRegion = struct {
    free: [orders]BlockList,
};

/// Initialization of the PMM
pub fn init() void {
    const memmap = limine.getMemoryMap();
    std.log.debug("Memory map:", .{});
    const memmap_entries = memmap.entries[0..memmap.entry_count];
    var i: usize = 0;
    for (memmap_entries) |entry_ptr| {
        const entry = entry_ptr.*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);
        std.log.debug("Entry 0x{X:0>2}: Base=0x{X:0>16}, Length=0x{X:0>16}, End=0x{X:0>16}, Type={s}", .{
            i,
            entry.base,
            entry.length,
            entry.base + entry.length,
            @tagName(entry_type),
        });
        i += 1;
    }
}
