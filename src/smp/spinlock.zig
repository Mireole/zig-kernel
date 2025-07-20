const std = @import("std");
const kernel = @import("kernel");

const interrupts = kernel.interrupts;

const cache_line = std.atomic.cache_line;
const CacheLine: type = @Type(.{ .int = .{ .bits = cache_line * 8, .signedness = .unsigned } });

pub const Spinlock = struct {
    value: CacheLine align(cache_line) = 0,

    // Disables interrupts, acquires the lock and returns the previous interrupt status
    pub fn lock(self: *Spinlock) interrupts.Status {
        // Save interrupt status and disable interrupts
        const status = interrupts.save();

        self.lock_interruptible();

        return status;
    }

    // Acquires the lock without disabling interrupts TODO SCHED: replace every usage with mutexes
    pub fn lock_interruptible(self: *Spinlock) void {
        const flag: *bool = @ptrCast(self);
        while (@cmpxchgWeak(bool, flag, false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    // Frees the lock and restores the previous interrupt status
    pub fn unlock(self: *Spinlock, status: interrupts.Status) void {
        self.unlock_interruptible();

        interrupts.restore(status);
    }

    // Frees the lock without restoring interrupts
    pub fn unlock_interruptible(self: *Spinlock) void {
        const flag: *bool = @ptrCast(self);
        @atomicStore(bool, flag, false, .release);
    }
};
