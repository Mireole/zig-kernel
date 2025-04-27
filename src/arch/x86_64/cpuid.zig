const std = @import("std");
const root = @import("root");

pub var huge_pages: bool = undefined;

/// Cache all needed cpuid values
pub fn init() void {
    huge_pages = feature_flag(0x80000001, .edx, 26);
    std.log.debug("Huge pages supported: {}", .{ huge_pages });
}

/// Struct and function from from https://github.com/ziglang/zig/blob/master/lib/std/zig/system/x86.zig
const CpuidLeaf = packed struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

const Register = enum {
    eax,
    ebx,
    ecx,
    edx,
};

fn feature_flag(leaf_id: u32, register: Register, bit: u5) bool {
    const leaf = cpuid(leaf_id, 0);
    const reg_value = switch (register) {
        .eax => leaf.eax,
        .ebx => leaf.ebx,
        .ecx => leaf.ecx,
        .edx => leaf.edx,
    };

    return (reg_value >> bit) & 1 != 0;
}