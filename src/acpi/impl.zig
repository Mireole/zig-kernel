const std = @import("std");
const zuacpi = @import("zuacpi");
const root = @import("root");

const limine = root.limine;
const uacpi = zuacpi.uacpi;
const acpi = root.acpi;

const Error = uacpi.Error;
const Spinlock = root.smp.Spinlock;
// TODO use real Mutexes
const Mutex = Spinlock;

var allocator = acpi.allocator;
const status = uacpi.uacpi_status;

// Very simple impl TODO use a semaphore once mutexes are implemented
const Event = struct {
    lock: Spinlock = Spinlock{},
    count: usize = 0,

    fn wait(event: *Event, _: u16) bool {
        event.lock.lock_interruptible();
        defer event.lock.unlock_interruptible();

        while (@atomicLoad(usize, &event.count, .unordered) == 0) {
            std.atomic.spinLoopHint();
        }

        _ = @atomicRmw(usize, &event.count, .Sub, 1, .acquire);

        return true;
    }

    fn signal(event: *Event) void {
        _ = @atomicRmw(usize, &event.count, .Add, 1, .release);
    }

    fn reset(event: *Event) void {
        event.lock.lock_interruptible();
        defer event.lock.unlock_interruptible();

        @atomicStore(usize, &event.count, 0, .release);
    }
};

export fn uacpi_kernel_create_mutex() ?*Mutex {
    return allocator.create(Mutex) catch null;
}

export fn uacpi_kernel_free_mutex(mutex: *Mutex) void {
    allocator.destroy(mutex);
}

export fn uacpi_kernel_acquire_mutex(mutex: *Mutex, _: u16) status {
    mutex.lock_interruptible();
    return .ok;
}

export fn uacpi_kernel_release_mutex(mutex: *Mutex) void {
    mutex.unlock_interruptible();
}

export fn uacpi_kernel_create_event() ?*Event {
    return allocator.create(Event) catch null;
}

export fn uacpi_kernel_free_event(event: *Event) void {
    allocator.destroy(event);
}

export fn uacpi_kernel_wait_for_event(event: *Event, timeout: u16) bool {
    return event.wait(timeout);
}

export fn uacpi_kernel_signal_event(event: *Event) void {
    event.signal();
}

export fn uacpi_kernel_reset_event(event: *Event) void {
    event.reset();
}

export fn uacpi_kernel_map(_: usize, _: usize) ?*anyopaque {
    return null;
}

export fn uacpi_kernel_unmap(_: *anyopaque, _: usize) void {

}

export fn uacpi_kernel_io_map(_: uacpi.IoAddress, _: usize, _: *anyopaque) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_unmap(_: *anyopaque) void {

}

export fn uacpi_kernel_create_spinlock() ?*Spinlock {
    return allocator.create(Spinlock) catch null;
}

export fn uacpi_kernel_free_spinlock(spinlock: *Spinlock) void {
    allocator.destroy(spinlock);
}

export fn uacpi_kernel_lock_spinlock(spinlock: *Spinlock) u64 {
    return @bitCast(spinlock.lock());
}

export fn uacpi_kernel_unlock_spinlock(spinlock: *Spinlock, state: u64) void {
    spinlock.unlock(@bitCast(state));
}

export fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
    return 0;
}

export fn uacpi_kernel_stall(_: u64) void {

}

export fn uacpi_kernel_sleep(_: u64) void {

}

export fn uacpi_kernel_get_rsdp(out_rsdp_addr: *u64) status {
    if (limine.rsdp) |rsdp| {
        out_rsdp_addr.* = rsdp.to(u64);
        return .ok;
    }
    return .unimplemented;
}

export fn uacpi_kernel_io_read8(_: *anyopaque, _: usize, _: *u8) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_read16(_: *anyopaque, _: usize, _: *u16) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_read32(_: *anyopaque, _: usize, _: u32) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_write8(_: *anyopaque, _: usize, _: u8) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_write16(_: *anyopaque, _: usize, _: u16) status {
    return .unimplemented;
}

export fn uacpi_kernel_io_write32(_: *anyopaque, _: usize, _: u32) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_read8(_: *anyopaque, _: usize, _: *u8) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_read16(_: *anyopaque, _: usize, _: *u16) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_read32(_: *anyopaque, _: usize, _: u32) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_write8(_: *anyopaque, _: usize, _: u8) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_write16(_: *anyopaque, _: usize, _: u16) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_write32(_: *anyopaque, _: usize, _: u32) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_device_open(_: uacpi.PciAddress, _: *anyopaque) status {
    return .unimplemented;
}

export fn uacpi_kernel_pci_device_close(_: *anyopaque) void {

}

export fn uacpi_kernel_schedule_work(_: uacpi.WorkType, _: uacpi.WorkHandler, _: *anyopaque) status {
    return .unimplemented;
}

export fn uacpi_kernel_wait_for_work_completion() status {
    return .unimplemented;
}

export fn uacpi_kernel_get_thread_id() usize {
    return 0;
}

export fn uacpi_kernel_handle_firmware_request(_: *uacpi.FirmwareRequestRaw) status {
    return .unimplemented;
}

export fn uacpi_kernel_install_interrupt_handler(_: u32, _: uacpi.InterruptHandler, _: *anyopaque, _: **anyopaque) status {
    return .unimplemented;
}

export fn uacpi_kernel_uninstall_interrupt_handler(_: uacpi.InterruptHandler, _: *anyopaque) status {
    return .unimplemented;
}