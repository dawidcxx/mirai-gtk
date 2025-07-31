const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_core_dep = b.dependency("tree_sitter_core", .{
        .target = target,
        .optimize = optimize,
    });

    const typescript_grammar_lib = b.addStaticLibrary(.{
        .name = "tree-sitter-typescript",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    typescript_grammar_lib.addIncludePath(b.path("c/"));
    typescript_grammar_lib.addIncludePath(b.path("c/tree_sitter"));
    typescript_grammar_lib.addCSourceFile(.{ .file = b.path("c/parser.c") });
    typescript_grammar_lib.addCSourceFile(.{ .file = b.path("c/scanner.c") });
    typescript_grammar_lib.linkLibrary(tree_sitter_core_dep.artifact("tree-sitter"));

    const tree_sitter = b.dependency("tree_sitter", .{
        .optimize = optimize,
        .target = target,
    });

    const tsstripper = b.addModule("tsstripper", .{
        .root_source_file = b.path("./src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    tsstripper.addImport("tree-sitter", tree_sitter.module("tree-sitter"));
    tsstripper.linkLibrary(typescript_grammar_lib);

    const tsstripper_tests = b.addTest(.{
        .root_module = tsstripper,
        .target = target,
        .optimize = .Debug,
    });

    const run_tsstripper_tests = b.addRunArtifact(tsstripper_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tsstripper_tests.step);
}
