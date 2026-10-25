const std = @import("std");
const clx_types = @import("../constants.zig").clx_types;
const Nd2Error = @import("../error.zig").Nd2Error;

pub const ClxObject = std.StringHashMapUnmanaged(ClxValue);

/// Parsed JSON-like value from CLX Lite format
pub const ClxValue = union(enum) {
    bool_val: bool,
    int_val: i64,
    uint_val: u64,
    float_val: f64,
    string_val: []u8,
    byte_array: []u8,
    object: ClxObject,
    array: []ClxValue,

    pub fn deinit(self: *ClxValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bool_val, .int_val, .uint_val, .float_val => {},
            .string_val => |s| allocator.free(s),
            .byte_array => |b| allocator.free(b),
            .object => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit(allocator);
            },
            .array => |arr| {
                for (arr) |*item| item.deinit(allocator);
                allocator.free(arr);
            },
        }
    }

    pub fn asObject(self: *const ClxValue) ?*const ClxObject {
        return switch (self.*) {
            .object => |*map| map,
            else => null,
        };
    }

    pub fn asStr(self: ClxValue) ?[]const u8 {
        return switch (self) {
            .string_val => |s| s,
            else => null,
        };
    }

    pub fn asI64(self: ClxValue) ?i64 {
        return switch (self) {
            .int_val => |i| i,
            else => null,
        };
    }

    pub fn asU64(self: ClxValue) ?u64 {
        return switch (self) {
            .uint_val => |u| u,
            else => null,
        };
    }

    pub fn asF64(self: ClxValue) ?f64 {
        return switch (self) {
            .float_val => |f| f,
            else => null,
        };
    }

    pub fn asBool(self: ClxValue) ?bool {
        return switch (self) {
            .bool_val => |b| b,
            else => null,
        };
    }
};

const SliceCursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn readU8(self: *SliceCursor) Nd2Error!u8 {
        if (self.pos >= self.data.len) return error.InvalidFormat;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readI32(self: *SliceCursor) Nd2Error!i32 {
        if (self.pos + 4 > self.data.len) return error.InvalidFormat;
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readU32(self: *SliceCursor) Nd2Error!u32 {
        if (self.pos + 4 > self.data.len) return error.InvalidFormat;
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI64(self: *SliceCursor) Nd2Error!i64 {
        if (self.pos + 8 > self.data.len) return error.InvalidFormat;
        const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readU64(self: *SliceCursor) Nd2Error!u64 {
        if (self.pos + 8 > self.data.len) return error.InvalidFormat;
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readF64(self: *SliceCursor) Nd2Error!f64 {
        const bits = try self.readU64();
        return @bitCast(bits);
    }

    fn readSlice(self: *SliceCursor, len: usize) Nd2Error![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.InvalidFormat;
        if (end > self.data.len) return error.InvalidFormat;
        const s = self.data[self.pos..end];
        self.pos = end;
        return s;
    }
};

/// Parser for CLX Lite binary TLV format
pub const ClxLiteParser = struct {
    strip_prefix: bool,

    pub fn init(strip_prefix: bool) ClxLiteParser {
        return .{ .strip_prefix = strip_prefix };
    }

    pub fn parse(self: ClxLiteParser, allocator: std.mem.Allocator, data: []const u8) Nd2Error!ClxValue {
        var cursor: SliceCursor = .{ .data = data };
        return self.parseWithCount(allocator, &cursor, 1);
    }

    fn parseWithCount(self: ClxLiteParser, allocator: std.mem.Allocator, cursor: *SliceCursor, count: usize) Nd2Error!ClxValue {
        var output: ClxObject = .empty;
        errdefer {
            var it = output.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            output.deinit(allocator);
        }

        for (0..count) |_| {
            const hdr = try self.readChunkHeader(allocator, cursor);
            var name_owned: ?[]u8 = hdr.name;
            defer if (name_owned) |n| allocator.free(n);

            if (hdr.data_type == -1) {
                break;
            }

            const dtype_u8: u8 = @bitCast(hdr.data_type);
            if (dtype_u8 == clx_types.COMPRESS) {
                // Free any items collected so far (rare in COMPRESS chunk)
                var it = output.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                output.deinit(allocator);

                if (cursor.pos + 10 > cursor.data.len) return error.InvalidFormat;
                cursor.pos += 10;
                const compressed = cursor.data[cursor.pos..];
                cursor.pos = cursor.data.len;
                const decompressed = try decompressZlib(allocator, compressed);
                defer allocator.free(decompressed);
                return self.parse(allocator, decompressed);
            }

            var value: ClxValue = switch (dtype_u8) {
                clx_types.BOOL => .{ .bool_val = (try cursor.readU8()) != 0 },
                clx_types.INT32 => .{ .int_val = @intCast(try cursor.readI32()) },
                clx_types.UINT32 => .{ .uint_val = @intCast(try cursor.readU32()) },
                clx_types.INT64 => .{ .int_val = try cursor.readI64() },
                clx_types.UINT64 => .{ .uint_val = try cursor.readU64() },
                clx_types.DOUBLE => .{ .float_val = try cursor.readF64() },
                clx_types.VOID_POINTER => .{ .uint_val = try cursor.readU64() },
                clx_types.STRING => try self.readUtf16String(allocator, cursor),
                clx_types.BYTE_ARRAY => try self.readByteArray(allocator, cursor),
                clx_types.LEVEL => try self.readLevel(allocator, cursor),
                else => return error.UnsupportedClxType,
            };
            errdefer value.deinit(allocator);

            const name = name_owned.?;
            if (name.len == 0) {
                if (output.getPtr("")) |existing_ptr| {
                    switch (existing_ptr.*) {
                        .array => |old_arr| {
                            const new_arr = allocator.realloc(old_arr, old_arr.len + 1) catch return error.OutOfMemory;
                            new_arr[new_arr.len - 1] = value;
                            existing_ptr.* = .{ .array = new_arr };
                        },
                        else => {
                            const first_val = existing_ptr.*;
                            const arr = allocator.alloc(ClxValue, 2) catch return error.OutOfMemory;
                            arr[0] = first_val;
                            arr[1] = value;
                            existing_ptr.* = .{ .array = arr };
                        },
                    }
                } else {
                    name_owned = null;
                    output.put(allocator, name, value) catch {
                        allocator.free(name);
                        return error.OutOfMemory;
                    };
                }
            } else {
                if (output.fetchRemove(name)) |old_kv| {
                    allocator.free(old_kv.key);
                    var old_val = old_kv.value;
                    old_val.deinit(allocator);
                }
                name_owned = null;
                output.put(allocator, name, value) catch {
                    allocator.free(name);
                    return error.OutOfMemory;
                };
            }
        }

        return .{ .object = output };
    }

    const HeaderInfo = struct {
        name: []u8,
        data_type: i8,
    };

    fn readChunkHeader(self: ClxLiteParser, allocator: std.mem.Allocator, cursor: *SliceCursor) Nd2Error!HeaderInfo {
        const data_type: i8 = @bitCast(try cursor.readU8());
        const name_length: usize = @intCast(try cursor.readU8());

        if (data_type == @as(i8, @intCast(clx_types.DEPRECATED)) or
            data_type == @as(i8, @intCast(clx_types.UNKNOWN)))
        {
            return error.InvalidFormat;
        }

        if (data_type == @as(i8, @intCast(clx_types.COMPRESS))) {
            const empty = allocator.alloc(u8, 0) catch return error.OutOfMemory;
            return .{ .name = empty, .data_type = data_type };
        }

        const name_bytes = try cursor.readSlice(name_length * 2);
        const decoded = try decodeUtf16Le(allocator, name_bytes);
        defer allocator.free(decoded);

        const trimmed = std.mem.trimEnd(u8, decoded, "\x00");
        const final_slice = if (self.strip_prefix) stripLowercasePrefix(trimmed) else trimmed;
        const duped = allocator.dupe(u8, final_slice) catch return error.OutOfMemory;
        return .{ .name = duped, .data_type = data_type };
    }

    fn readUtf16String(_: ClxLiteParser, allocator: std.mem.Allocator, cursor: *SliceCursor) Nd2Error!ClxValue {
        const start = cursor.pos;
        while (true) {
            const b1 = try cursor.readU8();
            const b2 = try cursor.readU8();
            if (b1 == 0 and b2 == 0) break;
        }
        const raw = cursor.data[start..cursor.pos];
        const decoded = try decodeUtf16Le(allocator, raw);
        defer allocator.free(decoded);

        const trimmed = std.mem.trimEnd(u8, decoded, "\x00");
        const duped = allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
        return .{ .string_val = duped };
    }

    fn readByteArray(self: ClxLiteParser, allocator: std.mem.Allocator, cursor: *SliceCursor) Nd2Error!ClxValue {
        const size_u64 = try cursor.readU64();
        const size = std.math.cast(usize, size_u64) orelse return error.InvalidFormat;
        const slice = try cursor.readSlice(size);

        if (looksLikeClxLite(slice)) {
            if (self.parse(allocator, slice)) |nested| {
                return nested;
            } else |_| {}
        }

        const bytes = allocator.dupe(u8, slice) catch return error.OutOfMemory;
        return .{ .byte_array = bytes };
    }

    fn readLevel(self: ClxLiteParser, allocator: std.mem.Allocator, cursor: *SliceCursor) Nd2Error!ClxValue {
        const item_count: usize = @intCast(try cursor.readU32());
        _ = try cursor.readU64(); // length

        var value = try self.parseWithCount(allocator, cursor, item_count);
        errdefer value.deinit(allocator);

        const skip_bytes = std.math.mul(usize, item_count, 8) catch return error.InvalidFormat;
        const next_pos = std.math.add(usize, cursor.pos, skip_bytes) catch return error.InvalidFormat;
        if (next_pos > cursor.data.len) return error.InvalidFormat;
        cursor.pos = next_pos;

        if (value == .object and value.object.count() == 1) {
            if (value.object.fetchRemove("")) |kv| {
                allocator.free(kv.key);
                value.object.deinit(allocator);
                return kv.value;
            }
        }

        return value;
    }
};

fn looksLikeClxLite(data: []const u8) bool {
    if (data.len < 2) return false;
    const data_type = data[0];
    const name_length = data[1];

    if (data_type == clx_types.COMPRESS) return true;
    if (data_type < 1 or data_type > 11) return false;
    if (name_length <= 1) return false;

    const name_bytes = @as(usize, name_length) * 2;
    const header_and_name = 2 + name_bytes;
    if (data.len < header_and_name) return false;

    const name_end = 2 + name_bytes;
    if (data[name_end - 2] != 0 or data[name_end - 1] != 0) return false;

    return true;
}

fn decodeUtf16Le(allocator: std.mem.Allocator, bytes: []const u8) Nd2Error![]u8 {
    if (bytes.len % 2 != 0) return error.InvalidFormat;
    const count = bytes.len / 2;
    const u16s = allocator.alloc(u16, count) catch return error.OutOfMemory;
    defer allocator.free(u16s);

    for (0..count) |i| {
        u16s[i] = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
    }

    return std.unicode.utf16LeToUtf8Alloc(allocator, u16s) catch return error.InvalidFormat;
}

fn stripLowercasePrefix(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isLower(s[i]) or s[i] == '_')) : (i += 1) {}
    return s[i..];
}

pub fn decompressZlib(allocator: std.mem.Allocator, data: []const u8) Nd2Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var in: std.Io.Reader = .fixed(data);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &window_buf);
    _ = decomp.reader.streamRemaining(&out.writer) catch return error.InvalidFormat;

    return out.toOwnedSlice() catch return error.OutOfMemory;
}
