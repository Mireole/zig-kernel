const kernel = @import("kernel");
const std = @import("std");

const tests = kernel.tests;
const pmm = kernel.pmm;
const heap = kernel.heap;

const Page = kernel.paging.Page;

const AllocatedPage = struct {
    page: *Page,
    order: u8,
};

test "pmm" {
    const max_allocs = 16384;
    const num_tests = 16384;
    const pages = try heap.alloc(AllocatedPage, max_allocs);
    defer heap.free(pages);
    const free_blocks_before = pmm.freeBlocks();

    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng.random();

    var allocated: usize = 0;
    for (0..num_tests) |test_index| {
        // Fill the allocation buffer
        while (allocated < max_allocs) {
            const order = random.intRangeAtMost(u8, 0, pmm.max_order);
            pages[allocated] = .{
                .page = pmm.allocPages(order, .{}) catch break,
                .order = order,
            };
            allocated += 1;
        }
        // Free some of it
        const target_size = blk: {
            if (test_index < num_tests - 1)
                break :blk random.intRangeAtMost(usize, 0, allocated);
            break :blk 0;
        };
        while (allocated > target_size) {
            allocated -= 1;
            const page = pages[allocated];
            pmm.freePages(page.page, page.order);
        }
    }

    const free_blocks_after = pmm.freeBlocks();
    try tests.expectEqual(free_blocks_before, free_blocks_after);
}