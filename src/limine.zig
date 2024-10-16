const limine = @import("limine");
const std = @import("std");
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
export var limine_framebuffer_request linksection(".requests") = limine.limine_framebuffer_request{
    .id = limine_common_magic ++ .{0x9d5827dcd881dd75, 0xa3148604f6fab11b},
    .revision = 0,
};

pub fn preventOptimizations() void {
    // Without these lines the compiler removes our markers and requests
    std.mem.doNotOptimizeAway(limine_base_revision);
    std.mem.doNotOptimizeAway(limine_requests_start_marker);
    std.mem.doNotOptimizeAway(limine_requests_end_marker);
    std.mem.doNotOptimizeAway(limine_framebuffer_request);
}

pub inline fn limineBaseRevisionSupported() bool {
    return limine_base_revision[2] == 0;
}

pub fn drawLine() void {
    // The framebuffer needs to use 32 bits per pixel for this code to work as intended
    const framebuffer_request = limine_framebuffer_request;

    if (framebuffer_request.response == null or framebuffer_request.response.*.framebuffer_count < 1) return;

    const framebuffer = framebuffer_request.response.*.framebuffers[0];

    for (0..100) |i| {
        const fb_ptr: [*]volatile u32 = @alignCast(@ptrCast(framebuffer.*.address));
        fb_ptr[i * (framebuffer.*.pitch / 4) + i] = 0xffffffff;
    }
}