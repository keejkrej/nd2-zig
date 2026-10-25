const std = @import("std");
const Nd2Error = @import("../error.zig").Nd2Error;
const clx_mod = @import("../parse/clx_lite.zig");
const ClxObject = clx_mod.ClxObject;
const ClxValue = clx_mod.ClxValue;
const TextInfo = @import("../types/mod.zig").TextInfo;

fn getStrDupe(allocator: std.mem.Allocator, obj: *const ClxObject, key: []const u8) Nd2Error!?[]u8 {
    if (obj.get(key)) |v| {
        if (v.asStr()) |s| {
            return allocator.dupe(u8, s) catch return error.OutOfMemory;
        }
    }
    return null;
}

pub fn parseTextInfo(allocator: std.mem.Allocator, clx: *const ClxValue) Nd2Error!TextInfo {
    const obj = clx.asObject() orelse return .{};
    var info: TextInfo = .{};
    errdefer info.deinit(allocator);

    info.image_id = try getStrDupe(allocator, obj, "ImageId");
    info.info_type = try getStrDupe(allocator, obj, "Type");
    info.group = try getStrDupe(allocator, obj, "Group");
    info.sample_id = try getStrDupe(allocator, obj, "SampleId");
    info.author = try getStrDupe(allocator, obj, "Author");
    info.description = try getStrDupe(allocator, obj, "Description");
    info.capturing = try getStrDupe(allocator, obj, "Capturing");
    info.sampling = try getStrDupe(allocator, obj, "Sampling");
    info.location = try getStrDupe(allocator, obj, "Location");
    info.date = try getStrDupe(allocator, obj, "Date");
    info.conclusion = try getStrDupe(allocator, obj, "Conclusion");
    info.info1 = try getStrDupe(allocator, obj, "Info1");
    info.info2 = try getStrDupe(allocator, obj, "Info2");
    info.optics = try getStrDupe(allocator, obj, "Optics");
    info.app_version = try getStrDupe(allocator, obj, "AppVersion");

    return info;
}
