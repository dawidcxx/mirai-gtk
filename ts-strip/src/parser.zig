const std = @import("std");
const ts = @import("tree-sitter");
const builtin = @import("builtin");
const Testing = @import("./testing.zig");
const File = @import("./fs.zig").File;

extern fn tree_sitter_tsx() callconv(.C) *ts.Language;

const ROOT_PARSER_SPECIAL_NAME = "@ROOT_PARSER";
const MAX_FILE_SIZE_IN_BYTES = 1024 * 1024 * 2; // 2 MB

pub const ParserErrors = error{
    OutOfMemory,
    ParseError,
    FileIsNotParsed,
};

pub const FileParser = struct {
    ctx: *ParserContext,
    file: File,

    // cached state
    file_content: ?[]u8,
    tree: ?*ts.Tree,
    referenced_imports: std.ArrayListUnmanaged(Import),

    pub fn init(ctx: *ParserContext, file: File) ParserErrors!FileParser {
        const referenced_imports = std.ArrayListUnmanaged(Import).initCapacity(ctx.allocator, 16) catch return ParserErrors.OutOfMemory;
        return .{ .ctx = ctx, .file = file, .tree = null, .file_content = null, .referenced_imports = referenced_imports };
    }

    pub fn deinit(self: *FileParser) void {
        self.clean_cached();
        self.referenced_imports.deinit(self.ctx.allocator);
    }

    pub fn parse(self: *FileParser) ParserErrors!void {
        const file_content = self.file.readAll(self.ctx.allocator) catch |e| {
            std.debug.panic("Unexpected error while reading file '{s}': '{}'", .{ try self.file.toString(), e });
        };
        if (self.ctx.parser.parseString(file_content, self.tree)) |tree| {
            self.clean_cached(); // invalidate all cache on re-parse
            self.tree = tree;
            self.file_content = file_content;
        } else {
            return ParserErrors.ParseError;
        }
    }
    pub fn isParsed(self: *FileParser) bool {
        return self.tree != null;
    }

    pub fn getReferencedImports(
        self: *FileParser,
    ) ParserErrors![]Import {
        if (self.tree) |tree| {
            self.referenced_imports.clearRetainingCapacity();
            try walk_tree_dfs(FileParser, self, tree, FileParser.appendReferencedImport);
            return self.referenced_imports.items;
        } else {
            @panic("FileParser.getReferencedImports called before parsing the file");
        }
    }

    fn appendReferencedImport(self: *FileParser, node: ts.Node) ParserErrors!void {
        if (std.mem.eql(u8, node.kind(), "import_statement")) {
            if (node.childByFieldName("source")) |src_node| {
                if (src_node.child(1)) |src_string_node| {
                    const file_content = self.file_content orelse unreachable;

                    // Obtain string node
                    const start = src_string_node.startByte();
                    const end = src_string_node.endByte();
                    const len = end - start;
                    const start_address: [*]const u8 = file_content.ptr + start;
                    const str_slice = start_address[0..len]; // lifetime is bound to self.tree
                    std.log.debug("Found import_statement: '{s}'", .{str_slice});
                    self.referenced_imports.append(self.ctx.allocator, Import{ .src = str_slice }) catch {
                        return ParserErrors.OutOfMemory;
                    };
                } else {
                    std.log.err("Expected 'source' field to have a child at index 1, but it does not.", .{});
                    return error.ParseError;
                }
            }
        }
    }

    fn clean_cached(self: *FileParser) void {
        self.referenced_imports.clearRetainingCapacity();
        if (self.tree) |tree| {
            tree.destroy();
            // file_content is guaranteed to be non-null after parsing
            self.ctx.allocator.free(self.file_content.?);
        }
    }
};

pub const ParserContext = struct {
    allocator: std.mem.Allocator,
    file_parsers: std.ArrayListUnmanaged(FileParser),
    parser: *ts.Parser,

    pub fn init(allocator: std.mem.Allocator) !ParserContext {
        const file_parsers = std.ArrayListUnmanaged(FileParser).initCapacity(allocator, 16) catch {
            return ParserErrors.OutOfMemory;
        };
        const ts_parser = ts.Parser.create();
        ts_parser.setLanguage(tree_sitter_tsx()) catch unreachable;
        return .{ .allocator = allocator, .file_parsers = file_parsers, .parser = ts_parser };
    }

    pub fn forFile(self: *ParserContext, file: File) ParserErrors!FileParser {
        const file_parser: FileParser = try .init(self, file);
        self.file_parsers.append(self.allocator, file_parser) catch {
            return ParserErrors.OutOfMemory;
        };
        return file_parser;
    }

    pub fn deinit(self: *ParserContext) void {
        self.file_parsers.deinit(self.allocator);
    }
};

fn walk_tree_dfs(Context: type, context_ptr: *Context, tree: *ts.Tree, on_node_callback: fn (ctx: *Context, node: ts.Node) ParserErrors!void) ParserErrors!void {
    var cursor = tree.walk();
    defer cursor.destroy();

    while (true) {
        const node = cursor.node();

        if (builtin.is_test) {
            std.log.debug("walk_tree_fs: {s} at depth {d}", .{ node.kind(), cursor.depth() });
        }

        try on_node_callback(context_ptr, node);

        if (cursor.gotoFirstChild()) {
            continue;
        }
        if (cursor.gotoNextSibling()) {
            continue;
        }
        var has_more_elements = false;
        while (cursor.gotoParent()) {
            if (cursor.gotoNextSibling()) {
                has_more_elements = true;
                break;
            }
        }
        if (!has_more_elements) {
            break;
        }
    }
}

pub const Import = struct {
    src: []const u8,
    pub fn is_relative(self: Import) bool {
        return std.mem.eql(u8, self.src[0], ".");
    }
};

test "simple parser check" {
    try Testing.run(simpleParserCheck);
}

fn simpleParserCheck(testing: *Testing) anyerror!void {
    testing.register(@src());
    testing.setLogLevel(.info);

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
    try testing.expectEqual("Import count should be 3", imports.len, 3);
}
