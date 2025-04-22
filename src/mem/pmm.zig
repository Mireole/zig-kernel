// Simple buddy allocator

const std = @import("std");
const root = @import("root");
const limine = root.limine;

const min_block_size = 0x4000; // 4 KiB
const max_block_size = 0x200000; // 2 MiB
const orders = @log2(@as(comptime_float, @floatFromInt(max_block_size / min_block_size))) + 1;

const PMM = @This();

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

/// Early initialization of the PMM
///
pub fn earlyInit() void {
    const memmap = limine.getMemoryMap();
    std.log.debug("Memory map:", .{});
    for (0..memmap.entry_count) |i| {
        const entry = memmap.entries[i].*;
        const entry_type: limine.MemmapType = @enumFromInt(entry.type);
        std.log.debug("Entry 0x{X:0>2}: Base=0x{X:0>16}, Length=0x{X:0>16}, End=0x{X:0>16}, Type={s}", .{
            i,
            entry.base,
            entry.length,
            entry.base + entry.length,
            @tagName(entry_type),
        });
        switch (entry_type) {
            .Usable => {},
            else => continue,
        }
        if (entry.base + entry.length >= limine.hhdm_size) continue;
    }
}
