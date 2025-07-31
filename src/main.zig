const std = @import("std");
const lib = @import("mirai_gtk_lib");

pub fn main() !void {
    std.debug.print("Mirai-GTK entry point goes here.\n", .{});
}

test "test runner check" {
    try std.testing.expectEqual(4, 2 + 2);
}
