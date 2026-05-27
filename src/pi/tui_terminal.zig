//! Raw-mode terminal control for the interactive TUI.
//!
//! Wraps the platform termios calls used by upstream `packages/tui/src/terminal.ts`
//! `start()`/`stop()`: switch the controlling TTY to raw mode (no canonical line
//! buffering, no echo, byte-at-a-time reads) and restore the saved attributes on
//! shutdown. Also provides terminal-size lookup and the alternate-screen / cursor
//! show-hide escape sequences.
//!
//! Only the POSIX path (macOS/Linux) is implemented; Windows console mode is
//! noted as remaining.

const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct { columns: u16 = 80, rows: u16 = 24 };

pub const RawMode = struct {
    fd: std.posix.fd_t,
    original: std.posix.termios,
    active: bool = false,

    /// Switch `fd` (a TTY) into raw mode, saving the prior attributes.
    pub fn enable(fd: std.posix.fd_t) !RawMode {
        const original = try std.posix.tcgetattr(fd);
        var raw = original;

        // Mirror cfmakeraw essentials needed for key-at-a-time input:
        // disable canonical mode, echo, signal generation, and extended input.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.IEXTEN = false;
        // Keep ISIG disabled so Ctrl+C / Ctrl+Z reach the app as bytes
        // (upstream handles app.clear / app.suspend itself).
        raw.lflag.ISIG = false;

        // Input flags: don't translate CR->NL, disable flow control/parity checks.
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;

        // Block until at least 1 byte; no inter-byte timer.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .original = original, .active = true };
    }

    /// Restore the original terminal attributes. Safe to call multiple times.
    pub fn disable(self: *RawMode) void {
        if (!self.active) return;
        std.posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

/// Query the terminal size via TIOCGWINSZ; falls back to 80x24, then to the
/// COLUMNS/LINES env vars if present.
pub fn querySize(fd: std.posix.fd_t, env: ?*const std.process.Environ.Map) Size {
    var ws: std.posix.winsize = undefined;
    const TIOCGWINSZ = if (@hasDecl(std.posix.T, "IOCGWINSZ")) std.posix.T.IOCGWINSZ else 0x40087468;
    const rc = std.posix.system.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(rc) == .SUCCESS and ws.col > 0 and ws.row > 0) {
        return .{ .columns = ws.col, .rows = ws.row };
    }
    if (env) |environ| {
        var size: Size = .{};
        if (environ.get("COLUMNS")) |c| size.columns = std.fmt.parseInt(u16, c, 10) catch 80;
        if (environ.get("LINES")) |l| size.rows = std.fmt.parseInt(u16, l, 10) catch 24;
        return size;
    }
    return .{};
}

/// Non-blocking read of up to `buf.len` bytes from `fd`. Returns 0 if no input
/// is currently available (so a cooperative cancellation poll never blocks the
/// agent loop). Uses poll(2) with a zero timeout.
pub fn readNonblocking(fd: std.posix.fd_t, buf: []u8) usize {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 0) catch return 0;
    if (ready == 0) return 0;
    if (fds[0].revents & std.posix.POLL.IN == 0) return 0;
    return std.posix.read(fd, buf) catch 0;
}

// Escape sequences (subset used by the interactive loop).
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const clear_screen = "\x1b[2J\x1b[H";
pub const clear_to_end = "\x1b[0J";

test "RawMode and querySize compile and have stable escape constants" {
    // No TTY available in the test harness; just exercise the pure pieces.
    try std.testing.expectEqualStrings("\x1b[?25l", hide_cursor);
    try std.testing.expectEqualStrings("\x1b[?25h", show_cursor);
    const s = querySize(-1, null);
    try std.testing.expect(s.columns == 80 and s.rows == 24);
}
