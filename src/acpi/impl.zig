const std = @import("std");
const uacpi = @import("uacpi");
const root = @import("root");

const limine = root.limine;

const Error = uacpi.Error;
const handle = uacpi.handle;
const Spinlock = root.smp.Spinlock;

var allocator: std.mem.Allocator = undefined;

// Very simple impl TODO use a semaphore once mutexes are implemented
const Event = struct {
    lock: Spinlock = Spinlock{},
    count: usize = 0,

    fn wait(event: *Event, _: u16) bool {
        event.lock.lock();
        defer event.lock.unlock();

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
        event.lock.lock();
        defer event.lock.unlock();

        @atomicStore(usize, &event.count, 0, .release);
    }
};

fn getNanosecondsSinceBoot() u64 {
    return 0;
}

fn getRsdp() Error!uacpi.phys_addr {
    if (limine.rsdp) |rsdp| {
        return rsdp.to(uacpi.phys_addr);
    }
    return Error.Uninplemented;
}

fn createSpinlock() ?*Spinlock {
    return allocator.create(Spinlock) catch null;
}

fn freeSpinlock(spinlock: *Spinlock) void {
    allocator.destroy(spinlock);
}

fn lockSpinlock(spinlock: *Spinlock) void {
    spinlock.lock();
}

fn unlockSpinlock(spinlock: *Spinlock) void {
    spinlock.unlock();
}

fn lockSpinlockTimeout(spinlock: *Spinlock, _: u16) Error!void {
    spinlock.lock();
}

fn createEvent() ?*Event {
    return allocator.create(Event) catch null;
}

fn freeEvent(event: *Event) void {
    allocator.destroy(event);
}

fn sleep(_: u64) void {

}

fn getThreadId() usize {
    return 0;
}

fn installInterruptHandler(_: u32, _: uacpi.interrupt_handler, _: handle) Error!handle {
    return Error.Uninplemented;
}

fn uninstallInterruptHandler(_: uacpi.interrupt_handler, _: handle) Error!void {
    return Error.Uninplemented;
}

fn handleFirmwareRequest(_: uacpi.FirmwareRequest) Error!void {
    return Error.Uninplemented;
}

fn log(_: uacpi.LogLevel, message: [*:0]const u8) void {
    _ = root.log.logFn(std.mem.span(message));
}

fn scheduleWork(_: uacpi.WorkType, _: uacpi.work_handler, _: handle) Error!void {
    return Error.Uninplemented;
}

fn waitForWorkCompletion() Error!void {
    return Error.Uninplemented;
}

fn map(_: uacpi.phys_addr, _: usize) ?*anyopaque {
    return null;
}

fn unmap(_: *anyopaque, _: usize) void {

}

fn pciDeviceOpen(_: uacpi.pci_address) Error!handle {
    return Error.Uninplemented;
}

fn pciDeviceClose(_: handle) void {

}

fn pciRead(_: *uacpi.pci_address, _: usize, _: u8) Error!u64 {
    return Error.Uninplemented;
}

fn pciWrite(_: *uacpi.pci_address, _: usize, _: u64, _: u8) Error!void {
    return Error.Uninplemented;
}

fn ioMap(_: uacpi.io_addr, _: usize) Error!handle {
    return Error.Uninplemented;
}

fn ioUnmap(_: handle) void {

}

fn ioRead(_: handle, _: usize, _: u8) Error!u64 {
    return Error.Uninplemented;
}

fn ioWrite(_: uacpi.handle, _: usize, _: u64, _: u8) Error!void {
    return Error.Uninplemented;
}

const options = uacpi.ExportOptions{
    .allocator = &allocator,
    .Spinlock = Spinlock,
    .Mutex = Spinlock,
    .Event = Event,
};

const functions = uacpi.FunctionImpl(options){
    .getNanosecondsSinceBoot = getNanosecondsSinceBoot, // TODO
    .getRsdp = getRsdp,
    .createSpinlock = createSpinlock,
    .freeSpinlock = freeSpinlock,
    .lockSpinlock = lockSpinlock,
    .unlockSpinlock = unlockSpinlock,
    .createMutex = createSpinlock, // TODO
    .freeMutex = freeSpinlock, // TODO
    .acquireMutex = lockSpinlockTimeout, // TODO
    .releaseMutex = unlockSpinlock, // TODO
    .createEvent = createEvent,
    .freeEvent = freeEvent,
    .resetEvent = Event.reset,
    .signalEvent = Event.signal,
    .waitForEvent = Event.wait,
    .sleep = sleep, // TODO
    .stall = sleep, // TODO
    .getThreadId = getThreadId, // TODO
    .installInterruptHandler = installInterruptHandler, // TODO
    .uninstallInterruptHandler = uninstallInterruptHandler, // TODO
    .handleFirmwareRequest = handleFirmwareRequest, // TODO
    .scheduleWork = scheduleWork, // TODO
    .waitForWorkCompletion = waitForWorkCompletion, // TODO
    .log = log, // TODO
    .map = map, // TODO
    .unmap = unmap, // TODO
    .pciDeviceOpen = pciDeviceOpen, // TODO
    .pciDeviceClose = pciDeviceClose, // TODO
    .pciRead = pciRead, // TODO
    .pciWrite = pciWrite, // TODO
    .ioMap = ioMap, // TODO
    .ioUnmap = ioUnmap, // TODO
    .ioRead = ioRead, // TODO
    .ioWrite = ioWrite, // TODO
};

comptime {
    uacpi.exportFunctions(options, functions);
}