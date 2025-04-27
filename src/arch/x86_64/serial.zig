const std = @import("std");

const assert = std.debug.assert;

const com_addresses: [8]u16 = .{
    0x3F8,
    0x2F8,
    0x3E8,
    0x2E8,
    0x5F8,
    0x4F8,
    0x5E8,
    0x4E8,
};

const receive_buffer = 0;    // Read ; DLAB=0
const transmit_buffer = 0;   // Write; DLAB=0
const interrupt_enable = 1;  // Both ; DLAB=0
const divisor_low = 0;       // Both ; DLAB=1
const divisor_high = 1;      // Both ; DLAB=1
const interrupt_identification = 2; // Read
const fifo_control = 2;      // Write
const line_control = 3;      // Both
const modem_control = 4;     // Both
const line_status = 5;       // Read
const modem_status = 6;      // Read
const scratch = 7;           // Both

const test_value = 0xA5;

var initialized = false;

const SerialError = error {
    InvalidPort,
};

pub var ports: [8]COMPort = undefined;

const COMPort = struct {
    address: u16,
    initialized: bool = false,

    pub fn init(port: *COMPort) SerialError!void {
        const address = port.address;
        outb(address + interrupt_enable, 0); // Disable interrupts
        outb(address + line_control, 0x80); // Set DLAB bit
        outb(address + divisor_low, 3); // Divisor low bits
        outb(address + divisor_high, 0); // Divisor high bits
        outb(address + line_control, 0x03); // Clear DLAB bit; Set transmission mode to 8 bits with no parity
                                            // and one stop bit
        outb(address + fifo_control, 0xC7); // Enable FIFO, clear buffers, use 14 byte trigger level
        outb(address + modem_control, 0x0B); // Set the IRQ, DTR and RTS pins
        outb(address + modem_control, 0x1E); // Set loopback bit

        // Test the serial port
        outb(address + transmit_buffer, test_value);
        
        if (inb(address + receive_buffer) != test_value) {
            return SerialError.InvalidPort;
        }

        outb(address + modem_control, 0x0B); // Set the IRQ, DTR and RTS pins again and disable loopback

        port.initialized = true;
    }

    fn canTransmit(port: COMPort) bool {
        assert(port.initialized == true);
        return inb(port.address + line_status) & 0x20 > 0;
    }

    pub fn write(port: COMPort, value: u8) void {
        assert(port.initialized == true);
        while (!canTransmit(port)) {}
        outb(port.address + transmit_buffer, value);
    }

    pub fn writeString(port: COMPort, string: []const u8) void {
        assert(port.initialized == true);
        for (string) |char| {
            port.write(char);
        }
    }

};

pub fn init() void {
    for (com_addresses, 0..) |address, i| {
        var port = COMPort {
            .address = address,
        };
        port.init() catch {};
        ports[i] = port;
    }
    initialized = true;
    // Send a newline and reset terminal settings
    writeString("\n");
}

pub fn writeString(string: []const u8) void {
    if (!initialized) return;
    for (ports) |port| {
        if (port.initialized) port.writeString(string);
    }
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{al}" (value),
    );
}