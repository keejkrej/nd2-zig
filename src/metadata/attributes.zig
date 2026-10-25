const std = @import("std");
const Nd2Error = @import("../error.zig").Nd2Error;
const clx_mod = @import("../parse/clx_lite.zig");
const ClxObject = clx_mod.ClxObject;
const ClxValue = clx_mod.ClxValue;
const types = @import("../types/mod.zig");
const Attributes = types.Attributes;
const CompressionType = types.CompressionType;
const PixelDataType = types.PixelDataType;

fn getOptU32(obj: *const ClxObject, key: []const u8) ?u32 {
    if (obj.get(key)) |v| {
        if (v.asU64()) |u| return @intCast(u);
        if (v.asI64()) |i| return @intCast(i);
    }
    var buf1: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf1, "{s}_u32", .{key})) |k1| {
        if (obj.get(k1)) |v| {
            if (v.asU64()) |u| return @intCast(u);
            if (v.asI64()) |i| return @intCast(i);
        }
    } else |_| {}
    var buf2: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buf2, "{s}_i32", .{key})) |k2| {
        if (obj.get(k2)) |v| {
            if (v.asU64()) |u| return @intCast(u);
            if (v.asI64()) |i| return @intCast(i);
        }
    } else |_| {}
    return null;
}

fn getU32(obj: *const ClxObject, key: []const u8) Nd2Error!u32 {
    return getOptU32(obj, key) orelse error.MetadataParse;
}

fn getOptF64(obj: *const ClxObject, key: []const u8) ?f64 {
    if (obj.get(key)) |v| return v.asF64();
    return null;
}

pub fn parseAttributes(clx: *const ClxValue) Nd2Error!Attributes {
    const root_obj = clx.asObject() orelse return error.MetadataParse;
    const obj: *const ClxObject = if (root_obj.getPtr("SLxImageAttributes")) |inner|
        inner.asObject() orelse root_obj
    else
        root_obj;

    const pixel_data_type: PixelDataType = if (obj.get("uiCompBPC")) |v|
        if (v.asU64()) |u| (if (u == 3) .float else .unsigned) else .unsigned
    else
        .unsigned;

    const compression_type: ?CompressionType = if (obj.get("eCompression")) |v|
        if (v.asStr()) |s| blk: {
            if (std.mem.eql(u8, s, "lossless")) break :blk .lossless;
            if (std.mem.eql(u8, s, "lossy")) break :blk .lossy;
            break :blk .none;
        } else null
    else
        null;

    return .{
        .bits_per_component_in_memory = try getU32(obj, "uiBpcInMemory"),
        .bits_per_component_significant = try getU32(obj, "uiBpcSignificant"),
        .component_count = try getU32(obj, "uiComp"),
        .height_px = try getU32(obj, "uiHeight"),
        .pixel_data_type = pixel_data_type,
        .sequence_count = try getU32(obj, "uiSequenceCount"),
        .width_bytes = getOptU32(obj, "uiWidthBytes"),
        .width_px = getOptU32(obj, "uiWidth"),
        .compression_level = getOptF64(obj, "dCompressionParam"),
        .compression_type = compression_type,
        .tile_height_px = getOptU32(obj, "uiTileHeight"),
        .tile_width_px = getOptU32(obj, "uiTileWidth"),
        .channel_count = getOptU32(obj, "uiChannelCount"),
    };
}
