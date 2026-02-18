const std = @import("std");

pub const Config = struct {
    size: Size = .default,
    show_block_size: bool = false,
    show_permissions: bool = false,

    pub const default: @This() = .{};

    pub const Size = union(enum) {
        dynamic: struct {
            units: std.Io.Writer.ByteSizeUnits = .decimal,
            precision: usize = 2,
        },
        bytes,
        decimal: Decimal,
        binary: Binary,

        pub const default: @This() = .{ .dynamic = .{ .units = .decimal, .precision = 2 } };

        pub const Decimal = enum {
            kB, // Kilobyte
            MB, // Megabyte
            GB, // Gigabyte
            TB, // Terabyte

            pub fn fromBytes(self: @This(), bytes: usize) f64 {
                const f: f64 = @floatFromInt(bytes);
                return switch (self) {
                    .kB => f / 1_000.0,
                    .MB => f / 1_000_000.0,
                    .GB => f / 1_000_000_000.0,
                    .TB => f / 1_000_000_000_000.0,
                };
            }
        };

        pub const Binary = enum {
            KiB, // Kibibyte = 1,024 bytes
            MiB, // Mebibyte = 1,024² bytes
            GiB, // Gibibyte = 1,024³ bytes
            TiB, // Tebibyte = 1,024⁴ bytes

            pub fn fromBytes(self: @This(), bytes: usize) f64 {
                const f: f64 = @floatFromInt(bytes);
                return switch (self) {
                    .KiB => f / 1024.0,
                    .MiB => f / (1024.0 * 1024.0),
                    .GiB => f / (1024.0 * 1024.0 * 1024.0),
                    .TiB => f / (1024.0 * 1024.0 * 1024.0 * 1024.0),
                };
            }
        };

        pub fn format(self: @This(), writer: *std.Io.Writer, size: u64) !void {
            switch (self) {
                .dynamic => |dynamic| switch (dynamic.units) {
                    .decimal => try writer.printByteSize(size, .decimal, .{ .precision = dynamic.precision }),
                    .binary => try writer.printByteSize(size, .binary, .{ .precision = dynamic.precision }),
                },
                .bytes => try writer.print("{d}", .{size}),
                .decimal => |decimal| try writer.print("{d:.2}{t}", .{ decimal.fromBytes(size), decimal }),
                .binary => |binary| try writer.print("{d:.2}{t}", .{ binary.fromBytes(size), binary }),
            }
        }
    };

    pub fn get(io: std.Io, init: std.process.Init, allocator: std.mem.Allocator) !?@This() {
        const user = init.environ_map.get("USER") orelse return error.NoUserEnviormentVariable;
        const home_path = try std.fmt.allocPrint(allocator, "/home/{s}", .{user});
        const home: std.Io.Dir = try .openDirAbsolute(io, home_path, .{});
        allocator.free(home_path);
        const source = home.readFileAllocOptions(io, ".config/bstat/config.zon", allocator, .unlimited, .of(u8), 0) catch |err| return switch (err) {
            error.FileNotFound => null,
            else => err,
        };
        defer allocator.free(source);

        return try std.zon.parse.fromSlice(Config, allocator, source, null, .{});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const sub_path = args.next() orelse return error.NoPathSpecified;

    var config: Config = try Config.get(io, init, allocator) orelse .default;
    while (args.next()) |arg| {
        if (std.meta.stringToEnum(Config.Size.Decimal, arg)) |decimal| {
            config.size = .{ .decimal = decimal };
        } else if (std.meta.stringToEnum(Config.Size.Binary, arg)) |binary| {
            config.size = .{ .binary = binary };
        }
    }

    const stat = try std.Io.Dir.cwd().statFile(io, sub_path, .{ .follow_symlinks = true });

    var stdout_writer_buffer: [512]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_writer_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("{t}: {s}\n", .{ stat.kind, std.Io.Dir.path.basename(sub_path) });
    if (stat.kind != .directory) {
        try stdout.writeAll("size: ");
        try config.size.format(stdout, stat.size);
        try stdout.writeByte('\n');

        if (config.show_block_size) try stdout.print("block size: {d}\n", .{stat.block_size});
    }
    if (config.show_permissions) {
        const mode: std.posix.mode_t = stat.permissions.toMode();
        const buf = posixSymbolicFileMode(stat.kind, mode);
        try stdout.print("permissions: ({o:0>4}/{s})\n", .{ mode & 0o7777, buf });
    }

    try stdout.flush();
}

/// Converts a file's kind and mode to the POSIX symbolic file mode string,
/// e.g. "drwxr-xr-x"
pub fn posixSymbolicFileMode(kind: std.Io.File.Kind, mode: std.posix.mode_t) [10]u8 {
    var buf: [10]u8 = undefined;

    // File type
    buf[0] = switch (kind) {
        .file => '-',
        .directory => 'd',
        .sym_link => 'l',
        .block_device => 'b',
        .character_device => 'c',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        else => '?',
    };

    // Owner permissions
    buf[1] = if (mode & std.posix.S.IRUSR != 0) 'r' else '-';
    buf[2] = if (mode & std.posix.S.IWUSR != 0) 'w' else '-';
    buf[3] = if (mode & std.posix.S.ISUID != 0)
        if (mode & std.posix.S.IXUSR != 0) 's' else 'S'
    else if (mode & std.posix.S.IXUSR != 0) 'x' else '-';

    // Group permissions
    buf[4] = if (mode & std.posix.S.IRGRP != 0) 'r' else '-';
    buf[5] = if (mode & std.posix.S.IWGRP != 0) 'w' else '-';
    buf[6] = if (mode & std.posix.S.ISGID != 0)
        if (mode & std.posix.S.IXGRP != 0) 's' else 'S'
    else if (mode & std.posix.S.IXGRP != 0) 'x' else '-';

    // Others permissions
    buf[7] = if (mode & std.posix.S.IROTH != 0) 'r' else '-';
    buf[8] = if (mode & std.posix.S.IWOTH != 0) 'w' else '-';
    buf[9] = if (mode & std.posix.S.ISVTX != 0)
        if (mode & std.posix.S.IXOTH != 0) 't' else 'T'
    else if (mode & std.posix.S.IXOTH != 0) 'x' else '-';

    return buf;
}
