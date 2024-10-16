const std = @import("std");
const builtin = @import("builtin");

pub const limine = @import("limine.zig");

pub const runtime_safety = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

inline fn hcf() noreturn {
    // Loop forever (until interrupted)
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}

export fn _start() noreturn {
    // Limine already gives us a stack, so we can just call
    kmain();
}

fn kmain() noreturn {
    limine.initialize();

    if (!limine.limineBaseRevisionSupported()) {
        hcf();
    }

    limine.drawLine();

    hcf();
}