const std = @import("std");
const ChunkHeader = @import("header.zig").ChunkHeader;
const constants = @import("../constants.zig");
const ND2_CHUNKMAP_SIGNATURE = constants.ND2_CHUNKMAP_SIGNATURE;
const ND2_FILEMAP_SIGNATURE = constants.ND2_FILEMAP_SIGNATURE;
const Nd2Error = @import("../error.zig").Nd2Error;
const Source = @import("../io.zig").Source;

pub const ChunkLocation = struct {
    offset: u64,
    size: u64,
};

pub const ChunkMap = struct {
    entries: std.StringHashMapUnmanaged(ChunkLocation) = .empty,

    pub fn deinit(self: *ChunkMap, allocator: std.mem.Allocator) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        self.entries.deinit(allocator);
    }

    pub fn get(self: *const ChunkMap, name: []const u8) ?ChunkLocation {
        return self.entries.get(name);
    }

    pub fn contains(self: *const ChunkMap, name: []const u8) bool {
        return self.entries.contains(name);
    }

    pub fn putOwnedKey(self: *ChunkMap, allocator: std.mem.Allocator, name: []const u8, loc: ChunkLocation) Nd2Error!void {
        const gop = self.entries.getOrPut(allocator, name) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, name) catch return error.OutOfMemory;
        }
        gop.value_ptr.* = loc;
    }
};

fn readOffsetSize(chunkmap_data: []const u8, value_pos: usize) ?ChunkLocation {
    if (value_pos + 16 > chunkmap_data.len) return null;
    const offset = std.mem.readInt(u64, chunkmap_data[value_pos..][0..8], .little);
    const size = std.mem.readInt(u64, chunkmap_data[value_pos + 8 ..][0..8], .little);
    return .{ .offset = offset, .size = size };
}

pub fn readChunkmap(allocator: std.mem.Allocator, source: Source) Nd2Error!ChunkMap {
    const file_size = try source.size();
    if (file_size < 40) return error.InvalidFormat;

    var tail: [40]u8 = undefined;
    source.readExactAtInto(file_size - 40, &tail) catch return error.InvalidFormat;

    if (!std.mem.eql(u8, tail[0..32], ND2_CHUNKMAP_SIGNATURE)) {
        return error.InvalidFormat;
    }

    const chunkmap_offset = std.mem.readInt(u64, tail[32..40], .little);
    const header = try ChunkHeader.readAt(source, chunkmap_offset);
    try header.validateMagic();

    if (header.name_length < ND2_FILEMAP_SIGNATURE.len) {
        return error.InvalidFormat;
    }

    const name = try source.readExactAt(allocator, chunkmap_offset + 16, @intCast(header.name_length));
    defer allocator.free(name);

    const is_expected_name = std.mem.startsWith(u8, name, ND2_FILEMAP_SIGNATURE) and blk: {
        for (name[ND2_FILEMAP_SIGNATURE.len..]) |b| {
            if (b != 0) break :blk false;
        }
        break :blk true;
    };
    if (!is_expected_name) return error.ChunkmapParse;

    const chunkmap_len = std.math.cast(usize, header.data_length) orelse return error.ChunkmapParse;
    const data_offset = chunkmap_offset + 16 + @as(u64, header.name_length);
    const chunkmap_data = source.readExactAt(allocator, data_offset, chunkmap_len) catch return error.InvalidFormat;
    defer allocator.free(chunkmap_data);

    var chunkmap: ChunkMap = .{};
    errdefer chunkmap.deinit(allocator);

    var pos: usize = 0;
    while (pos < chunkmap_data.len) {
        const start_pos = pos;
        var found_bang = false;
        while (pos < chunkmap_data.len) {
            const byte = chunkmap_data[pos];
            pos += 1;
            const current_name = chunkmap_data[start_pos..pos];
            if (byte == '!') {
                found_bang = true;
                break;
            }
            if (current_name.len >= 32 and
                std.mem.eql(u8, current_name[current_name.len - 32 ..], ND2_CHUNKMAP_SIGNATURE))
            {
                return chunkmap;
            }
        }

        if (!found_bang) break;
        const chunk_name = chunkmap_data[start_pos..pos];
        if (std.mem.eql(u8, chunk_name, ND2_CHUNKMAP_SIGNATURE)) break;

        var value_pos = pos;
        var found_entry = false;
        var best_score: i32 = -1;
        var best_loc: ChunkLocation = .{ .offset = 0, .size = 0 };

        for (0..2) |candidate| {
            const loc = readOffsetSize(chunkmap_data, pos + candidate) orelse continue;
            var score: i32 = 0;
            if (loc.offset <= file_size) {
                score = 1;
                if (std.math.add(u64, loc.offset, loc.size)) |end| {
                    if (end <= file_size) {
                        score = 2;
                    }
                } else |_| {}
            }

            if (score > best_score) {
                best_score = score;
                best_loc = loc;
                value_pos = pos + candidate;
                found_entry = true;
                if (score == 2) break;
            }
        }

        if (!found_entry) return error.ChunkmapParse;
        try chunkmap.putOwnedKey(allocator, chunk_name, best_loc);
        pos = value_pos + 16;
    }

    return chunkmap;
}

pub fn readChunk(
    allocator: std.mem.Allocator,
    source: Source,
    chunkmap: *const ChunkMap,
    name: []const u8,
) Nd2Error![]u8 {
    const file_size = try source.size();
    const loc = chunkmap.get(name) orelse return error.ChunkNotFound;

    const header = try ChunkHeader.readAt(source, loc.offset);
    try header.validateMagic();

    const size = header.data_length;
    const after_hdr = std.math.add(u64, loc.offset, 16) catch return error.InvalidFormat;
    const data_offset = std.math.add(u64, after_hdr, @as(u64, header.name_length)) catch return error.InvalidFormat;
    const chunk_end = std.math.add(u64, data_offset, size) catch return error.InvalidFormat;

    if (chunk_end > file_size) return error.InvalidFormat;

    const size_usize = std.math.cast(usize, size) orelse return error.InvalidFormat;
    return source.readExactAt(allocator, data_offset, size_usize) catch return error.InvalidFormat;
}
