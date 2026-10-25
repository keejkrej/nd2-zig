const std = @import("std");
const ChunkHeader = @import("chunk/header.zig").ChunkHeader;
const chunk_map_mod = @import("chunk/map.zig");
const ChunkMap = chunk_map_mod.ChunkMap;
const readChunk = chunk_map_mod.readChunk;
const readChunkmap = chunk_map_mod.readChunkmap;
const constants = @import("constants.zig");
const JP2_MAGIC = constants.JP2_MAGIC;
const ND2_CHUNK_MAGIC = constants.ND2_CHUNK_MAGIC;
const ND2_FILE_SIGNATURE = constants.ND2_FILE_SIGNATURE;
const Nd2Error = @import("error.zig").Nd2Error;
const Source = @import("io.zig").Source;
const parseAttributes = @import("metadata/attributes.zig").parseAttributes;
const parseExperiment = @import("metadata/experiment.zig").parseExperiment;
const clx_mod = @import("parse/clx_lite.zig");
const ClxLiteParser = clx_mod.ClxLiteParser;
const decompressZlib = clx_mod.decompressZlib;
const types = @import("types/mod.zig");
const Attributes = types.Attributes;
const CompressionType = types.CompressionType;
const DatasetSummary = types.DatasetSummary;
const DimensionSizes = types.DimensionSizes;
const ExpLoop = types.ExpLoop;
const SummaryChannel = types.SummaryChannel;

const AXIS_T = "T";
const AXIS_P = "P";
const AXIS_C = "C";
const AXIS_Z = "Z";
const AXIS_Y = "Y";
const AXIS_X = "X";

pub const Version = struct { major: u32, minor: u32 };

/// Main reader for Nikon ND2 microscopy files.
pub const Nd2File = struct {
    allocator: std.mem.Allocator,
    path_owned: ?[]u8,
    source: Source,
    ver: Version,
    chunkmap: ChunkMap,
    cached_attributes: ?Attributes,
    cached_experiment: ?[]ExpLoop,

    /// Open an ND2 file from an in-memory byte slice.
    pub fn openMemory(allocator: std.mem.Allocator, data: []const u8) Nd2Error!Nd2File {
        return openInternal(allocator, null, .{ .memory = data });
    }

    /// Open an ND2 file from a `Source`.
    pub fn openSource(allocator: std.mem.Allocator, source: Source) Nd2Error!Nd2File {
        return openInternal(allocator, null, source);
    }

    /// Open an ND2 file for reading from a local filesystem path.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) Nd2Error!Nd2File {
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return error.IoError;
        var src: Source = .{ .file = .{ .file = file, .io = io, .owned = true } };
        errdefer src.close();

        const duped_path = allocator.dupe(u8, file_path) catch return error.OutOfMemory;
        errdefer allocator.free(duped_path);

        return openInternal(allocator, duped_path, src);
    }

    fn openInternal(allocator: std.mem.Allocator, path_owned: ?[]u8, source: Source) Nd2Error!Nd2File {
        const ver = try readVersion(source);
        if (ver.major < 2 or ver.major > 3) {
            return error.UnsupportedVersion;
        }
        const chunkmap = try readChunkmap(allocator, source);
        return .{
            .allocator = allocator,
            .path_owned = path_owned,
            .source = source,
            .ver = ver,
            .chunkmap = chunkmap,
            .cached_attributes = null,
            .cached_experiment = null,
        };
    }

    pub fn deinit(self: *Nd2File) void {
        if (self.path_owned) |p| self.allocator.free(p);
        self.source.close();
        self.chunkmap.deinit(self.allocator);
        if (self.cached_experiment) |exp| {
            for (exp) |*l| l.deinit(self.allocator);
            self.allocator.free(exp);
        }
    }

    pub fn path(self: *const Nd2File) ?[]const u8 {
        return self.path_owned;
    }

    pub fn version(self: *const Nd2File) Version {
        return self.ver;
    }

    pub fn attributes(self: *Nd2File) Nd2Error!Attributes {
        if (self.cached_attributes == null) {
            const chunk_name: []const u8 = if (self.ver.major >= 3)
                "ImageAttributesLV!"
            else
                "ImageAttributes!";
            const data = try readChunk(self.allocator, self.source, &self.chunkmap, chunk_name);
            defer self.allocator.free(data);

            const parser = ClxLiteParser.init(false);
            var clx = try parser.parse(self.allocator, data);
            defer clx.deinit(self.allocator);

            self.cached_attributes = try parseAttributes(&clx);
        }
        return self.cached_attributes.?;
    }

    pub fn experiment(self: *Nd2File) Nd2Error![]const ExpLoop {
        if (self.cached_experiment == null) {
            const chunk_name: []const u8 = if (self.ver.major >= 3)
                "ImageMetadataLV!"
            else
                "ImageMetadata!";

            if (!self.chunkmap.contains(chunk_name)) {
                self.cached_experiment = self.allocator.alloc(ExpLoop, 0) catch return error.OutOfMemory;
            } else {
                const data = try readChunk(self.allocator, self.source, &self.chunkmap, chunk_name);
                defer self.allocator.free(data);

                const parser = ClxLiteParser.init(false);
                var clx = try parser.parse(self.allocator, data);
                defer clx.deinit(self.allocator);

                const to_parse: *const clx_mod.ClxValue = if (self.ver.major >= 3) blk: {
                    if (clx.asObject()) |o| {
                        if (o.getPtr("SLxExperiment")) |inner| {
                            if (inner.asObject() != null) break :blk inner;
                        }
                    }
                    break :blk &clx;
                } else &clx;

                var exp = parseExperiment(self.allocator, to_parse) catch
                    (self.allocator.alloc(ExpLoop, 0) catch return error.OutOfMemory);
                if (exp.len == 0 and self.ver.major >= 3 and to_parse != &clx) {
                    self.allocator.free(exp);
                    exp = parseExperiment(self.allocator, &clx) catch
                        (self.allocator.alloc(ExpLoop, 0) catch return error.OutOfMemory);
                }
                self.cached_experiment = exp;
            }
        }
        return self.cached_experiment.?;
    }

    pub fn sizes(self: *Nd2File) Nd2Error!DimensionSizes {
        const attrs = try self.attributes();
        const exp = try self.experiment();

        const n_chan = attrs.channel_count orelse attrs.component_count;
        const height: usize = @intCast(attrs.height_px);
        const width_u32 = attrs.width_px orelse blk: {
            if (attrs.width_bytes) |wb| {
                const bpp = attrs.bits_per_component_in_memory / 8;
                const denom = bpp * attrs.component_count;
                if (denom > 0) break :blk wb / denom;
            }
            break :blk 0;
        };
        const width: usize = @intCast(width_u32);

        var dim_sizes: DimensionSizes = .{
            .P = 1,
            .T = 1,
            .C = @intCast(n_chan),
            .Z = 1,
            .Y = height,
            .X = width,
        };

        if (exp.len == 0) {
            const total: usize = @intCast(attrs.sequence_count);
            const n_z: usize = 1;
            const n_pos: usize = 1;
            const n_chan_usize: usize = @intCast(n_chan);
            const denom = @max(n_pos * n_chan_usize * n_z, 1);
            dim_sizes.P = n_pos;
            dim_sizes.T = total / denom;
            dim_sizes.C = n_chan_usize;
            dim_sizes.Z = n_z;
        } else {
            for (exp) |loop_item| {
                switch (loop_item) {
                    .TimeLoop => |t| dim_sizes.T = @intCast(t.count),
                    .XYPosLoop => |xy| dim_sizes.P = @intCast(xy.count),
                    .ZStackLoop => |z| dim_sizes.Z = @intCast(z.count),
                    .NETimeLoop => |n| dim_sizes.T = @intCast(n.count),
                    .CustomLoop => {},
                }
            }
        }

        return dim_sizes;
    }

    const CoordAxisOrder = struct {
        axes: [6][]const u8 = undefined,
        shapes: [6]usize = undefined,
        len: usize = 0,

        fn contains(self: *const CoordAxisOrder, axis: []const u8) bool {
            for (self.axes[0..self.len]) |a| {
                if (std.mem.eql(u8, a, axis)) return true;
            }
            return false;
        }

        fn push(self: *CoordAxisOrder, axis: []const u8, shape: usize) void {
            self.axes[self.len] = axis;
            self.shapes[self.len] = shape;
            self.len += 1;
        }

        fn product(self: *const CoordAxisOrder) usize {
            var prod: usize = 1;
            for (self.shapes[0..self.len]) |s| prod *= s;
            return prod;
        }
    };

    fn coordAxisOrder(self: *Nd2File) Nd2Error!CoordAxisOrder {
        const attrs = try self.attributes();
        const exp = try self.experiment();
        const n_chan: usize = @intCast(attrs.channel_count orelse attrs.component_count);
        const seq_count: usize = @intCast(attrs.sequence_count);

        var order: CoordAxisOrder = .{};

        if (exp.len == 0) {
            const n_z: usize = 1;
            const n_pos: usize = 1;
            const n_time = seq_count / @max(n_pos * n_chan * n_z, 1);
            order.push(AXIS_P, n_pos);
            order.push(AXIS_T, n_time);
            order.push(AXIS_C, n_chan);
            order.push(AXIS_Z, n_z);
        } else {
            for (exp) |loop_item| {
                switch (loop_item) {
                    .TimeLoop => |t| order.push(AXIS_T, @intCast(t.count)),
                    .NETimeLoop => |n| order.push(AXIS_T, @intCast(n.count)),
                    .XYPosLoop => |xy| order.push(AXIS_P, @intCast(xy.count)),
                    .ZStackLoop => |z| order.push(AXIS_Z, @intCast(z.count)),
                    .CustomLoop => {},
                }
            }
            if (!order.contains(AXIS_P)) order.push(AXIS_P, 1);
            if (!order.contains(AXIS_T)) order.push(AXIS_T, 1);
            if (!order.contains(AXIS_Z)) order.push(AXIS_Z, 1);

            const exp_product = order.product();
            if (exp_product > 0 and exp_product * n_chan <= seq_count) {
                order.push(AXIS_C, n_chan);
            }
            if (!order.contains(AXIS_Z)) order.push(AXIS_Z, 1);
        }

        return order;
    }

    pub fn logicalFrameCount(self: *Nd2File) Nd2Error!usize {
        const order = try self.coordAxisOrder();
        return order.product();
    }

    pub fn summary(self: *Nd2File) Nd2Error!DatasetSummary {
        const dim_sizes = try self.sizes();
        const attrs = try self.attributes();
        const logical_frame_count = try self.logicalFrameCount();

        const prefix: []const u8 = switch (attrs.pixel_data_type) {
            .float => "Float",
            .unsigned => "Unsigned",
        };
        const pixel_type = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, attrs.bits_per_component_in_memory }) catch return error.OutOfMemory;
        errdefer self.allocator.free(pixel_type);

        const channel_count = dim_sizes.C;
        const channels = self.allocator.alloc(SummaryChannel, channel_count) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (channels[0..initialized]) |*ch| ch.deinit(self.allocator);
            self.allocator.free(channels);
        }

        for (0..channel_count) |index| {
            const pt_copy = self.allocator.dupe(u8, pixel_type) catch return error.OutOfMemory;
            channels[index] = .{
                .index = index,
                .name = null,
                .color = null,
                .pixel_type = pt_copy,
            };
            initialized += 1;
        }

        return .{
            .version_major = self.ver.major,
            .version_minor = self.ver.minor,
            .sizes = dim_sizes,
            .logical_frame_count = logical_frame_count,
            .channels = channels,
            .pixel_type = pixel_type,
            .scaling = null,
        };
    }

    /// Read one logical frame by sequence index (0..logical_frame_count).
    /// Returns decoded pixels as planar (Channel, Height, Width) in row-major order.
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn readFrame(self: *Nd2File, index: usize) Nd2Error![]u16 {
        const attrs = try self.attributes();
        var chunk_name_buf: [64]u8 = undefined;
        const chunk_key = std.fmt.bufPrint(&chunk_name_buf, "ImageDataSeq|{d}!", .{index}) catch return error.InvalidArgument;

        const h: usize = @intCast(attrs.height_px);
        const w: usize = @intCast(attrs.width_px orelse 0);
        const n_c: usize = if (attrs.channel_count) |ch|
            (if (ch > 0) @intCast(ch) else @intCast(attrs.component_count))
        else
            @intCast(attrs.component_count);
        const n_comp: usize = if (attrs.channel_count) |ch|
            (if (ch > 0) @intCast(attrs.component_count / ch) else 1)
        else
            1;

        const bytes_per_pixel: usize = @intCast(attrs.bits_per_component_in_memory / 8);
        if (bytes_per_pixel == 0) return error.InvalidFormat;

        const n_c_n_comp = std.math.mul(usize, n_c, n_comp) catch return error.InvalidFormat;
        const w_elems = std.math.mul(usize, w, n_c_n_comp) catch return error.InvalidFormat;
        const default_row_bytes = std.math.mul(usize, w_elems, bytes_per_pixel) catch return error.InvalidFormat;
        const raw_row_bytes: usize = if (attrs.width_bytes) |wb| @intCast(wb) else default_row_bytes;

        if (raw_row_bytes == 0 or raw_row_bytes % bytes_per_pixel != 0) return error.InvalidFormat;
        const raw_row_pixels = raw_row_bytes / bytes_per_pixel;
        if (raw_row_pixels < w_elems) return error.InvalidFormat;

        const frame_area = std.math.mul(usize, h, w) catch return error.InvalidFormat;
        const frame_size = std.math.mul(usize, frame_area, n_c_n_comp) catch return error.InvalidFormat;
        const expected_raw = std.math.mul(usize, h, raw_row_bytes) catch return error.InvalidFormat;

        const pixel_bytes: []u8 = if (attrs.compression_type != null and attrs.compression_type.? == .lossless) blk: {
            const data = readChunk(self.allocator, self.source, &self.chunkmap, chunk_key) catch |err| switch (err) {
                error.ChunkNotFound => return error.OutOfRange,
                else => return err,
            };
            defer self.allocator.free(data);

            if (data.len < 8) return error.InvalidFormat;
            break :blk try decompressZlib(self.allocator, data[8..]);
        } else blk: {
            break :blk self.readUncompressedFrameBytes(chunk_key, expected_raw) catch |err| switch (err) {
                error.ChunkNotFound => return error.OutOfRange,
                else => return err,
            };
        };
        defer self.allocator.free(pixel_bytes);

        if (pixel_bytes.len % 2 != 0) return error.InvalidFormat;
        if (pixel_bytes.len / 2 < frame_size) return error.InvalidFormat;

        const out = self.allocator.alloc(u16, frame_size) catch return error.OutOfMemory;
        errdefer self.allocator.free(out);

        for (0..h) |y| {
            const y_offset = y * raw_row_pixels;
            const y_plane_offset = y * w;
            for (0..w) |x| {
                const x_offset = x * n_c_n_comp;
                for (0..n_c) |c| {
                    const c_offset = c * n_comp;
                    for (0..n_comp) |comp| {
                        const src_idx = y_offset + x_offset + c_offset + comp;
                        const dst_x = y_plane_offset + x;
                        const c_plane = c_offset + comp;
                        const dst_idx = c_plane * frame_area + dst_x;
                        out[dst_idx] = std.mem.readInt(u16, pixel_bytes[src_idx * 2 ..][0..2], .little);
                    }
                }
            }
        }

        return out;
    }

    fn readUncompressedFrameBytes(self: *Nd2File, chunk_key: []const u8, expected_raw: usize) Nd2Error![]u8 {
        const file_size = try self.source.size();
        const loc = self.chunkmap.get(chunk_key) orelse return error.ChunkNotFound;

        const pixel_offset: u64 = if (try self.readImageChunkPayloadOffset(loc.offset)) |payload_offset|
            std.math.add(u64, payload_offset, 8) catch return error.InvalidFormat
        else
            std.math.add(u64, loc.offset, 4096) catch return error.InvalidFormat;

        const pixel_end = std.math.add(u64, pixel_offset, @intCast(expected_raw)) catch return error.InvalidFormat;
        if (pixel_end > file_size) return error.InvalidFormat;

        return self.source.readExactAt(self.allocator, pixel_offset, expected_raw) catch return error.InvalidFormat;
    }

    fn readImageChunkPayloadOffset(self: *Nd2File, offset: u64) Nd2Error!?u64 {
        const header = ChunkHeader.readAt(self.source, offset) catch return null;
        if (header.magic != ND2_CHUNK_MAGIC) return null;

        const after_hdr = std.math.add(u64, offset, 16) catch return error.InvalidFormat;
        return std.math.add(u64, after_hdr, @as(u64, header.name_length)) catch return error.InvalidFormat;
    }

    fn seqIndexFromCoords(self: *Nd2File, p: usize, t: usize, c: usize, z: usize) Nd2Error!usize {
        const order = try self.coordAxisOrder();
        var seq: usize = 0;
        var stride: usize = 1;

        var i = order.len;
        while (i > 0) {
            i -= 1;
            const ax = order.axes[i];
            const shape = order.shapes[i];
            if (shape == 0) return error.InvalidFormat;

            const coord: usize = if (std.mem.eql(u8, ax, AXIS_P))
                p
            else if (std.mem.eql(u8, ax, AXIS_T))
                t
            else if (std.mem.eql(u8, ax, AXIS_C))
                c
            else if (std.mem.eql(u8, ax, AXIS_Z))
                z
            else
                0;

            if (coord >= shape) return error.OutOfRange;

            const next = std.math.mul(usize, coord, stride) catch return error.Overflow;
            seq = std.math.add(usize, seq, next) catch return error.Overflow;
            stride = std.math.mul(usize, stride, shape) catch return error.Overflow;
        }
        return seq;
    }

    /// Read a 2D plane at the specified coordinates: Position (`p`), Time (`t`), Channel (`c`), and Z-slice (`z`).
    /// Returns decoded pixels as `[]u16` in row-major order (Height x Width).
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn readFrame2d(self: *Nd2File, p: usize, t: usize, c: usize, z: usize) Nd2Error![]u16 {
        const dim_sizes = try self.sizes();
        if (p >= dim_sizes.P) return error.OutOfRange;
        if (t >= dim_sizes.T) return error.OutOfRange;
        if (c >= dim_sizes.C) return error.OutOfRange;
        if (z >= dim_sizes.Z) return error.OutOfRange;

        const seq_index = try self.seqIndexFromCoords(p, t, c, z);
        const frame = try self.readFrame(seq_index);
        defer self.allocator.free(frame);

        const len = std.math.mul(usize, dim_sizes.Y, dim_sizes.X) catch return error.InvalidFormat;
        const start = std.math.mul(usize, c, len) catch return error.InvalidFormat;
        const end = std.math.mul(usize, c + 1, len) catch return error.InvalidFormat;
        if (end > frame.len) return error.InvalidFormat;

        return self.allocator.dupe(u16, frame[start..end]) catch return error.OutOfMemory;
    }

    fn readVersion(source: Source) Nd2Error!Version {
        var header: [112]u8 = undefined;
        source.readExactAtInto(0, &header) catch return error.InvalidFormat;

        const magic = std.mem.readInt(u32, header[0..4], .little);
        if (magic == JP2_MAGIC) {
            return .{ .major = 1, .minor = 0 };
        }
        if (magic != ND2_CHUNK_MAGIC) {
            return error.InvalidMagic;
        }

        const name_length = std.mem.readInt(u32, header[4..8], .little);
        const data_length = std.mem.readInt(u64, header[8..16], .little);
        if (name_length != 32 or data_length != 64) {
            return error.InvalidFormat;
        }

        const name = header[16..48];
        if (!std.mem.eql(u8, name, ND2_FILE_SIGNATURE)) {
            return error.InvalidFormat;
        }

        const data = header[48..112];
        const major: u32 = if (std.ascii.isDigit(data[3])) @intCast(data[3] - '0') else 0;
        const minor: u32 = if (std.ascii.isDigit(data[5])) @intCast(data[5] - '0') else 0;
        return .{ .major = major, .minor = minor };
    }
};
