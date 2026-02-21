const std = @import("std");
const builtin = @import("builtin");

const shell = @import("shell.zig");


pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = arena.allocator();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_writer.interface;

    const stdin_buf: []u8 = try allocator.alloc(u8, 1024);

    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf);
    const stdin = &stdin_reader.interface;
    
    var sh = try shell.Shell.init(io, stdout, stderr, stdin_buf, stdin, allocator, init.environ_map);

    try stdout.print("Hello World!\n", .{});

    // Shell Sequence: Init -> Interpret -> Terminate

    // Load config files

    // Run command loop
    try sh.loop();

    // Perform shutdown
}

