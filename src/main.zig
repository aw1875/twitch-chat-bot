const std = @import("std");
const Logger = @import("utils/logger.zig");
const WebSocket = @import("ws");

var log = Logger{};

const NICKNAME = "aWxlfyBot";

const ParsedMessage = struct {
    tags: []const u8 = undefined,
    source: []const u8 = undefined,
    command: []const u8 = undefined,
    params: []const u8 = undefined,
};

const Command = enum {
    JOIN,
    PART,
    PRIVMSG,
    MODE,
    NAMES,
    PING,
    PONG,
    CAP,
    RECONNECT,
    CLEAR_CHAT,
    GLOBALUSERSTATE,
    ROOMSTATE,
    USERSTATE,
    USERNOTICE,
    HOSTTARGET,
    NOTICE,
    CLEARCHAT,
    CLEARMSG,
    WHISPER,
    UNKNOWN,

    pub fn fromString(logger: Logger, str: []const u8) Command {
        logger.debug("Parsing command: {s}", .{str});

        if (std.mem.eql(u8, str, "JOIN")) {
            return .JOIN;
        } else if (std.mem.eql(u8, str, "PART")) {
            return .PART;
        } else if (std.mem.eql(u8, str, "PRIVMSG")) {
            return .PRIVMSG;
        } else if (std.mem.eql(u8, str, "MODE")) {
            return .MODE;
        } else if (std.mem.eql(u8, str, "NAMES")) {
            return .NAMES;
        } else if (std.mem.eql(u8, str, "PING")) {
            return .PING;
        } else if (std.mem.eql(u8, str, "PONG")) {
            return .PONG;
        } else if (std.mem.eql(u8, str, "CAP")) {
            return .CAP;
        } else if (std.mem.eql(u8, str, "RECONNECT")) {
            return .RECONNECT;
        } else if (std.mem.eql(u8, str, "CLEAR_CHAT")) {
            return .CLEAR_CHAT;
        } else if (std.mem.eql(u8, str, "GLOBALUSERSTATE")) {
            return .GLOBALUSERSTATE;
        } else if (std.mem.eql(u8, str, "ROOMSTATE")) {
            return .ROOMSTATE;
        } else if (std.mem.eql(u8, str, "USERSTATE")) {
            return .USERSTATE;
        } else if (std.mem.eql(u8, str, "USERNOTICE")) {
            return .USERNOTICE;
        } else if (std.mem.eql(u8, str, "HOSTTARGET")) {
            return .HOSTTARGET;
        } else if (std.mem.eql(u8, str, "NOTICE")) {
            return .NOTICE;
        } else if (std.mem.eql(u8, str, "CLEARCHAT")) {
            return .CLEARCHAT;
        } else if (std.mem.eql(u8, str, "CLEARMSG")) {
            return .CLEARMSG;
        } else if (std.mem.eql(u8, str, "WHISPER")) {
            return .WHISPER;
        } else {
            return .UNKNOWN;
        }
    }
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
        const m = std.mem.trim(u8, data, "\r\n");
        var parts = std.mem.split(u8, m, "\r\n");

        while (parts.next()) |message| {
            self.log.debug("{s}", .{message});

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
                    raw_source_component = message[idx..end_idx];
                    idx = end_idx + 1;

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

            std.debug.print("-------------------\n\n\n", .{});
        }
    }

    fn parse_command(self: Handler, raw_command_component: []const u8) void {
        const parsed_command: []const u8 = undefined;
        _ = parsed_command;
        var command_parts = std.mem.split(u8, raw_command_component, " ");
        const command = Command.fromString(self.log, command_parts.first());

        self.log.debug("Command: {s}", .{@tagName(command)});
    }

    pub fn write(self: *Handler, data: []const u8) !void {
        const message = try self.allocator.dupe(u8, data);
        return self.client.write(message);
    }

    pub fn close(_: Handler) void {}
};

pub fn main() !void {
    const TWITCH_TOKEN = std.posix.getenv("TWITCH_TOKEN") orelse "";
    if (std.mem.eql(u8, TWITCH_TOKEN, "")) {
        log.fatalln("TWITCH_TOKEN is missing");
    }

    log.debugln("TWITCH_TOKEN is present");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const pass = try std.fmt.allocPrint(alloc, "PASS oauth:{s}", .{TWITCH_TOKEN});

    var client = try Handler.init(alloc, "irc-ws.chat.twitch.tv", 80);
    defer client.deinit();

    try client.connect("/");

    try client.write("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands");
    try client.write(pass);
    try client.write("NICK aWxlfyBot");
    try client.write("JOIN #aWxlfy");

    while (true) {}
}
