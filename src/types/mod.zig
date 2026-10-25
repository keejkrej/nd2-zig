const std = @import("std");

pub const PixelDataType = enum {
    unsigned,
    float,
};

pub const CompressionType = enum {
    lossless,
    lossy,
    none,
};

pub const Attributes = struct {
    bits_per_component_in_memory: u32,
    bits_per_component_significant: u32,
    component_count: u32,
    height_px: u32,
    pixel_data_type: PixelDataType,
    sequence_count: u32,
    width_bytes: ?u32 = null,
    width_px: ?u32 = null,
    compression_level: ?f64 = null,
    compression_type: ?CompressionType = null,
    tile_height_px: ?u32 = null,
    tile_width_px: ?u32 = null,
    channel_count: ?u32 = null,
};

pub const TimeLoopParams = struct {
    start_ms: f64,
    period_ms: f64,
    duration_ms: f64,
    period_diff: ?PeriodDiff = null,
};

pub const PeriodDiff = struct {
    avg: f64 = 0.0,
    max: f64 = 0.0,
    min: f64 = 0.0,
};

pub const TimeLoop = struct {
    count: u32,
    nesting_level: u32,
    parameters: TimeLoopParams,
};

pub const ZStackLoopParams = struct {
    home_index: i32,
    step_um: f64,
    bottom_to_top: bool,
    device_name: ?[]u8 = null,

    pub fn deinit(self: *ZStackLoopParams, allocator: std.mem.Allocator) void {
        if (self.device_name) |d| allocator.free(d);
    }
};

pub const ZStackLoop = struct {
    count: u32,
    nesting_level: u32,
    parameters: ZStackLoopParams,

    pub fn deinit(self: *ZStackLoop, allocator: std.mem.Allocator) void {
        self.parameters.deinit(allocator);
    }
};

pub const StagePosition = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const Position = struct {
    stage_position_um: StagePosition,
    pfs_offset: ?f64 = null,
    name: ?[]u8 = null,

    pub fn deinit(self: *Position, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
    }
};

pub const XYPosLoopParams = struct {
    is_setting_z: bool,
    points: []Position,

    pub fn deinit(self: *XYPosLoopParams, allocator: std.mem.Allocator) void {
        for (self.points) |*p| p.deinit(allocator);
        allocator.free(self.points);
    }
};

pub const XYPosLoop = struct {
    count: u32,
    nesting_level: u32,
    parameters: XYPosLoopParams,

    pub fn deinit(self: *XYPosLoop, allocator: std.mem.Allocator) void {
        self.parameters.deinit(allocator);
    }
};

pub const Period = struct {
    count: u32,
    start_ms: f64,
    period_ms: f64,
    duration_ms: f64,
    period_diff: ?PeriodDiff = null,
};

pub const NETimeLoopParams = struct {
    periods: []Period,

    pub fn deinit(self: *NETimeLoopParams, allocator: std.mem.Allocator) void {
        allocator.free(self.periods);
    }
};

pub const NETimeLoop = struct {
    count: u32,
    nesting_level: u32,
    parameters: NETimeLoopParams,

    pub fn deinit(self: *NETimeLoop, allocator: std.mem.Allocator) void {
        self.parameters.deinit(allocator);
    }
};

pub const CustomLoop = struct {
    count: u32,
    nesting_level: u32,
};

pub const ExpLoop = union(enum) {
    TimeLoop: TimeLoop,
    ZStackLoop: ZStackLoop,
    XYPosLoop: XYPosLoop,
    NETimeLoop: NETimeLoop,
    CustomLoop: CustomLoop,

    pub fn count(self: ExpLoop) u32 {
        return switch (self) {
            .TimeLoop => |t| t.count,
            .ZStackLoop => |z| z.count,
            .XYPosLoop => |xy| xy.count,
            .NETimeLoop => |n| n.count,
            .CustomLoop => |c| c.count,
        };
    }

    pub fn deinit(self: *ExpLoop, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .TimeLoop, .CustomLoop => {},
            .ZStackLoop => |*z| z.deinit(allocator),
            .XYPosLoop => |*xy| xy.deinit(allocator),
            .NETimeLoop => |*n| n.deinit(allocator),
        }
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn fromAbgrU32(val: u32) Color {
        return .{
            .r = @intCast(val & 0xFF),
            .g = @intCast((val >> 8) & 0xFF),
            .b = @intCast((val >> 16) & 0xFF),
            .a = @intCast((val >> 24) & 0xFF),
        };
    }
};

pub const TextInfo = struct {
    image_id: ?[]u8 = null,
    info_type: ?[]u8 = null,
    group: ?[]u8 = null,
    sample_id: ?[]u8 = null,
    author: ?[]u8 = null,
    description: ?[]u8 = null,
    capturing: ?[]u8 = null,
    sampling: ?[]u8 = null,
    location: ?[]u8 = null,
    date: ?[]u8 = null,
    conclusion: ?[]u8 = null,
    info1: ?[]u8 = null,
    info2: ?[]u8 = null,
    optics: ?[]u8 = null,
    app_version: ?[]u8 = null,

    pub fn deinit(self: *TextInfo, allocator: std.mem.Allocator) void {
        if (self.image_id) |v| allocator.free(v);
        if (self.info_type) |v| allocator.free(v);
        if (self.group) |v| allocator.free(v);
        if (self.sample_id) |v| allocator.free(v);
        if (self.author) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        if (self.capturing) |v| allocator.free(v);
        if (self.sampling) |v| allocator.free(v);
        if (self.location) |v| allocator.free(v);
        if (self.date) |v| allocator.free(v);
        if (self.conclusion) |v| allocator.free(v);
        if (self.info1) |v| allocator.free(v);
        if (self.info2) |v| allocator.free(v);
        if (self.optics) |v| allocator.free(v);
        if (self.app_version) |v| allocator.free(v);
    }
};

pub const SummaryChannel = struct {
    index: usize,
    name: ?[]u8 = null,
    color: ?[]u8 = null,
    pixel_type: ?[]u8 = null,

    pub fn deinit(self: *SummaryChannel, allocator: std.mem.Allocator) void {
        if (self.name) |v| allocator.free(v);
        if (self.color) |v| allocator.free(v);
        if (self.pixel_type) |v| allocator.free(v);
    }
};

pub const SummaryScaling = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    z: ?f64 = null,
    unit: ?[]u8 = null,

    pub fn deinit(self: *SummaryScaling, allocator: std.mem.Allocator) void {
        if (self.unit) |v| allocator.free(v);
    }
};

pub const DimensionSizes = struct {
    P: usize = 1,
    T: usize = 1,
    C: usize = 1,
    Z: usize = 1,
    Y: usize = 0,
    X: usize = 0,

    pub fn get(self: DimensionSizes, axis: []const u8) ?usize {
        if (std.mem.eql(u8, axis, "P")) return self.P;
        if (std.mem.eql(u8, axis, "T")) return self.T;
        if (std.mem.eql(u8, axis, "C")) return self.C;
        if (std.mem.eql(u8, axis, "Z")) return self.Z;
        if (std.mem.eql(u8, axis, "Y")) return self.Y;
        if (std.mem.eql(u8, axis, "X")) return self.X;
        return null;
    }

    pub fn set(self: *DimensionSizes, axis: []const u8, val: usize) void {
        if (std.mem.eql(u8, axis, "P")) self.P = val;
        if (std.mem.eql(u8, axis, "T")) self.T = val;
        if (std.mem.eql(u8, axis, "C")) self.C = val;
        if (std.mem.eql(u8, axis, "Z")) self.Z = val;
        if (std.mem.eql(u8, axis, "Y")) self.Y = val;
        if (std.mem.eql(u8, axis, "X")) self.X = val;
    }
};

pub const DatasetSummary = struct {
    version_major: u32,
    version_minor: u32,
    sizes: DimensionSizes,
    logical_frame_count: usize,
    channels: []SummaryChannel,
    pixel_type: ?[]u8 = null,
    scaling: ?SummaryScaling = null,

    pub fn deinit(self: *DatasetSummary, allocator: std.mem.Allocator) void {
        for (self.channels) |*ch| ch.deinit(allocator);
        allocator.free(self.channels);
        if (self.pixel_type) |pt| allocator.free(pt);
        if (self.scaling) |*sc| sc.deinit(allocator);
    }
};
