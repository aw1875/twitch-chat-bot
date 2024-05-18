const std = @import("std");

const stdout_file = std.io.getStdOut();
const stderr_file = std.io.getStdErr();

pub const Color = struct {
    pub const Black = "\x1b[30m";
    pub const Red = "\x1b[31m";
    pub const Green = "\x1b[32m";
    pub const Yellow = "\x1b[33m";
    pub const Blue = "\x1b[34m";
    pub const Magenta = "\x1b[35m";
    pub const Cyan = "\x1b[36m";
    pub const White = "\x1b[37m";
    pub const Clear = "\x1b[0m";

    pub const FG = "\x1b[38;5;";
    pub const BG = "\x1b[48;5;";
};

const LogLevel = enum(usize) {
    Debug,
    Info,
    Warn,
    Fatal,

    fn getColor(self: LogLevel) []const u8 {
        switch (self) {
            .Debug => return Color.Magenta,
            .Info => return Color.Green,
            .Warn => return Color.Yellow,
            .Fatal => return Color.Red,
        }
    }

    fn toString(self: LogLevel) []const u8 {
        switch (self) {
            .Debug => return "DEBUG",
            .Info => return " INFO",
            .Warn => return " WARN",
            .Fatal => return "FATAL",
        }
    }
};

const Self = @This();
scope: ?[]const u8 = null,
allocator: std.mem.Allocator = std.heap.page_allocator,

fn getTimeString(self: Self) []const u8 {
    const buff = self.allocator.alloc(u8, 11) catch unreachable;
    defer self.allocator.free(buff);

    const timestamp: u64 = @intCast(std.time.timestamp());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };

    _ = std.fmt.bufPrintZ(buff, "{d}", .{epoch_seconds.secs}) catch unreachable;

    const out = self.allocator.dupe(u8, buff) catch unreachable;
    return out[0..];
}

fn writeLog(
    self: Self,
    log_level: LogLevel,
    comptime message: []const u8,
    args: anytype,
) void {
    const time_str = self.getTimeString();
    const file = switch (log_level) {
        .Debug, .Info => stdout_file,
        .Warn, .Fatal => stderr_file,
    };

    file.lock(.exclusive) catch unreachable;

    var bw = std.io.bufferedWriter(file.writer());
    const output = bw.writer();

    if (self.scope) |scope| {
        output.print("{s}({s}) [{s}] {s}: ", .{ log_level.getColor(), scope, time_str, log_level.toString() }) catch unreachable;
    } else {
        output.print("{s}[{s}] {s}: ", .{ log_level.getColor(), time_str, log_level.toString() }) catch unreachable;
    }

    output.print(message, args) catch unreachable;
    output.print("{s}\n", .{Color.Clear}) catch unreachable;

    bw.flush() catch unreachable;
}

pub fn debug(self: Self, comptime message: []const u8, args: anytype) void {
    if (std.posix.getenv("DEV")) |_| self.writeLog(LogLevel.Debug, message, args);
}

pub fn debugln(self: Self, comptime message: []const u8) void {
    if (std.posix.getenv("DEV")) |_| self.writeLog(LogLevel.Debug, message, .{});
}

pub fn info(self: Self, comptime message: []const u8, args: anytype) void {
    self.writeLog(LogLevel.Info, message, args);
}

pub fn infoln(self: Self, comptime message: []const u8) void {
    self.writeLog(LogLevel.Info, message, .{});
}

pub fn warn(self: Self, comptime message: []const u8, args: anytype) void {
    self.writeLog(LogLevel.Warn, message, args);
}

pub fn warnln(self: Self, comptime message: []const u8) void {
    self.writeLog(LogLevel.Warn, message, .{});
}

pub fn fatal(self: Self, comptime message: []const u8, args: anytype) noreturn {
    self.writeLog(LogLevel.Fatal, message, args);
    std.posix.exit(1);
}

pub fn fatalln(self: Self, comptime message: []const u8) noreturn {
    self.writeLog(LogLevel.Fatal, message, .{});
    std.posix.exit(1);
}
