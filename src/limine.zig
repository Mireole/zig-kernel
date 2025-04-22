const builtin = @import("builtin");
const limine = @import("limine");
const std = @import("std");
const root = @import("root");

const PhysAddr = root.types.PhysAddr;
const VirtAddr = root.types.VirtAddr;

pub var rsdp: ?PhysAddr = null;
pub var hhdm_start: usize = undefined;

// 4GiB
pub const hhdm_size = 0x1_0000_0000;

// The translation to zig code misses quite a few macros, therefore some of them have to be reimplemented here

const limine_common_magic: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// LIMINE_BASE_REVISION(3)
// The extern struct type is needed to make sure that the compiler doesn't optimize away the markers
const base_revision = extern struct {
    value: [3]u64,
};
export var limine_base_revision linksection(".requests") = base_revision{
    .value = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 },
};

// LIMINE_REQUESTS_START_MARKER
const requests_start_marker = extern struct {
    value: [4]u64,
};
export var limine_requests_start_marker linksection(".requests_start_marker") = requests_start_marker{
    .value = .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 },
};

// LIMINE_REQUESTS_END_MARKER
const requests_end_marker = extern struct {
    value: [2]u64,
};
export var limine_requests_end_marker linksection(".requests_end_marker") = requests_end_marker{
    .value = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

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

// Kernel address request
export var executable_address_request linksection(".requests") = limine.limine_executable_address_request{
    .id = limine_common_magic ++ .{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    .revision = 0,
};

// RSDP request
export var rsdp_request linksection(".requests") = limine.limine_rsdp_request{
    .id = limine_common_magic ++ .{ 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    .revision = 0,
};

// Device tree request
export var dtb_request linksection(".requests") = limine.limine_dtb_request{
    .id = limine_common_magic ++ .{ 0xb40ddb48fb54bac7, 0x545081493f81ffb7 },
    .revision = 0,
};

// Multiprocessor request
export var mp_request linksection(".requests") = limine.limine_mp_request{
    .id = limine_common_magic ++ .{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    .revision = 0,
};

// Memory map request
export var memmap_request linksection(".requests") = limine.limine_memmap_request{
    .id = limine_common_magic ++ .{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
};

pub const MemmapType = enum(u32) {
    Usable = limine.LIMINE_MEMMAP_USABLE,
    Reserved = limine.LIMINE_MEMMAP_RESERVED,
    AcpiReclaimable = limine.LIMINE_MEMMAP_ACPI_RECLAIMABLE,
    AcpiNVS = limine.LIMINE_MEMMAP_ACPI_NVS,
    BadMemory = limine.LIMINE_MEMMAP_BAD_MEMORY,
    BootloaderReclaimable = limine.LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE,
    ExecutableAndModules = limine.LIMINE_MEMMAP_EXECUTABLE_AND_MODULES,
    Framebuffer = limine.LIMINE_MEMMAP_FRAMEBUFFER,
};

pub fn init() void{
    preventOptimizations();

    // HHDM start
    const hhdm_request_ptr: *volatile limine.limine_hhdm_request = @ptrCast(&hhdm_request);
    const hhdm_response = hhdm_request_ptr.response;
    if (hhdm_response == null) {
        @panic("Cannot retrieve the HHDM start address");
    }
    hhdm_start = hhdm_response.*.offset;

    const rsdp_request_ptr: *volatile limine.limine_rsdp_request = @ptrCast(&rsdp_request);
    const rsdp_response = rsdp_request_ptr.response;
    if (rsdp_response) |response| {
        rsdp = PhysAddr.from(response.*.address);
    }
}

fn preventOptimizations() void {
    // Without these lines the compiler might remove our markers and requests
    // Markers
    std.mem.doNotOptimizeAway(limine_base_revision);
    std.mem.doNotOptimizeAway(limine_requests_start_marker);
    std.mem.doNotOptimizeAway(limine_requests_end_marker);
    // Requests
    std.mem.doNotOptimizeAway(framebuffer_request);
    std.mem.doNotOptimizeAway(hhdm_request);
    std.mem.doNotOptimizeAway(executable_address_request);
    std.mem.doNotOptimizeAway(rsdp_request);
    std.mem.doNotOptimizeAway(dtb_request);
    std.mem.doNotOptimizeAway(mp_request);
    std.mem.doNotOptimizeAway(memmap_request);
}

pub inline fn limineBaseRevisionSupported() bool {
    // Implementation of the LIMINE_BASE_REVISION_SUPPORTED macro
    const ptr: *const volatile [3]u64 = @ptrCast(&limine_base_revision);
    return ptr[2] == 0;
}

pub noinline fn drawLine(offset: usize) void {
    const framebuffer_request_ptr: *volatile limine.limine_framebuffer_request = @ptrCast(&framebuffer_request);
    const response = framebuffer_request_ptr.response;
    // The framebuffer needs to use 32 bits per pixel for this code to work as intended
    if (response == null or response.*.framebuffer_count < 1) return;

    const framebuffer = response.*.framebuffers[0];

    for (0..100) |i| {
        const fb_ptr: [*]volatile u32 = @alignCast(@ptrCast(framebuffer.*.address));
        fb_ptr[i * (framebuffer.*.pitch / 4) + i + offset] = 0xffffffff;
    }
}

pub fn getMemoryMap() limine.limine_memmap_response {
    const memmap_request_ptr: *volatile limine.limine_memmap_request = @ptrCast(&memmap_request);
    return memmap_request_ptr.response.*;
}

pub inline fn get(phys: PhysAddr) VirtAddr {
    std.debug.assert(phys.v < hhdm_size);
    const address = phys.v + hhdm_start;
    return VirtAddr.from(address);
}