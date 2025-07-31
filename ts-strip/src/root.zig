const Testing = @import("./testing.zig");
const std = @import("std");
const ParserContext = @import("./parser.zig").ParserContext;
const FileParser = @import("./parser.zig").FileParser;
pub const File = @import("./file.zig").File;

test "tsstripper basic test" {
    try Testing.run(tsstripperBasicTest);
}

fn tsstripperBasicTest(testing: *Testing) anyerror!void {
    testing.register(@src());

    const test_file = File.virtual("test.tsx");
    defer test_file.close();

    const file_content =
        \\ import { math } from '@std/core'
        \\ import baz from '../baz' ;
        \\ import bar from 'npm'
        \\ const gg = 'vv'
    ;
    test_file.write(file_content[0..]);

    var ctx: ParserContext = try .init(testing.allocator);
    defer ctx.deinit();
    var file_parser: FileParser = try ctx.forFile(test_file);
    defer file_parser.deinit();

    try file_parser.parse();
    const imports = try file_parser.getReferencedImports();

    std.log.info("Found import count: {d}", .{imports.len});
    for (imports) |import| {
        std.log.info("Found import: {s}", .{import.src});
    }
}
