const std = @import("std");
const Nd2Error = @import("../error.zig").Nd2Error;
const clx_mod = @import("../parse/clx_lite.zig");
const ClxObject = clx_mod.ClxObject;
const ClxValue = clx_mod.ClxValue;
const types = @import("../types/mod.zig");
const CustomLoop = types.CustomLoop;
const ExpLoop = types.ExpLoop;
const NETimeLoop = types.NETimeLoop;
const NETimeLoopParams = types.NETimeLoopParams;
const Period = types.Period;
const Position = types.Position;
const StagePosition = types.StagePosition;
const TimeLoop = types.TimeLoop;
const TimeLoopParams = types.TimeLoopParams;
const XYPosLoop = types.XYPosLoop;
const XYPosLoopParams = types.XYPosLoopParams;
const ZStackLoop = types.ZStackLoop;
const ZStackLoopParams = types.ZStackLoopParams;

pub fn parseExperiment(allocator: std.mem.Allocator, clx: *const ClxValue) Nd2Error![]ExpLoop {
    var list: std.ArrayList(ExpLoop) = .empty;
    errdefer {
        for (list.items) |*l| l.deinit(allocator);
        list.deinit(allocator);
    }
    try parseExperimentInner(allocator, unwrapSingleItem(clx), 0, &list);
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn unwrapSingleItem(v_in: *const ClxValue) *const ClxValue {
    var v = v_in;
    while (true) {
        switch (v.*) {
            .array => |arr| {
                if (arr.len == 1) {
                    v = &arr[0];
                    continue;
                }
            },
            .object => |*map| {
                if (map.count() == 1) {
                    if (map.getPtr("")) |inner| {
                        v = inner;
                        continue;
                    }
                    if (map.getPtr("i0000000000")) |inner| {
                        v = inner;
                        continue;
                    }
                    if (map.getPtr("SLxExperiment")) |inner| {
                        v = inner;
                        continue;
                    }
                }
            },
            else => {},
        }
        break;
    }
    return v;
}

fn parseExperimentInner(
    allocator: std.mem.Allocator,
    clx_in: *const ClxValue,
    level: u32,
    dest: *std.ArrayList(ExpLoop),
) Nd2Error!void {
    const clx = unwrapSingleItem(clx_in);
    const obj = clx.asObject() orelse return;

    if (try parseSingleLoop(allocator, obj)) |exp_loop| {
        if (exp_loop.count() > 0) {
            dest.append(allocator, exp_loop) catch {
                var mut_loop = exp_loop;
                mut_loop.deinit(allocator);
                return error.OutOfMemory;
            };
        } else {
            var mut_loop = exp_loop;
            mut_loop.deinit(allocator);
        }
    }

    if (obj.getPtr("ppNextLevelEx")) |next_level| {
        var items = try collectOrderedItems(allocator, next_level, true);
        defer items.deinit(allocator);

        for (items.items) |item| {
            try parseExperimentInner(allocator, unwrapSingleItem(item), level + 1, dest);
        }
    }
}

fn collectOrderedItems(
    allocator: std.mem.Allocator,
    val: *const ClxValue,
    allow_single_loop_object: bool,
) Nd2Error!std.ArrayList(*const ClxValue) {
    var out: std.ArrayList(*const ClxValue) = .empty;
    errdefer out.deinit(allocator);

    switch (val.*) {
        .array => |arr| {
            for (arr) |*item| {
                out.append(allocator, item) catch return error.OutOfMemory;
            }
        },
        .object => |*map| {
            if (allow_single_loop_object and (map.contains("eType") or map.contains("uiLoopType"))) {
                out.append(allocator, val) catch return error.OutOfMemory;
            } else {
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(allocator);
                var it = map.keyIterator();
                while (it.next()) |k| {
                    keys.append(allocator, k.*) catch return error.OutOfMemory;
                }
                std.mem.sort([]const u8, keys.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);
                for (keys.items) |k| {
                    if (map.getPtr(k)) |v_ptr| {
                        out.append(allocator, v_ptr) catch return error.OutOfMemory;
                    }
                }
            }
        },
        else => {},
    }
    return out;
}

fn valueAsU32(v: ClxValue) ?u32 {
    if (v.asU64()) |u| return @intCast(u);
    if (v.asI64()) |i| if (i >= 0) return @intCast(i);
    return null;
}

fn valueAsF64(v: ClxValue) ?f64 {
    if (v.asF64()) |f| return f;
    if (v.asU64()) |u| return @floatFromInt(u);
    if (v.asI64()) |i| return @floatFromInt(i);
    return null;
}

fn valueAsBool(v: ClxValue) ?bool {
    if (v.asBool()) |b| return b;
    if (v.asU64()) |u| return u != 0;
    if (v.asI64()) |i| return i != 0;
    return null;
}

fn mapGetU32(map: *const ClxObject, key: []const u8) ?u32 {
    if (map.get(key)) |v| return valueAsU32(v);
    return null;
}

fn mapGetF64(map: *const ClxObject, key: []const u8) ?f64 {
    if (map.get(key)) |v| return valueAsF64(v);
    return null;
}

fn mapGetBool(map: *const ClxObject, key: []const u8) ?bool {
    if (map.get(key)) |v| return valueAsBool(v);
    return null;
}

fn extractValidFlags(allocator: std.mem.Allocator, val_opt: ?*const ClxValue) Nd2Error![]bool {
    const val = val_opt orelse return &.{};
    switch (val.*) {
        .byte_array => |bytes| {
            const flags = allocator.alloc(bool, bytes.len) catch return error.OutOfMemory;
            for (bytes, 0..) |b, i| flags[i] = b != 0;
            return flags;
        },
        .array, .object => {
            var items = try collectOrderedItems(allocator, val, false);
            defer items.deinit(allocator);
            const flags = allocator.alloc(bool, items.items.len) catch return error.OutOfMemory;
            for (items.items, 0..) |item, i| {
                flags[i] = valueAsBool(item.*) orelse true;
            }
            return flags;
        },
        else => return &.{},
    }
}

fn parseSingleLoop(allocator: std.mem.Allocator, obj: *const ClxObject) Nd2Error!?ExpLoop {
    const loop_type = mapGetU32(obj, "uiLoopType") orelse mapGetU32(obj, "eType") orelse return null;
    const nesting_level = mapGetU32(obj, "uiNestingLevel") orelse 0;

    var loop_pars: ?*const ClxObject = if (obj.getPtr("uLoopPars")) |u| u.asObject() else null;
    if (loop_pars) |pars| {
        if (pars.count() == 1) {
            if (pars.getPtr("i0000000000")) |inner| {
                if (inner.asObject()) |inner_obj| {
                    loop_pars = inner_obj;
                }
            }
        }
    }
    const params = loop_pars orelse obj;
    const loop_count = mapGetU32(params, "uiCount") orelse mapGetU32(obj, "uiCount") orelse 0;

    switch (loop_type) {
        1 => {
            // TimeLoop
            if (loop_count == 0) return null;
            return .{ .TimeLoop = .{
                .count = loop_count,
                .nesting_level = nesting_level,
                .parameters = .{
                    .start_ms = mapGetF64(params, "dStart") orelse 0.0,
                    .period_ms = mapGetF64(params, "dPeriod") orelse 0.0,
                    .duration_ms = mapGetF64(params, "dDuration") orelse 0.0,
                    .period_diff = null,
                },
            } };
        },
        4 => {
            // ZStackLoop
            if (loop_count == 0) return null;
            const home_idx: i32 = if (mapGetU32(params, "uiHomeIndex") orelse mapGetU32(params, "iHome")) |v|
                @intCast(v)
            else
                0;
            const bottom_to_top = mapGetBool(params, "bBottomToTop") orelse
                (if (mapGetU32(params, "iType")) |v| (v < 4) else false);
            const dev_val = params.get("wsZDevice") orelse params.get("pPeriod");
            const device_name = if (dev_val) |dv|
                if (dv.asStr()) |s| (allocator.dupe(u8, s) catch return error.OutOfMemory) else null
            else
                null;

            return .{ .ZStackLoop = .{
                .count = loop_count,
                .nesting_level = nesting_level,
                .parameters = .{
                    .home_index = home_idx,
                    .step_um = mapGetF64(params, "dZStep") orelse 0.0,
                    .bottom_to_top = bottom_to_top,
                    .device_name = device_name,
                },
            } };
        },
        2 => {
            // XYPosLoop
            const is_setting_z = mapGetBool(params, "bUseZ") orelse
                mapGetBool(params, "bIsSettingZ") orelse
                mapGetBool(obj, "bIsSettingZ") orelse false;
            const rel_xy = mapGetBool(params, "bRelativeXY") orelse false;
            const ref_x = if (rel_xy) (mapGetF64(params, "dReferenceX") orelse 0.0) else 0.0;
            const ref_y = if (rel_xy) (mapGetF64(params, "dReferenceY") orelse 0.0) else 0.0;

            const valid = try extractValidFlags(allocator, obj.getPtr("pItemValid"));
            defer if (valid.len > 0) allocator.free(valid);

            const pos_list = params.getPtr("Points") orelse params.getPtr("pPeriod") orelse obj.getPtr("pPeriod");
            var points: std.ArrayList(Position) = .empty;
            errdefer {
                for (points.items) |*p| p.deinit(allocator);
                points.deinit(allocator);
            }

            if (pos_list) |pl| {
                var pos_items = try collectOrderedItems(allocator, pl, false);
                defer pos_items.deinit(allocator);

                for (pos_items.items, 0..) |pos_item_raw, i| {
                    if (valid.len > 0 and (i >= valid.len or !valid[i])) continue;
                    const pos_item = unwrapSingleItem(pos_item_raw);
                    if (pos_item.asObject()) |pos_obj| {
                        const x = ref_x + (mapGetF64(pos_obj, "dPosX") orelse 0.0);
                        const y = ref_y + (mapGetF64(pos_obj, "dPosY") orelse 0.0);
                        const z = if (is_setting_z) (mapGetF64(pos_obj, "dPosZ") orelse 0.0) else 0.0;
                        const pfs_raw = mapGetF64(pos_obj, "dPFSOffset");
                        const pfs_offset: ?f64 = if (pfs_raw) |v| (if (v >= 0.0) v else null) else null;

                        const name_val = pos_obj.get("dPosName") orelse pos_obj.get("pPosName") orelse pos_obj.get("wszName");
                        const name = if (name_val) |nv|
                            if (nv.asStr()) |s| (allocator.dupe(u8, s) catch return error.OutOfMemory) else null
                        else
                            null;

                        points.append(allocator, .{
                            .stage_position_um = .{ .x = x, .y = y, .z = z },
                            .pfs_offset = pfs_offset,
                            .name = name,
                        }) catch {
                            if (name) |n| allocator.free(n);
                            return error.OutOfMemory;
                        };
                    }
                }
            }

            const count: u32 = if (points.items.len == 0) loop_count else @intCast(points.items.len);
            const points_slice = points.toOwnedSlice(allocator) catch return error.OutOfMemory;
            return .{ .XYPosLoop = .{
                .count = count,
                .nesting_level = nesting_level,
                .parameters = .{
                    .is_setting_z = is_setting_z,
                    .points = points_slice,
                },
            } };
        },
        8 => {
            // NETimeLoop
            const valid = try extractValidFlags(allocator, params.getPtr("pPeriodValid"));
            defer if (valid.len > 0) allocator.free(valid);

            var periods: std.ArrayList(Period) = .empty;
            errdefer periods.deinit(allocator);

            if (params.getPtr("pPeriod")) |period_src| {
                var period_items = try collectOrderedItems(allocator, period_src, false);
                defer period_items.deinit(allocator);

                for (period_items.items, 0..) |period_item, i| {
                    if (valid.len > 0 and (i >= valid.len or !valid[i])) continue;
                    if (period_item.asObject()) |period_obj| {
                        const cnt = mapGetU32(period_obj, "uiCount") orelse 0;
                        if (cnt == 0) continue;
                        periods.append(allocator, .{
                            .count = cnt,
                            .start_ms = mapGetF64(period_obj, "dStart") orelse 0.0,
                            .period_ms = mapGetF64(period_obj, "dPeriod") orelse mapGetF64(period_obj, "dAvgPeriodDiff") orelse 0.0,
                            .duration_ms = mapGetF64(period_obj, "dDuration") orelse 0.0,
                            .period_diff = null,
                        }) catch return error.OutOfMemory;
                    }
                }
            }

            var total_count: u32 = 0;
            for (periods.items) |p| total_count += p.count;
            const periods_slice = periods.toOwnedSlice(allocator) catch return error.OutOfMemory;
            return .{ .NETimeLoop = .{
                .count = total_count,
                .nesting_level = nesting_level,
                .parameters = .{ .periods = periods_slice },
            } };
        },
        7 => {
            return .{ .CustomLoop = .{
                .count = loop_count,
                .nesting_level = nesting_level,
            } };
        },
        else => return null,
    }
}
