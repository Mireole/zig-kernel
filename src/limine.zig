const builtin = @import("builtin");
const limine = @import("limine");
const std = @import("std");

// 4GiB
const hhdm_size = 0x1_0000_0000;

// The translation to zig code misses quite a few macros, therefore some of them have to be reimplemented here

const limine_common_magic: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// Equivalent to LIMINE_BASE_REVISION(2)
export var limine_base_revision linksection(".requests") = @as([3]u64,
    .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 }
);

// LIMINE_REQUESTS_START_MARKER
export var limine_requests_start_marker linksection(".requests_start_marker") = @as([4]u64,
    .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 }
);

// LIMINE_REQUESTS_END_MARKER
export var limine_requests_end_marker linksection(".requests_end_marker") = @as([2]u64,
    .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 }
);

// Requests
// Framebuffer request
export var framebuffer_request linksection(".requests") = limine.limine_framebuffer_request{
    .id = limine_common_magic ++ .{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
};

// HHDM request
export var hhdm_request linksection(".requests") = limine.limine_hhdm_request{
    .id = limine_common_magic ++ .{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
};
var hhdm_start: u64 = undefined;

// Kernel address
export var kernel_address_request linksection(".requests") = limine.limine_kernel_address_request{
    .id = limine_common_magic ++ .{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    .revision = 0,
};

pub fn initialize() void{
    preventOptimizations();

    // HHDM start
    if (hhdm_request.response == null) @panic("Cannot retrieve the HHDM start address");
    hhdm_start = hhdm_request.response.*.offset;
}

fn preventOptimizations() void {
    // Without these lines the compiler removes our markers and requests
    // Markers
    std.mem.doNotOptimizeAway(limine_base_revision);
    std.mem.doNotOptimizeAway(limine_requests_start_marker);
    std.mem.doNotOptimizeAway(limine_requests_end_marker);
    // Requests
    std.mem.doNotOptimizeAway(framebuffer_request);
    std.mem.doNotOptimizeAway(hhdm_request);
    std.mem.doNotOptimizeAway(kernel_address_request);
}

pub inline fn limineBaseRevisionSupported() bool {
    // Implementation of the LIMINE_BASE_REVISION_SUPPORTED macro
    return limine_base_revision[2] == 0;
}

pub fn drawLine() void {
    // The framebuffer needs to use 32 bits per pixel for this code to work as intended
    if (framebuffer_request.response == null or framebuffer_request.response.*.framebuffer_count < 1) return;

    const framebuffer = framebuffer_request.response.*.framebuffers[0];

    for (0..100) |i| {
        const fb_ptr: [*]volatile u32 = @alignCast(@ptrCast(framebuffer.*.address));
        fb_ptr[i * (framebuffer.*.pitch / 4) + i] = 0xffffffff;
    }
}

pub inline fn toVirtualAddress(T: type, val: *T) *T {
    const phys_addr: usize = @intFromPtr(val);
    std.debug.assert(phys_addr < hhdm_size);
    const virt_addr: usize = phys_addr + hhdm_start;
    return @ptrFromInt(virt_addr);
}