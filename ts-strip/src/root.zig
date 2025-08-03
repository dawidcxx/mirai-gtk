const Testing = @import("./testing.zig");

test "tsstripper basic test" {
    try Testing.run(tsstripperBasicTest);
}

fn tsstripperBasicTest(t: *Testing) anyerror!void {
    t.register(@src());
}
