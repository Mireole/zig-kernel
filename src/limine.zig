const builtin = @import("builtin");
const limine = @import("limine");
const std = @import("std");
const kernel = @import("kernel");

const vmm = kernel.vmm;
const framebuffer = kernel.framebuffer;

const PhysAddr = kernel.types.PhysAddr;
const VirtAddr = kernel.types.VirtAddr;

pub var rsdp: ?PhysAddr = null;
pub var hhdm_start: usize = undefined;
pub var debug_file: ?[]const u8 = null;

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
    .flags = 0x1, // Enable x2APIC if possible
};

// Memory map request
export var memmap_request linksection(".requests") = limine.limine_memmap_request{
    .id = limine_common_magic ++ .{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
};

// Module request
export var module_request linksection(".requests") = limine.limine_module_request{
    .id = limine_common_magic ++ .{ 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    .revision = 1,
};

pub const MemmapType = enum(u32) {
    usable = limine.LIMINE_MEMMAP_USABLE,
    reserved = limine.LIMINE_MEMMAP_RESERVED,
    acpi_reclaimable = limine.LIMINE_MEMMAP_ACPI_RECLAIMABLE,
    acpi_nvs = limine.LIMINE_MEMMAP_ACPI_NVS,
    bad_memory = limine.LIMINE_MEMMAP_BAD_MEMORY,
    bootloader_reclaimable = limine.LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE,
    executable_and_modules = limine.LIMINE_MEMMAP_EXECUTABLE_AND_MODULES,
    framebuffer = limine.LIMINE_MEMMAP_FRAMEBUFFER,
};

pub fn init() void {
    preventOptimizations();

    // HHDM start
    const hhdm_request_ptr: *volatile limine.limine_hhdm_request = @ptrCast(&hhdm_request);
    const hhdm_response = hhdm_request_ptr.response;
    if (hhdm_response == null) {
        @panic("Cannot retrieve the HHDM start address");
    }
    hhdm_start = hhdm_response.*.offset;
    std.log.debug("Limine HHDM start address: {X:0>16}", .{hhdm_start});

    const rsdp_request_ptr: *volatile limine.limine_rsdp_request = @ptrCast(&rsdp_request);
    const rsdp_response = rsdp_request_ptr.response;
    if (rsdp_response) |response| {
        rsdp = PhysAddr.from(response.*.address);
    }

    const module_request_ptr: *volatile limine.limine_module_request = @ptrCast(&module_request);
    const module_request_response = module_request_ptr.response;
    if (module_request_response) |response| {
        const modules = response.*.modules[0..response.*.module_count];
        for (modules) |module| {
            const path: []const u8 = module.*.path[0..std.mem.len(module.*.path)];
            if (std.mem.eql(u8, path, "/kernel.elf.debug")) {
                debug_file = @as([*]u8, @ptrCast(module.*.address))[0..module.*.size];
            }
        }
    }
    initFramebuffer();
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
    std.mem.doNotOptimizeAway(module_request);
}

fn initFramebuffer() void {
    const fb_request_ptr: *volatile limine.limine_framebuffer_request = @ptrCast(&framebuffer_request);
    const fb_response = fb_request_ptr.response;
    if (fb_response == null) return;
    const count = fb_response.*.framebuffer_count;
    const framebuffers = fb_response.*.framebuffers[0..count];
    var index: usize = 0;
    for (framebuffers) |fb_ptr| {
        if (index >= framebuffer.fb_buf.len) break;
        const fb = fb_ptr.*;
        if (fb.bpp != 32 and fb.bpp != 24) {
            var ptr: [*]u32 = @alignCast(@ptrCast(fb.address));
            const buffer = ptr[0..(fb.pitch * fb.height) / 4];
            // Don't know what color this would be, but definitely noticeable
            @memset(buffer, 0xACBD1234);
            continue;
        }
        framebuffer.fb_buf[index] = .{
            .buffer = @ptrCast(fb.address),
            .frame_buffer = @ptrCast(fb.address),
            .width = fb.width,
            .height = fb.height,
            .pitch = fb.pitch,
            .bpp = @intCast(fb.bpp),
            .red_mask = fb.red_mask_size - 1,
            .red_shift = @intCast(fb.red_mask_shift),
            .green_mask = fb.green_mask_size - 1,
            .green_shift = @intCast(fb.green_mask_shift),
            .blue_mask = fb.blue_mask_size - 1,
            .blue_shift = @intCast(fb.blue_mask_shift),
        };
        index += 1;
    }
    framebuffer.framebuffers = framebuffer.fb_buf[0..index];
}

pub inline fn limineBaseRevisionSupported() bool {
    // Implementation of the LIMINE_BASE_REVISION_SUPPORTED macro
    const ptr: *const volatile [3]u64 = @ptrCast(&limine_base_revision);
    return ptr[2] == 0;
}

/// Returns the memmap reponse
pub fn getMemoryMap() limine.limine_memmap_response {
    const memmap_request_ptr: *volatile limine.limine_memmap_request = @ptrCast(&memmap_request);
    return memmap_request_ptr.response.*;
}

pub fn getKernelAddress() PhysAddr {
    const executable_address_ptr: *volatile limine.limine_executable_address_request = @ptrCast(&executable_address_request);
    return PhysAddr.from(executable_address_ptr.response.*.physical_base);
}

/// Changes all pointers inside the memory map request to match the kernel HHDM
pub fn updateMemoryMap() void {
    const memmap_request_ptr: *volatile limine.limine_memmap_request = @ptrCast(&memmap_request);
    const response = toHHDM(VirtAddr.from(memmap_request_ptr.response))
        .to([*c]limine.struct_limine_memmap_response);
    // Change the address of the list and every entry it contains
    response.*.entries = toHHDM(VirtAddr.from(response.*.entries))
        .to([*c][*c]limine.struct_limine_memmap_entry);

    const entries = response.*.entries[0..response.*.entry_count];
    for (entries, 0..) |entry, i| {
        entries[i] = toHHDM(VirtAddr.from(entry)).to([*c]limine.struct_limine_memmap_entry);
    }
}

pub fn updateDebugInfo() void {
    if (debug_file) |file| {
        debug_file = toHHDM(VirtAddr.from(file.ptr)).toSlice(u8, file.len);
    }
}

pub fn updateFramebuffers() void {
    for (framebuffer.framebuffers) |*fb| {
        fb.buffer = toHHDM(VirtAddr.from(fb.buffer)).to([*]u8);
    }
}

/// Returns a pointer corresponding to the physical address in limine's HHDM
pub inline fn get(phys: PhysAddr) VirtAddr {
    std.debug.assert(phys.v < hhdm_size);
    const address = phys.v + hhdm_start;
    return VirtAddr.from(address);
}

/// Changes the value of a pointer from limine's HHDM to the new HHDM
pub inline fn toHHDM(limine_addr: VirtAddr) VirtAddr {
    var hhdm_addr = limine_addr;
    hhdm_addr.v -= hhdm_start;
    hhdm_addr.v += vmm.hhdm_start;
    return hhdm_addr;
}
