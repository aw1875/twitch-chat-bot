const std = @import("std");
const WebSocket = @import("ws");

const Logger = @import("utils/logger.zig");
const Color = Logger.Color;

// Parsed Message
const ParsedMessage = @import("parsed_message.zig");
const ParsedTags = ParsedMessage.ParsedTags;
const Tag = ParsedTags.Tag;
const ParsedSource = ParsedMessage.ParsedSource;
const ParsedCommand = ParsedMessage.ParsedCommand;
const Command = ParsedCommand.Command;

// Colors
const RGBA = @import("utils/colors.zig");

// Main Logger
var log = Logger{};

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
        const start_time = std.time.milliTimestamp();
        self.log.debugln("Connecting...");

        defer {
            const end_time = std.time.milliTimestamp();
            self.log.debug("Connected ({d}ms)", .{end_time - start_time});

            self.log.infoln("Connected to chat");
        }

        try self.client.handshake(path, .{
            .timeout_ms = 5000,
            .headers = "Host: 127.0.0.1:8000",
        });
        const thread = try self.client.readLoopInNewThread(self);
        thread.detach();
    }

    pub fn handle(self: Handler, msg: WebSocket.Message) !void {
        if (try self.parse_message(msg.data)) |parsed_message| {
            if (parsed_message.command) |parsed_command| {
                switch (parsed_command.command) {
                    .PING => |c| {
                        self.log.debug("Command: {s}", .{@tagName(c)});
                        var s: *Handler = @constCast(&self);

                        const pong = try std.fmt.allocPrint(self.allocator, "PONG :{s}", .{parsed_message.params});
                        try s.write(pong, true);
                        return;
                    },
                    .PRIVMSG => |c| {
                        self.log.debug("Command: {s}", .{@tagName(c)});

                        var color_code: RGBA = undefined;
                        var name: ?[]const u8 = null;
                        if (parsed_message.tags) |parsed_tags| {
                            if (parsed_tags.tags.get("color")) |color| {
                                if (!std.mem.eql(u8, color, "")) color_code = RGBA.init(color) else color_code = RGBA.initRandom();
                            }

                            if (parsed_tags.tags.get("display-name")) |display_name| name = display_name;
                        }

                        if (name == null) return;
                        self.log.writeMessage(name.?, color_code.rgbToAnsi256(), parsed_message.params);
                    },
                    else => |c| self.log.debug("Command: {s}", .{@tagName(c)}),
                }
            }
        }
    }

    fn parse_message(self: Handler, data: []const u8) !?ParsedMessage {
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
            if (parsed_message.command == null) return null;
            self.log.debug("Parsed Command: {s}", .{parsed_message.command.?.toString(self.allocator)});

            if (raw_tags_component) |tags| parsed_message.tags = self.parse_tags(tags);
            if (raw_source_component) |source| parsed_message.source = self.parse_source(source);

            if (raw_params_component) |params| {
                parsed_message.params = params;

                if (params[0] == '!') self.parse_params(params, &parsed_message.command.?);
            }
        }

        return parsed_message;
    }

    fn parse_command(self: Handler, raw_command: []const u8) ParsedMessage.ParsedCommand {
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

    fn parse_tags(self: Handler, raw_tags: []const u8) ParsedTags {
        var parsed_tags: ParsedTags = .{
            .badges = std.StringHashMap(std.StringHashMap([]const u8)).init(self.allocator),
            .emote_sets = std.ArrayList([]const u8).init(self.allocator),
            .tags = std.StringHashMap([]const u8).init(self.allocator),
        };
        var tags_split = std.mem.split(u8, raw_tags, ";");

        while (tags_split.next()) |tag| {
            var tag_parts = std.mem.split(u8, tag, "=");

            const key = tag_parts.first();
            const value: ?[]const u8 = if (tag_parts.next()) |v| v else null;

            if (std.meta.stringToEnum(Tag, key)) |tag_key| {
                switch (tag_key) {
                    .badges, .@"badge-info" => {
                        if (value) |tag_value| {
                            var badges_set = std.StringHashMap([]const u8).init(self.allocator);
                            var badges = std.mem.split(u8, tag_value, ",");

                            while (badges.next()) |badge| {
                                var badge_parts = std.mem.split(u8, badge, "/");

                                const badge_key = badge_parts.first();
                                if (badge_parts.next()) |badge_value| {
                                    badges_set.put(badge_key, badge_value) catch self.log.warn("Failed to add {s}={s} to badges_set", .{ badge_key, badge_value });
                                }
                            }

                            parsed_tags.badges.put(@tagName(tag_key), badges_set) catch self.log.warn("Failed to add {s} to parsed_tags.badges", .{@tagName(tag_key)});
                        }
                    },
                    .emotes => {
                        // TODO: implement

                    },
                    .@"emote-sets" => {
                        if (value) |tag_value| {
                            var emote_set_ids = std.mem.split(u8, tag_value, ",");

                            while (emote_set_ids.next()) |emote_set| {
                                parsed_tags.emote_sets.append(emote_set) catch self.log.warn("Failed to add {s} to parsed_tags.emote_set", .{emote_set});
                            }
                        }
                    },
                }

                continue;
            }

            if (std.mem.eql(u8, key, "client-nonce") or std.mem.eql(u8, key, "flags")) continue;
            if (value) |v| parsed_tags.tags.put(key, v) catch self.log.warn("Failed to add {s}={s} to parsed_tags.tags", .{ key, v });
        }

        return parsed_tags;
    }

    fn parse_source(self: Handler, raw_source: []const u8) ParsedSource {
        var source_parts = std.mem.split(u8, raw_source, "!");

        const first = source_parts.first();
        const next = source_parts.next();

        const nick: ?[]const u8 = if (next) |_| first else null;
        const host: []const u8 = if (next) |h| h else first;

        self.log.debug("Nick: {?s}, Host: {s}", .{ nick, host });

        return .{ .nick = nick, .host = host };
    }

    fn parse_params(self: Handler, raw_params: []const u8, command: *ParsedCommand) void {
        var command_parts = std.mem.trim(u8, raw_params[1..], " ");
        if (std.mem.indexOf(u8, command_parts, " ")) |param_idx| {
            self.log.debug("Bot Command: {s}, Bot Command Params: {s}", .{ command_parts[0..param_idx], command_parts[param_idx + 1 ..] });

            command.*.bot_command = command_parts[0..param_idx];
            command.*.bot_command_params = command_parts[param_idx + 1 ..];
            return;
        }

        command.*.bot_command = command_parts;
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
    try client.write("NICK the_sus_police", true);
    try client.write("JOIN #aWxlfy", true);

    while (true) {
        std.time.sleep(250_000_000);
    }
}
