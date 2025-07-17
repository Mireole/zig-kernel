const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const arch = root.arch;
const interrupts = arch.interrupts;

pub const Status = interrupts.Status;

pub const disable = interrupts.disable;
pub const enable = interrupts.enable;
pub const save = interrupts.save;
pub const restore = interrupts.restore;
