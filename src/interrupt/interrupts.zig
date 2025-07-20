const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const arch = kernel.arch;
const interrupts = arch.interrupts;

pub const Status = interrupts.Status;

pub const disable = interrupts.disable;
pub const enable = interrupts.enable;
pub const save = interrupts.save;
pub const restore = interrupts.restore;
