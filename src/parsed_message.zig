const std = @import("std");

pub const ParsedCommand = struct {
    command: Command = Command.UNKNOWN,
    channel: []const u8 = "",
    cap_request_enabled: bool = false,
    bot_command: []const u8 = "",
    bot_command_params: []const u8 = "",

    pub const Command = enum {
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

    pub fn toString(self: ParsedCommand, allocator: std.mem.Allocator) []const u8 {
        const str = std.fmt.allocPrint(allocator, "Command: {s}, Channel: {s}, Cap Req Enabled: {s}", .{
            @tagName(self.command),
            if (std.mem.eql(u8, self.channel, "")) "None" else self.channel,
            if (self.cap_request_enabled) "true" else "false",
        }) catch "";

        return allocator.dupe(u8, str) catch "";
    }
};

pub const ParsedSource = struct {
    nick: ?[]const u8 = null,
    host: []const u8 = undefined,
};

pub const ParsedTags = struct {
    badges: std.StringHashMap(std.StringHashMap([]const u8)),
    emotes: []const u8 = undefined,
    emote_sets: std.ArrayList([]const u8),
    tags: std.StringHashMap([]const u8),

    pub const Tag = enum {
        badges,
        @"badge-info",
        emotes,
        @"emote-sets",
    };
};

tags: ?ParsedTags = undefined,
source: ?ParsedSource = undefined,
command: ?ParsedCommand = undefined,
params: []const u8 = undefined,
