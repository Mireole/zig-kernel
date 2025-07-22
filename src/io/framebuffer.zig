const std = @import("std");
const kernel = @import("kernel");

const types = kernel.types;

const VirtAddr = types.VirtAddr;

const font: Font = @import("jbmono.zon");

const Font = struct {
    credit: []const u8,
    glyphWidth: u8,
    glyphHeight: u8,
    indexes: [128]u8,
    data: []const u8,
};


const Framebuffer = struct {
    pub const Color = u32;

    buffer: [*]u8,
    width: usize,
    height: usize,
    pitch: usize,
    bpp: u8,
    red_mask: u32,
    red_shift: u5,
    green_mask: u32,
    green_shift: u5,
    blue_mask: u32,
    blue_shift: u5,

    pub inline fn writePixel(fb: *Framebuffer, x: usize, y: usize, r: u8, g: u8, b: u8) void {
        // Currently assuming a 24-bpp RGB or 32-bpp RGB framebuffer
        var base: [*]u8 = @ptrCast(&fb.buffer[y * fb.pitch + x * (fb.bpp >> 3)]);
        base[0] = b;
        base[1] = g;
        base[2] = r;
    }

    pub inline fn clear(fb: *Framebuffer) void {
        @memset(fb.buffer[0..fb.pitch*fb.height], 0);
    }
};

const Terminal = struct {
    framebuffer: *Framebuffer,
    rows: usize,
    cols: usize,
    curr_row: usize = 0,
    curr_col: usize = 0,

    // TODO PERF: inline some functions / loops ?
    pub fn write(term: *Terminal, char: u8) void {
        switch (char) {
            '\n' => {
                term.curr_col = 0;
                term.curr_row += 1;
            },
            '\t' => {
                term.curr_col += 4;
                term.curr_col -= (term.curr_col % 4);
            },
            ' ' => {
                term.curr_col += 1;
            },
            else => {
                term.draw(char);
                term.curr_col += 1;
            }
        }
        term.handleOverflow();
    }

    fn handleOverflow(term: *Terminal) void {
        if (term.curr_col >= term.cols) {
            term.curr_col = 0;
            term.curr_row += 1;
        }
        if (term.curr_row >= term.rows) term.scroll(1);
    }

    fn draw(term: *Terminal, char: u8) void {
        // The font only supports ASCII characters right now
        const glyph_index = if (char < 128) font.indexes[char] else 0;
        var offset = @as(usize, glyph_index) * font.glyphHeight * font.glyphWidth;
        const base_x = term.curr_col * font.glyphWidth;
        const base_y = term.curr_row * font.glyphHeight;
        for (0..font.glyphHeight) |y| {
            for (0..font.glyphWidth) |x| {
                const intensity = font.data[offset];
                term.framebuffer.writePixel(base_x + x, base_y + y, intensity, intensity, intensity);
                offset += 1;
            }
        }
    }

    pub fn scroll(term: *Terminal, rows: usize) void {
        const fb = term.framebuffer;
        var buffer = fb.buffer;
        const moved_bytes = (term.rows - rows) * font.glyphHeight * fb.pitch;
        const replaced_bytes = rows * font.glyphHeight * fb.pitch;
        const source = buffer[replaced_bytes..replaced_bytes + moved_bytes];
        const dest = buffer[0..moved_bytes];
        const empty = buffer[moved_bytes..replaced_bytes + moved_bytes];
        @memmove(dest, source);
        @memset(empty, 0);
        term.curr_row -= rows;
    }

    pub fn clear(term: *Terminal) void {
        term.framebuffer.clear();
        term.curr_col = 0;
        term.curr_row = 0;
    }
};

// Do we really need more than 4 framebuffers ?
pub var fb_buf: [4]Framebuffer = undefined;
pub var framebuffers: []Framebuffer = &.{};
var term_buf: [4]Terminal = undefined;
var terminals: []Terminal = &.{};

pub fn init() void {
    for (0..framebuffers.len) |i| {
        var fb = &framebuffers[i];
        fb.clear();
        term_buf[i] = .{
            .framebuffer = fb,
            .rows = fb.height / font.glyphHeight,
            .cols = fb.width / font.glyphWidth,
        };
        fb.writePixel(fb.width - 1, fb.height - 1, 0, 0, 255);
        fb.writePixel(fb.width - 2, fb.height - 1, 0, 255, 0);
        fb.writePixel(fb.width - 3, fb.height - 1, 255, 0, 0);
    }
    terminals = term_buf[0..framebuffers.len];
}

pub fn writeString(string: []const u8) void {
    for (string) |char| {
        for (0..terminals.len) |i| {
            terminals[i].write(char);
        }
    }
}