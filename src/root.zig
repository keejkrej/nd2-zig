const std = @import("std");

pub const constants = @import("constants.zig");
pub const err = @import("error.zig");
pub const io = @import("io.zig");
pub const chunk_header = @import("chunk/header.zig");
pub const chunk_map = @import("chunk/map.zig");
pub const clx_lite = @import("parse/clx_lite.zig");
pub const attributes_meta = @import("metadata/attributes.zig");
pub const experiment_meta = @import("metadata/experiment.zig");
pub const text_info_meta = @import("metadata/text_info.zig");
pub const reader = @import("reader.zig");
pub const types = @import("types/mod.zig");

pub const Nd2Error = err.Nd2Error;
pub const ErrorSource = err.ErrorSource;
pub const classifyError = err.classifyError;
pub const isFileError = err.isFileError;
pub const isInputError = err.isInputError;
pub const isInternalError = err.isInternalError;
pub const isUnsupportedError = err.isUnsupportedError;

pub const Source = io.Source;
pub const Nd2File = reader.Nd2File;

pub const Attributes = types.Attributes;
pub const Color = types.Color;
pub const CompressionType = types.CompressionType;
pub const CustomLoop = types.CustomLoop;
pub const DatasetSummary = types.DatasetSummary;
pub const DimensionSizes = types.DimensionSizes;
pub const ExpLoop = types.ExpLoop;
pub const NETimeLoop = types.NETimeLoop;
pub const NETimeLoopParams = types.NETimeLoopParams;
pub const Period = types.Period;
pub const PeriodDiff = types.PeriodDiff;
pub const PixelDataType = types.PixelDataType;
pub const Position = types.Position;
pub const StagePosition = types.StagePosition;
pub const SummaryChannel = types.SummaryChannel;
pub const SummaryScaling = types.SummaryScaling;
pub const TextInfo = types.TextInfo;
pub const TimeLoop = types.TimeLoop;
pub const TimeLoopParams = types.TimeLoopParams;
pub const XYPosLoop = types.XYPosLoop;
pub const XYPosLoopParams = types.XYPosLoopParams;
pub const ZStackLoop = types.ZStackLoop;
pub const ZStackLoopParams = types.ZStackLoopParams;

test "open nonexistent fails" {
    const res = Nd2File.open(std.testing.allocator, std.testing.io, "nonexistent_file_xyz.nd2");
    try std.testing.expectError(error.IoError, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
    }
}

test "open invalid file fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const garbage: [200]u8 = @splat(0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "garbage.nd2", .data = &garbage });

    const file = try tmp.dir.openFile(std.testing.io, "garbage.nd2", .{});
    var src: Source = .{ .file = .{ .file = file, .io = std.testing.io, .owned = true } };
    defer src.close();

    const res = Nd2File.openSource(std.testing.allocator, src);
    try std.testing.expectError(error.InvalidMagic, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
    }
}

test "open memory invalid stream" {
    const garbage: [100]u8 = @splat(0);
    const res = Nd2File.openMemory(std.testing.allocator, &garbage);
    try std.testing.expectError(error.InvalidFormat, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
        try std.testing.expectEqual(ErrorSource.file, classifyError(e));
    }
}

test "error classification helpers" {
    try std.testing.expect(isFileError(error.InvalidFormat));
    try std.testing.expect(!isInputError(error.InvalidFormat));
    try std.testing.expect(!isInternalError(error.InvalidFormat));
    try std.testing.expect(!isUnsupportedError(error.InvalidFormat));

    try std.testing.expect(!isFileError(error.OutOfRange));
    try std.testing.expect(isInputError(error.OutOfRange));

    try std.testing.expect(isInternalError(error.Overflow));
    try std.testing.expect(isUnsupportedError(error.UnsupportedVersion));
}

fn appendClxU32Field(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, val: u32) !void {
    try list.append(allocator, constants.clx_types.UINT32);
    try list.append(allocator, @intCast(name.len + 1));
    for (name) |c| {
        try list.append(allocator, c);
        try list.append(allocator, 0);
    }
    try list.append(allocator, 0);
    try list.append(allocator, 0);
    var v_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &v_bytes, val, .little);
    try list.appendSlice(allocator, &v_bytes);
}

fn appendChunk(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, payload: []const u8) !u64 {
    const offset: u64 = @intCast(buf.items.len);
    var hdr: [16]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], constants.ND2_CHUNK_MAGIC, .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(name.len), .little);
    std.mem.writeInt(u64, hdr[8..16], @intCast(payload.len), .little);
    try buf.appendSlice(allocator, &hdr);
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, payload);
    return offset;
}

test "synthetic in-memory ND2 v3 file roundtrip" {
    const allocator = std.testing.allocator;
    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(allocator);

    // 1. File header chunk at offset 0 (16 + 32 + 64 = 112 bytes)
    var ver_data: [64]u8 = @splat(0);
    @memcpy(ver_data[0..6], "Ver3.0");
    _ = try appendChunk(&file_buf, allocator, constants.ND2_FILE_SIGNATURE, &ver_data);

    // 2. Build CLX Lite payload for ImageAttributesLV!
    // Level chunk named "SLxImageAttributes" with 6 UINT32 fields
    var inner_fields: std.ArrayList(u8) = .empty;
    defer inner_fields.deinit(allocator);
    try appendClxU32Field(&inner_fields, allocator, "uiBpcInMemory", 16);
    try appendClxU32Field(&inner_fields, allocator, "uiBpcSignificant", 16);
    try appendClxU32Field(&inner_fields, allocator, "uiComp", 1);
    try appendClxU32Field(&inner_fields, allocator, "uiHeight", 2);
    try appendClxU32Field(&inner_fields, allocator, "uiWidth", 2);
    try appendClxU32Field(&inner_fields, allocator, "uiSequenceCount", 1);

    var attr_clx: std.ArrayList(u8) = .empty;
    defer attr_clx.deinit(allocator);
    const level_name = "SLxImageAttributes";
    try attr_clx.append(allocator, constants.clx_types.LEVEL);
    try attr_clx.append(allocator, @intCast(level_name.len + 1));
    for (level_name) |c| {
        try attr_clx.append(allocator, c);
        try attr_clx.append(allocator, 0);
    }
    try attr_clx.append(allocator, 0);
    try attr_clx.append(allocator, 0);
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, 6, .little);
    try attr_clx.appendSlice(allocator, &count_bytes);
    var len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_bytes, @intCast(inner_fields.items.len), .little);
    try attr_clx.appendSlice(allocator, &len_bytes);
    try attr_clx.appendSlice(allocator, inner_fields.items);
    // 6 * 8 bytes of offset table
    const offset_pad: [48]u8 = @splat(0);
    try attr_clx.appendSlice(allocator, &offset_pad);

    const attr_offset = try appendChunk(&file_buf, allocator, "ImageAttributesLV!", attr_clx.items);
    const attr_total_size: u64 = 16 + "ImageAttributesLV!".len + attr_clx.items.len;

    // 3. ImageDataSeq|0! chunk (8-byte timestamp + 4 u16 pixels = 16 bytes)
    var seq0_payload: [16]u8 = @splat(0);
    std.mem.writeInt(u16, seq0_payload[8..10], 111, .little);
    std.mem.writeInt(u16, seq0_payload[10..12], 222, .little);
    std.mem.writeInt(u16, seq0_payload[12..14], 333, .little);
    std.mem.writeInt(u16, seq0_payload[14..16], 444, .little);
    const seq0_offset = try appendChunk(&file_buf, allocator, "ImageDataSeq|0!", &seq0_payload);
    const seq0_total_size: u64 = 16 + "ImageDataSeq|0!".len + seq0_payload.len;

    // 4. Chunkmap section
    var map_payload: std.ArrayList(u8) = .empty;
    defer map_payload.deinit(allocator);

    try map_payload.appendSlice(allocator, "ImageAttributesLV!");
    var off_sz: [16]u8 = undefined;
    std.mem.writeInt(u64, off_sz[0..8], attr_offset, .little);
    std.mem.writeInt(u64, off_sz[8..16], attr_total_size, .little);
    try map_payload.appendSlice(allocator, &off_sz);

    try map_payload.appendSlice(allocator, "ImageDataSeq|0!");
    std.mem.writeInt(u64, off_sz[0..8], seq0_offset, .little);
    std.mem.writeInt(u64, off_sz[8..16], seq0_total_size, .little);
    try map_payload.appendSlice(allocator, &off_sz);

    try map_payload.appendSlice(allocator, constants.ND2_CHUNKMAP_SIGNATURE);

    const chunkmap_offset = try appendChunk(&file_buf, allocator, constants.ND2_FILEMAP_SIGNATURE, map_payload.items);

    // 5. Trailing 40-byte signature + chunkmap_offset
    try file_buf.appendSlice(allocator, constants.ND2_CHUNKMAP_SIGNATURE);
    var map_off_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &map_off_bytes, chunkmap_offset, .little);
    try file_buf.appendSlice(allocator, &map_off_bytes);

    var nd2 = try Nd2File.openMemory(allocator, file_buf.items);
    defer nd2.deinit();

    const ver = nd2.version();
    try std.testing.expectEqual(@as(u32, 3), ver.major);
    try std.testing.expectEqual(@as(u32, 0), ver.minor);

    var summary = try nd2.summary();
    defer summary.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), summary.sizes.X);
    try std.testing.expectEqual(@as(usize, 2), summary.sizes.Y);
    try std.testing.expectEqual(@as(usize, 1), summary.sizes.C);
    try std.testing.expectEqual(@as(usize, 1), summary.logical_frame_count);
    try std.testing.expectEqualStrings("Unsigned16", summary.pixel_type.?);

    const plane = try nd2.readFrame2d(0, 0, 0, 0);
    defer allocator.free(plane);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 111, 222, 333, 444 }, plane);

    try std.testing.expectError(error.OutOfRange, nd2.readFrame2d(1, 0, 0, 0));
    try std.testing.expectError(error.OutOfRange, nd2.readFrame(1));
}

test "real OME ND2 fixture integration" {
    const allocator = std.testing.allocator;
    const io_ctx = std.testing.io;
    const fixture_path = "/Users/jack/workspace/nd2-zig/tests/fixtures/BF007.nd2";
    var nd2 = Nd2File.open(allocator, io_ctx, fixture_path) catch |e| switch (e) {
        error.IoError => return, // Skip if fixture not downloaded
        else => return e,
    };
    defer nd2.deinit();

    const ver = nd2.version();
    try std.testing.expect(ver.major >= 2 and ver.major <= 3);

    var summary = try nd2.summary();
    defer summary.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 164), summary.sizes.X);
    try std.testing.expectEqual(@as(usize, 156), summary.sizes.Y);
    try std.testing.expectEqual(@as(usize, 1), summary.sizes.C);
    try std.testing.expectEqual(@as(usize, 1), summary.logical_frame_count);

    const frame0 = try nd2.readFrame(0);
    defer allocator.free(frame0);
    try std.testing.expectEqual(@as(usize, 164 * 156), frame0.len);

    const frame2d = try nd2.readFrame2d(0, 0, 0, 0);
    defer allocator.free(frame2d);
    try std.testing.expectEqualSlices(u16, frame0, frame2d);

    try std.testing.expectError(error.OutOfRange, nd2.readFrame(summary.logical_frame_count + 1));
    try std.testing.expectError(error.OutOfRange, nd2.readFrame2d(summary.sizes.P, 0, 0, 0));
    try std.testing.expectError(error.OutOfRange, nd2.readFrame2d(0, summary.sizes.T, 0, 0));
    try std.testing.expectError(error.OutOfRange, nd2.readFrame2d(0, 0, summary.sizes.C, 0));
    try std.testing.expectError(error.OutOfRange, nd2.readFrame2d(0, 0, 0, summary.sizes.Z));
}
