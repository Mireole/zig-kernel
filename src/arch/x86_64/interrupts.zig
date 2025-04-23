const std = @import("std");
const root = @import("root");

pub const Status = packed struct(u64) {
    interrupts_enabled: bool,
    _padding: u63 = 0,
};

const interrupt_flag_mask = 1 << 9;

// Disable interrupts and return the previous state
pub fn save() Status {
    const flags = asm volatile("pushf ; pop %[value]"
        : [value] "=r" (-> u16)
    );
    const interrupt_enable = flags & interrupt_flag_mask > 0;
    if (interrupt_enable) asm volatile ("cli");

    return Status {
        .interrupts_enabled = interrupt_enable,
    };
}

// Restore interrupts from the given state
pub fn restore(status: Status) void {
    if (status.interrupts_enabled) asm volatile ("sti");
}