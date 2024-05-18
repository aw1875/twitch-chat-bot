const std = @import("std");
const Logger = @import("utils/logger.zig");
const WebSocket = @import("ws");

var log = Logger{};

const ParsedMessage = struct {
    tags: []const u8 = undefined,
    source: []const u8 = undefined,
    command: ?ParsedCommand = undefined,
    params: []const u8 = undefined,
};

const ParsedCommand = struct {
    command: Command = Command.UNKNOWN,
    channel: []const u8 = "",
    cap_request_enabled: bool = false,

    pub fn toString(self: ParsedCommand, allocator: std.mem.Allocator) []const u8 {
        const str = std.fmt.allocPrint(allocator, "Command: {s}, Channel: {s}, Cap Req Enabled: {s}", .{
            @tagName(self.command),
            if (std.mem.eql(u8, self.channel, "")) "None" else self.channel,
            if (self.cap_request_enabled) "true" else "false",
        }) catch "";

        return allocator.dupe(u8, str) catch "";
    }
};

const Command = enum {
    JOIN,
    PART,
    NOTICE,
    CLEARCHAT,
    HOSTTARGET,
    PRIVMSG,
    PING,
    CAP,
    GLOBALUSERSTATE,
    USERSTATE,
    ROOMSTATE,
    RECONNECT,
    UNKNOWN,

    // Numeric replies
    @"001",
    @"002",
    @"003",
    @"004",
    @"353",
    @"366",
    @"372",
    @"375",
    @"376",
    @"421",
};

const Handler = struct {
    allocator: std.mem.Allocator,
    client: WebSocket.Client,
    log: Logger,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Handler {
        return .{
            .allocator = allocator,
            .client = try WebSocket.connect(allocator, host, port, .{}),
            .log = Logger{ .scope = "Handler", .allocator = allocator },
        };
    }

    pub fn deinit(self: *Handler) void {
        self.client.deinit();
    }

    pub fn connect(self: *Handler, path: []const u8) !void {
        try self.client.handshake(path, .{
            .timeout_ms = 5000,
            .headers = "Host: 127.0.0.1:8000",
        });
        const thread = try self.client.readLoopInNewThread(self);
        thread.detach();
    }

    pub fn handle(self: Handler, msg: WebSocket.Message) !void {
        try self.parse_message(msg.data);
    }

    fn parse_message(self: Handler, data: []const u8) !void {
        var parsed_message: ParsedMessage = .{};
        var parts = std.mem.split(u8, std.mem.trim(u8, data, "\r\n"), "\r\n");

        while (parts.next()) |message| {
            var idx: usize = 0;
            var raw_tags_component: ?[]const u8 = null;
            var raw_source_component: ?[]const u8 = null;
            var raw_command_component: ?[]const u8 = null;
            var raw_params_component: ?[]const u8 = null;

            if (message[idx] == '@') {
                if (std.mem.indexOf(u8, message, " ")) |end_idx| {
                    raw_tags_component = message[1..end_idx];
                    idx = end_idx + 1;

                    self.log.debug("Tags: {s}", .{raw_tags_component.?});
                }
            }

            if (message[idx] == ':') {
                idx += 1;

                if (std.mem.indexOf(u8, message[idx..], " ")) |end_idx| {
                    raw_source_component = message[idx .. idx + end_idx];
                    idx = idx + end_idx + 1;

                    self.log.debug("Source: {s}", .{raw_source_component.?});
                }
            }

            var end_idx: usize = std.math.maxInt(usize);
            if (std.mem.indexOf(u8, message[idx..], ":")) |i| end_idx = idx + i;
            if (end_idx == std.math.maxInt(usize)) end_idx = message.len;
            raw_command_component = std.mem.trim(u8, message[idx..end_idx], " ");
            self.log.debug("Command: {s}", .{raw_command_component.?});

            if (end_idx != message.len) {
                idx = end_idx + 1;
                raw_params_component = message[idx..];

                self.log.debug("Params: {s}", .{raw_params_component.?});
            }

            if (raw_command_component) |command| parsed_message.command = self.parse_command(command);
            if (parsed_message.command == null) return;
            self.log.debug("Parsed Command: {s}", .{parsed_message.command.?.toString(self.allocator)});

            std.debug.print("\n", .{});
        }
    }

    fn parse_command(self: Handler, raw_command: []const u8) ParsedCommand {
        var parsed_command: ParsedCommand = .{};

        var command_parts = std.mem.split(u8, raw_command, " ");
        if (std.meta.stringToEnum(Command, command_parts.first())) |command| {
            self.log.debug("Enum: {s}", .{@tagName(command)});

            parsed_command.command = command;
            switch (command) {
                .JOIN, .PART, .NOTICE, .CLEARCHAT, .HOSTTARGET, .PRIVMSG => {
                    if (command_parts.next()) |channel| parsed_command.channel = channel;
                },
                .CAP => {
                    _ = command_parts.next();
                    if (command_parts.next()) |cap_request| parsed_command.cap_request_enabled = if (std.mem.eql(u8, cap_request, "ACK")) true else false;
                },
                .USERSTATE, .ROOMSTATE => {
                    if (command_parts.next()) |channel| parsed_command.channel = channel;
                },
                .RECONNECT => self.log.infoln("The Twitch IRC server is about to terminate the connection for maintenance."),
                .@"421" => {
                    if (command_parts.next()) |message| self.log.warn("Unsupported IRC command: {s}", .{message});
                },
                .@"001" => {
                    if (command_parts.next()) |channel| parsed_command.channel = channel;
                },
                .@"002", .@"003", .@"004", .@"353", .@"366", .@"372", .@"375", .@"376" => self.log.debug("numeric message: {s}", .{@tagName(command)}),
                .PING, .GLOBALUSERSTATE => {},
                else => self.log.warn("Unexpected command: {s}", .{@tagName(command)}),
            }
        }

        return parsed_command;
    }

    pub fn write(self: *Handler, data: []const u8, should_log: bool) !void {
        const message = try self.allocator.dupe(u8, data);
        if (should_log) self.log.debug("Writing: {s}", .{data});
        return self.client.write(message);
    }

    pub fn close(_: Handler) void {}
};

pub fn main() !void {
    const TWITCH_TOKEN = std.posix.getenv("TWITCH_TOKEN") orelse "";
    if (std.mem.eql(u8, TWITCH_TOKEN, "")) log.fatalln("TWITCH_TOKEN is missing");

    log.debugln("TWITCH_TOKEN is present\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const pass = try std.fmt.allocPrint(alloc, "PASS oauth:{s}", .{TWITCH_TOKEN});

    var client = try Handler.init(alloc, "irc-ws.chat.twitch.tv", 80);
    defer client.deinit();

    try client.connect("/");

    try client.write("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands", true);
    try client.write(pass, false);
    try client.write("NICK aWxlfyBot", true);
    try client.write("JOIN #aWxlfy", true);
    std.debug.print("\n", .{});

    while (true) {}
}
