const std = @import("std");
const builtin = @import("builtin");

pub const Status = enum {
    Ok,
    StdErr,
    Exit,
    NotOk,
};

pub const Builtin = struct {
    name: []const u8,
    desc: []const u8,
    /// A function with the signature: fn builtin_func(io, stdout, stderr, args) !Status;
    func: fn (*Shell, []const []const u8) anyerror!Status,

    fn execute(self: Builtin, shell: *Shell, args: []const []const u8) !Status {
        return self.func(shell, args);
    }
};

pub const sh_builtins: [6]Builtin = [_]Builtin{
    Builtin{
        .name = "exit",
        .desc = "exits the shell",
        .func = Shell.exit,
    },
    Builtin{
        .name = "help",
        .desc = "prints this",
        .func = Shell.help,
    },
    Builtin{
        .name = "logo",
        .desc = "prints logo",
        .func = Shell.logo,
    },
    Builtin{
        .name = "cd",
        .desc = "cd <path> - changes directory to path",
        .func = Shell.cd,
    },
    Builtin{
        .name = "pwd",
        .desc = "prints cwd to stdout",
        .func = Shell.pwd,
    },
    Builtin{ .name = "alias", .desc = "set shell alias", .func = Shell.alias },
};

pub const Shell = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdin: *std.Io.Reader,

    stdin_buf: []u8,

    status: Status,

    cwd: [std.Io.Dir.max_path_bytes]u8,
    cwd_len: usize = undefined,

    aliases: std.StringHashMap([]const u8),

    pub fn init(io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer, stdin_buf: []u8, stdin: *std.Io.Reader, allocator: std.mem.Allocator) !Shell {
        const map = std.StringHashMap([]const u8).init(allocator);

        return Shell{
            .io = io,
            .allocator = allocator,
            .stdout = stdout,
            .stderr = stderr,
            .stdin = stdin,
            .stdin_buf = stdin_buf,
            .status = .Ok,
            .cwd = undefined,
            .aliases = map,
        };
    }

    fn set_cwd(self: *Shell) usize {
        const cwd_len = std.os.linux.getcwd(&self.cwd, std.Io.Dir.max_path_bytes);
        self.cwd_len = cwd_len;
        return cwd_len;
    }

    // Read -> Parse -> Execute
    pub fn loop(self: *Shell) !void {
        var status: Status = .Ok;

        _ = self.set_cwd();

        while (status == .Ok or status == .StdErr) {
            try self.stdout.print("{s} > ", .{self.cwd[0..self.cwd_len]});
            const line: []const u8 = try self.read_line();

            // try stdout.print("Line: {s}\nWith Length: {}\n", .{line, line.len});

            if (line.len == 0) continue;

            var tokens_buf = try self.allocator.alloc([]const u8, line.len);
            const arg_cnt = try parse_line(line, &tokens_buf);

            const args: []const []const u8 = tokens_buf[0..arg_cnt];
            status = try self.execute(args);
        }
    }

    fn read_line(self: *Shell) ![]const u8 {
        const bare_line = (try self.stdin.takeDelimiter('\n')).?;
        const line = std.mem.trim(u8, bare_line, "\r");
        return line;
    }

    /// Returns number of arguments
    fn parse_line(line: []const u8, buf: *[][]const u8) !usize {
        var it = std.mem.tokenizeAny(u8, line, "\n \r");
        var i: usize = 0;
        while (it.next()) |token| : (i += 1) {
            if (i >= buf.*.len) return error.OutOfTokenSpace;
            buf.*[i] = token;
        }

        return i;
    }

    fn replace_env(allocator: std.mem.Allocator, buf: *[][]const u8) void {
        for (buf, 0..) |token, i| {
            if (token[0] == '$') {
                std.process.Environ.contains(.empty, allocator, buf[i]);
            }
        }
    }

    fn launch(self: *Shell, argv: []const []const u8) !Status {
        var child: std.process.Child = std.process.spawn(self.io, .{ .argv = argv }) catch |err| {
            try self.stderr.print("sh: {s}\n", .{@errorName(err)});
            return .StdErr;
        };

        const term = try child.wait(self.io);
        _ = term;

        return .Ok;
    }

    fn execute(self: *Shell, args: []const []const u8) !Status {
        inline for (sh_builtins) |sh_builtin| {
            if (std.mem.eql(u8, args[0], sh_builtin.name)) return sh_builtin.execute(@constCast(self), args);
        }

        return self.launch(args);
    }

    /// Shell builtin for printing logo, TODO: Make configurable
    fn logo(shell: *Shell, args: []const []const u8) !Status {
        _ = args;
        try shell.stdout.print("      _       _     \n  ___| |_ ___| |__  \n / __| __/ __| '_ \\ \n \\__ \\ |_\\__ \\ | | |\n |___/\\__|___/_| |_|\n\n", .{});
        return .Ok;
    }

    /// Exits the shell
    fn exit(shell: *Shell, args: []const []const u8) !Status {
        _ = shell;
        _ = args;
        return .Exit;
    }

    /// Prints help screen
    fn help(shell: *Shell, args: []const []const u8) !Status {
        _ = try Shell.logo(shell, args);
        try shell.stdout.print("Welcome to st(upid) sh(ell)\n\n", .{});
        try shell.stdout.print("Shell builtins: \n", .{});

        inline for (sh_builtins) |sh_builtin| {
            try shell.stdout.print(" - {s}: {s}\n", .{ sh_builtin.name, sh_builtin.desc });
        }

        try shell.stdout.print("\nuse man pages for more info on other commands\n\n", .{});

        if (builtin.os.tag != .linux) {
            try shell.stdout.print("please use linux for all of the features of stsh\ncurrent os: {any}", .{builtin.os.tag});
        }

        return .Ok;
    }

    /// Change Directory
    fn cd(shell: *Shell, args: []const []const u8) !Status {
        if (args.len <= 1) {
            try shell.stderr.print("sh: expected argument to \"cd\"\n", .{});
            return .StdErr;
        }

        // std.debug.print("{any}\n", .{args[1]});
        //

        switch (comptime builtin.os.tag) {
            .linux => {
                var path: [*:0]u8 = try shell.allocator.allocSentinel(u8, args[1].len + 1, 0);
                @memcpy(path[0..args[1].len], args[1]);
                path[args[1].len] = 0;

                const err_code = std.os.linux.chdir(path);
                if (err_code == 0) {
                    _ = shell.set_cwd();
                    return .Ok;
                }

                // pretify the errors
                const err = std.os.linux.errno(err_code);
                switch (err) {
                    .NOENT => try shell.stderr.print("sh: No such file or directory\n", .{}),

                    else => try shell.stderr.print("sh: {any} with error code: {}\n", .{ std.os.linux.errno(err_code), err_code }),
                }

                return .StdErr;
            },
            else => {
                try shell.stderr.print("sh: {any} not supported for \"cd\"", .{comptime builtin.os.tag});
                return .StdErr;
            },
        }
    }

    fn pwd(shell: *Shell, args: []const []const u8) !Status {
        _ = args;
        try shell.stdout.print("{s}\n", .{shell.cwd[0..shell.cwd_len]});
        return .Ok;
    }

    fn alias(shell: *Shell, args: []const []const u8) !Status {
        if (args.len == 1) {
            try shell.stdout.print("KEY: ", .{});
            const key_line = try shell.read_line();

            const key = try shell.allocator.alloc(u8, key_line.len);
            @memcpy(key, key_line);

            try shell.stdout.print("VALUE: ", .{});
            const value_line = try shell.read_line();

            const value = try shell.allocator.alloc(u8, value_line.len);
            @memcpy(value, value_line);

            try shell.aliases.put(key, value);
        }

        var iter = shell.aliases.iterator();

        while (iter.next()) |entry| {
            std.debug.print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }

        return .Ok;
    }
};
