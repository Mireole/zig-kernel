const std = @import("std");
const builtin = @import("builtin");

inline fn hcf() noreturn {
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
    hcf();
}