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

    var output_writer_buffer: [128]u8 = undefined;
    var output_writer: std.Io.File.Writer = .init(.stdout(), io, &output_writer_buffer);
    const output = &output_writer.interface;

    try output.print("{t}: {s}\n", .{ stat.kind, std.Io.Dir.path.basename(sub_path) });

    try output.writeAll("size: ");
    const size = if (stat.kind != .directory) stat.size else size: {
        var stdout_writer_buffer: [6]u8 = undefined;
        var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_writer_buffer);
        const stdout = &stdout_writer.interface;

        var loading_future = try io.concurrent(loading, .{ io, stdout });

        const dir = try std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true });
        defer dir.close(io);
        const size = try getDirectorySizeRecursive(io, dir);

        _ = loading_future.cancel(io) catch {};
        try stdout.writeByte('\r');
        try stdout.flush();

        break :size size;
    };
    try config.size.format(output, size);
    try output.writeByte('\n');

    if (stat.kind != .directory and config.show_block_size) try output.print("block size: {d}\n", .{stat.block_size});

    if (config.show_permissions) {
        const mode: std.posix.mode_t = stat.permissions.toMode();
        const buf = posixSymbolicFileMode(stat.kind, mode);
        try output.print("permissions: ({o:0>4}/{s})\n", .{ mode & 0o7777, buf });
    }

    try output.flush();
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

pub fn getDirectorySizeRecursive(io: std.Io, dir: std.Io.Dir) !u64 {
    var size: u64 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| switch (entry.kind) {
        .directory => {
            const sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub_dir.close(io);

            size += try getDirectorySizeRecursive(io, sub_dir);
        },
        else => {
            const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            size += stat.size;
        },
    };

    return size;
}

pub fn loading(io: std.Io, writer: *std.Io.Writer) !void {
    var index: usize = 0;
    const loading_bars: []const []const u8 = &.{
        "·..",
        ".·.",
        "..·",
        ".·.",
    };

    while (true) : (index += 1) {
        const current_loading_bar = loading_bars[index % loading_bars.len];
        try writer.writeByte('\r');
        try writer.writeAll(current_loading_bar);
        try writer.flush();

        _ = try io.sleep(.fromMilliseconds(100), .real);
    }
}
