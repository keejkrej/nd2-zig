const std = @import("std");
const nd2_mod = @import("nd2");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path-to-nd2-file>\n", .{args[0]});
        std.process.exit(1);
    }

    const path = args[1];
    var nd2 = try nd2_mod.Nd2File.open(allocator, io, path);
    defer nd2.deinit();

    const ver = nd2.version();
    try stdout.print("=== ND2 File Information ===\n", .{});
    try stdout.print("Version: {d}.{d}\n", .{ ver.major, ver.minor });

    var summary = try nd2.summary();
    defer summary.deinit(allocator);

    try stdout.print("Logical frames: {d}\n", .{summary.logical_frame_count});
    try stdout.print(
        "Sizes: X={d} Y={d} C={d} Z={d} T={d} P={d}\n",
        .{
            summary.sizes.X,
            summary.sizes.Y,
            summary.sizes.C,
            summary.sizes.Z,
            summary.sizes.T,
            summary.sizes.P,
        },
    );

    const first_plane = try nd2.readFrame2d(0, 0, 0, 0);
    defer allocator.free(first_plane);
    try stdout.print("First plane pixels: {d}\n", .{first_plane.len});
}
