const std = @import("std");
const ts = @import("tree-sitter");
const builtin = @import("builtin");
const Testing = @import("./testing.zig");
const File = @import("./fs.zig").File;

extern fn tree_sitter_tsx() callconv(.C) *ts.Language;

pub const ParserErrors = error{
    OutOfMemory,
    ParseError,
    FileIsNotParsed,
    IOError,
};

pub const ParserContext = struct {
    allocator: std.mem.Allocator,
    file_parsers: std.ArrayListUnmanaged(*FileParser),
    parser: *ts.Parser,

    pub fn init(allocator: std.mem.Allocator) !ParserContext {
        const file_parsers = std.ArrayListUnmanaged(*FileParser).initCapacity(allocator, 16) catch {
            return ParserErrors.OutOfMemory;
        };
        const ts_parser = ts.Parser.create();
        ts_parser.setLanguage(tree_sitter_tsx()) catch unreachable;
        return .{ .allocator = allocator, .file_parsers = file_parsers, .parser = ts_parser };
    }

    pub fn forFile(self: *ParserContext, file: File) ParserErrors!*FileParser {
        const parser = try self.allocator.create(FileParser);
        parser.* = try .init(self, file);
        self.file_parsers.append(self.allocator, parser) catch {
            self.allocator.destroy(parser);
            return ParserErrors.OutOfMemory;
        };
        return parser;
    }

    pub fn deinit(self: *ParserContext) void {
        for (self.file_parsers.items) |fp| {
            fp.deinit();
            fp.* = undefined;
            self.allocator.destroy(fp);
        }
        self.file_parsers.deinit(self.allocator);
    }
};

pub const FileParser = struct {
    const CurrentParse = struct {
        tree: *ts.Tree,
        content: []const u8,
        imports: ?*Imports,
    };

    ctx: *ParserContext,
    file: File,

    // cached state
    current_parse: ?*CurrentParse,

    pub fn init(ctx: *ParserContext, file: File) ParserErrors!FileParser {
        return .{
            .ctx = ctx,
            .file = file,
            .current_parse = null,
        };
    }

    pub fn deinit(self: *FileParser) void {
        self.freeCurrentParse();
    }

    fn freeCurrentParse(self: *FileParser) void {
        if (self.current_parse) |parsed| {
            parsed.tree.destroy();
            if (parsed.imports) |imports| {
                imports.deinit();
                self.ctx.allocator.destroy(imports);
            }
            self.ctx.allocator.free(parsed.content);
            self.ctx.allocator.destroy(parsed);
            self.current_parse = null;
        }
    }

    pub fn parse(self: *FileParser) ParserErrors!void {
        const file_content = self.file.readAll(self.ctx.allocator) catch |e| {
            std.log.info("Failed to read file '{s}' due to {s}", .{ self.file.toString(), @errorName(e) });
            return ParserErrors.IOError;
        };
        const old_tree: ?*ts.Tree = blk: {
            if (self.current_parse) |cp| {
                break :blk cp.tree;
            } else {
                break :blk null;
            }
        };
        if (self.ctx.parser.parseString(file_content, old_tree)) |tree| {
            self.freeCurrentParse();
            const next_parse = try self.ctx.allocator.create(CurrentParse);
            next_parse.* = .{
                .tree = tree,
                .content = file_content,
                .imports = null,
            };
            self.current_parse = next_parse;
        } else {
            return ParserErrors.ParseError;
        }
    }

    pub fn getReferencedImports(
        self: *FileParser,
    ) ParserErrors![]const Import {
        if (self.current_parse) |current_parse| {
            if (current_parse.imports) |imports| {
                return imports.values();
            }
            const imports = try self.ctx.allocator.create(Imports);
            imports.* = try .init(self.ctx.allocator, current_parse);
            current_parse.imports = imports;
            return imports.values();
        } else {
            @panic("Illegal state: file is not parsed");
        }
    }
};

fn walk_tree_dfs(
    Context: type,
    ErrorSet: type,
    context_ptr: *Context,
    current_parse: *FileParser.CurrentParse,
    on_node_callback: fn (ctx: *Context, current_parse: *FileParser.CurrentParse, node: ts.Node) ErrorSet!void,
) ErrorSet!void {
    var cursor = current_parse.tree.walk();
    defer cursor.destroy();

    while (true) {
        const node = cursor.node();

        if (builtin.is_test) {
            std.log.debug("walk_tree_dfs: {s} at depth {d}", .{ node.kind(), cursor.depth() });
        }

        try on_node_callback(context_ptr, current_parse, node);

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

pub const Imports = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Import),

    pub fn init(alloc: std.mem.Allocator, current_parse: *FileParser.CurrentParse) error{ OutOfMemory, ParseError }!Imports {
        const import_list = try std.ArrayListUnmanaged(Import).initCapacity(alloc, 8);
        var instance: Imports = .{ .list = import_list, .alloc = alloc };
        try walk_tree_dfs(Imports, error{ OutOfMemory, ParseError }, &instance, current_parse, Imports.appendReferencedImport);
        return instance;
    }

    pub fn values(self: *const Imports) []const Import {
        return self.list.items;
    }

    pub fn deinit(self: *Imports) void {
        self.list.deinit(self.alloc);
    }

    fn appendReferencedImport(self: *Imports, current_parse: *FileParser.CurrentParse, node: ts.Node) error{ OutOfMemory, ParseError }!void {
        if (std.mem.eql(u8, node.kind(), "import_statement")) {
            if (node.childByFieldName("source")) |src_node| {
                if (src_node.child(1)) |src_string_node| {
                    const file_content = current_parse.content;
                    // Obtain string node
                    const start = src_string_node.startByte();
                    const end = src_string_node.endByte();
                    const len = end - start;
                    const start_address: [*]const u8 = file_content.ptr + start;
                    const str_slice = start_address[0..len];
                    std.log.debug("Found import_statement: '{s}'", .{str_slice});
                    const import = Import{ .src = str_slice };
                    self.list.append(self.alloc, import) catch {
                        return error.OutOfMemory;
                    };
                } else {
                    std.log.err("Expected 'source' field to have a child at index 1, but it does not node={s}", .{src_node.kind()});
                    return error.ParseError;
                }
            }
        }
    }
};

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
    const Fs = @import("./fs.zig").VirtualFs;
    const FsPath = @import("./FsPath.zig").FsPath;

    testing.register(@src());
    testing.setLogLevel(.info);

    var fs = try Fs.init(testing.allocator);
    defer fs.deinit();

    try fs.mkDir(FsPath.static("/test-dir"));
    try fs.create(FsPath.static("/test-dir/test.tsx"));

    var test_file = try fs.open(FsPath.static("/test-dir/test.tsx"));
    defer test_file.close();

    const file_content =
        \\ import { math } from '@std/core'
        \\ import baz from '../baz' ;
        \\ import bar from 'npm'
        \\ const gg = 'vv'
    ;
    try test_file.writeAll(file_content[0..]);

    var ctx: ParserContext = try .init(testing.allocator);
    defer ctx.deinit();

    var file_parser: *FileParser = try ctx.forFile(test_file);
    defer file_parser.deinit();

    try file_parser.parse();

    const imports = try file_parser.getReferencedImports();
    try testing.expectEqual("Import count should be 3", imports.len, 3);
}
