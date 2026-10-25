const std = @import("std");
const ND2_CHUNK_MAGIC = @import("../constants.zig").ND2_CHUNK_MAGIC;
const Nd2Error = @import("../error.zig").Nd2Error;
const Source = @import("../io.zig").Source;

/// Chunk header structure (16 bytes)
pub const ChunkHeader = struct {
    magic: u32,
    name_length: u32,
    data_length: u64,

    pub fn readAt(source: Source, offset: u64) Nd2Error!ChunkHeader {
        var bytes: [16]u8 = undefined;
        source.readExactAtInto(offset, &bytes) catch return error.InvalidFormat;
        return .{
            .magic = std.mem.readInt(u32, bytes[0..4], .little),
            .name_length = std.mem.readInt(u32, bytes[4..8], .little),
            .data_length = std.mem.readInt(u64, bytes[8..16], .little),
        };
    }

    pub fn validateMagic(self: ChunkHeader) Nd2Error!void {
        if (self.magic != ND2_CHUNK_MAGIC) {
            return error.InvalidMagic;
        }
    }
};
