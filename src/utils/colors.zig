const RGBA = @This();
r: f32 = 255.0,
g: f32 = 255.0,
b: f32 = 255.0,

pub fn init(color: []const u8) RGBA {
    var hex: u32 = 0;
    for (1..color.len) |i| {
        const curr = color[i];

        switch (curr) {
            '0'...'9' => hex = hex << 4 | curr - '0',
            'a'...'f' => hex = hex << 4 | curr - 'a' + 10,
            'A'...'F' => hex = hex << 4 | curr - 'A' + 10,
            else => continue,
        }
    }

    return RGBA{
        .r = @floatFromInt((hex >> 16) & 0xFF),
        .g = @floatFromInt((hex >> 8) & 0xFF),
        .b = @floatFromInt(hex & 0xFF),
    };
}

pub fn rgbToAnsi256(self: RGBA) u8 {
    if (self.r == self.g and self.g == self.b) {
        if (self.r < 8.0) return 16;
        if (self.r > 248.0) return 231;
        return @intFromFloat(@round(((self.r - 8.0) / 247.0) * 24) + 232);
    }

    return @intFromFloat(16 + 36 * @round(self.r / 255.0 * 5) + 6 * @round(self.g / 255.0 * 5) + @round(self.b / 255.0 * 5));
}
