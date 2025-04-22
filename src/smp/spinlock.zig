const std = @import("std");

const cache_line = std.atomic.cache_line;
const CacheLine: type = @Type(.{ .int = .{ .bits = cache_line, .signedness = .unsigned } });

pub const Spinlock = packed struct(CacheLine) {
    value: CacheLine = 0,

    pub fn lock(self: *Spinlock) void {
        const flag: *bool = @ptrCast(self);
        while (flag.* or @cmpxchgWeak(bool, flag, false, true, .acquire, .monotonic) == null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Spinlock) void {
        const flag: *bool = @ptrCast(self);
        @atomicStore(bool, flag, false, .release);
    }
};
