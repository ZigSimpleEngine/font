//! Glyph outline decoding for the `glyf` table.
//!
//! Converts raw `glyf` bytes into a resolution-independent outline made of
//! quadratic contours: a flat list of points, parallel on-curve flags and one
//! span per contour. Both simple glyphs and composite glyphs (with their
//! scale / x-y scale / 2x2 component transforms) are supported. Implied
//! on-curve points between consecutive off-curve control points are left in
//! the data; the rasterizer resolves them.

const std = @import("std");
const read_module = @import("read.zig");
const sfnt = @import("sfnt.zig");
const Reader = read_module.Reader;

/// A single two-dimensional point in font units (y grows upward).
pub const Point = struct {
    /// Horizontal position in font units.
    x: f32,
    /// Vertical position in font units, positive above the baseline.
    y: f32,
};

/// Half-open description of one contour inside the flat point list.
pub const ContourSpan = struct {
    /// Index of the contour's first point inside `Outline.points`.
    first_point_index: u32,
    /// Number of consecutive points belonging to this contour.
    point_count: u32,
};

/// Error set produced while decoding glyph data.
pub const DecodeError = error{
    /// Allocation failed while building the outline.
    OutOfMemory,
    /// The `glyf` bytes are malformed: truncated records, invalid point
    /// counts or non-monotonic contour end points.
    InvalidGlyph,
};

/// Decoded outline of one glyph, allocated from an internal arena.
///
/// All slices are owned by the arena stored in `arena`; freeing the outline
/// through `deinit` releases every slice at once.
pub const Outline = struct {
    /// Arena owning every allocation of this outline.
    arena: std.heap.ArenaAllocator,
    /// Flat list of contour points in font units, grouped per `contours`.
    points: []Point = &.{},
    /// For each entry of `points`, `true` when the point lies on the curve
    /// and `false` when it is a quadratic Bézier control point.
    on_curve_flags: []bool = &.{},
    /// One span per contour describing its range inside `points`.
    contours: []ContourSpan = &.{},
    /// Minimum x of the outline bounding box in font units.
    min_x: f32 = 0,
    /// Minimum y of the outline bounding box in font units.
    min_y: f32 = 0,
    /// Maximum x of the outline bounding box in font units.
    max_x: f32 = 0,
    /// Maximum y of the outline bounding box in font units.
    max_y: f32 = 0,
    /// `true` when the glyph produced no points at all (for example a space).
    is_empty: bool = true,

    /// Releases every allocation owned by this outline.
    ///
    /// The outline must not be used afterwards.
    pub fn deinit(self: *Outline) void {
        self.arena.deinit();
    }
};

/// Affine transform applied to component points of composite glyphs.
///
/// The transform follows the TrueType row-vector convention:
/// `x' = xx*x + xy*y + offset_x`, `y' = yx*x + yy*y + offset_y`.
pub const GlyphTransform = struct {
    /// Contribution of the input x coordinate to the output x.
    xx: f32 = 1,
    /// Contribution of the input x coordinate to the output y.
    yx: f32 = 0,
    /// Contribution of the input y coordinate to the output x.
    xy: f32 = 0,
    /// Contribution of the input y coordinate to the output y.
    yy: f32 = 1,
    /// Translation added to the output x (font units).
    offset_x: f32 = 0,
    /// Translation added to the output y (font units).
    offset_y: f32 = 0,

    /// Maps one point through this transform.
    ///
    /// Parameters:
    ///     `point`: Point in font units to transform.
    ///
    /// Returns:
    ///     The transformed point in font units.
    fn applyToPoint(self: GlyphTransform, point: Point) Point {
        return .{
            .x = self.xx * point.x + self.xy * point.y + self.offset_x,
            .y = self.yx * point.x + self.yy * point.y + self.offset_y,
        };
    }

    /// Builds the transform that applies a composite component's own matrix
    /// and offset first, then the parent transform.
    ///
    /// Parameters:
    ///     `component_xx`: xx coefficient of the component matrix.
    ///     `component_yx`: yx coefficient of the component matrix.
    ///     `component_xy`: xy coefficient of the component matrix.
    ///     `component_yy`: yy coefficient of the component matrix.
    ///     `component_offset_x`: Translation of the component in parent
    ///         font units.
    ///     `component_offset_y`: Translation of the component in parent
    ///         font units.
    ///
    /// Returns:
    ///     A single transform equivalent to `component` followed by `self`.
    fn combinedWith(
        self: GlyphTransform,
        component_xx: f32,
        component_yx: f32,
        component_xy: f32,
        component_yy: f32,
        component_offset_x: f32,
        component_offset_y: f32,
    ) GlyphTransform {
        return .{
            .xx = self.xx * component_xx + self.xy * component_yx,
            .yx = self.yx * component_xx + self.yy * component_yx,
            .xy = self.xx * component_xy + self.xy * component_yy,
            .yy = self.yx * component_xy + self.yy * component_yy,
            .offset_x = self.xx * component_offset_x + self.xy * component_offset_y + self.offset_x,
            .offset_y = self.yx * component_offset_x + self.yy * component_offset_y + self.offset_y,
        };
    }
};

/// Decodes the complete outline of one glyph.
///
/// Composite glyphs are expanded recursively (bounded by a depth limit of 8)
/// with all component transforms baked into the resulting points. The
/// bounding box is computed from the decoded points; for composite glyphs
/// this avoids relying on the possibly stale box stored in the glyph header.
///
/// Parameters:
///     `allocator`: Allocator used to back the outline's internal arena.
///     `tables`: Parsed font tables providing `glyf` and `loca` access.
///     `glyph_id`: Index of the glyph to decode.
///
/// Returns:
///     An owned `Outline`; release it with `deinit` when done.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
///     error.InvalidGlyph: The glyph bytes are missing or malformed.
pub fn decode(
    allocator: std.mem.Allocator,
    tables: *const sfnt.FontTables,
    glyph_id: u16,
) DecodeError!Outline {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var point_list: std.ArrayList(Point) = .empty;
    var on_curve_flag_list: std.ArrayList(bool) = .empty;
    var contour_span_list: std.ArrayList(ContourSpan) = .empty;

    try decodeGlyphInto(arena_allocator, tables, glyph_id, .{}, &point_list, &on_curve_flag_list, &contour_span_list, 0);

    var result_outline = Outline{ .arena = arena };
    result_outline.points = point_list.items;
    result_outline.on_curve_flags = on_curve_flag_list.items;
    result_outline.contours = contour_span_list.items;

    var smallest_x: f32 = std.math.floatMax(f32);
    var smallest_y: f32 = std.math.floatMax(f32);
    var largest_x: f32 = -std.math.floatMax(f32);
    var largest_y: f32 = -std.math.floatMax(f32);
    for (result_outline.points) |point| {
        smallest_x = @min(smallest_x, point.x);
        smallest_y = @min(smallest_y, point.y);
        largest_x = @max(largest_x, point.x);
        largest_y = @max(largest_y, point.y);
    }
    if (result_outline.points.len > 0) {
        result_outline.is_empty = false;
        result_outline.min_x = smallest_x;
        result_outline.min_y = smallest_y;
        result_outline.max_x = largest_x;
        result_outline.max_y = largest_y;
    }
    return result_outline;
}

/// Decodes one glyph and appends its transformed points and contours to the
/// given output lists.
///
/// Acts as the shared entry point for simple and composite glyphs and is the
/// recursion vehicle for composite components.
///
/// Parameters:
///     `allocator`: Allocator for the output lists (usually an arena).
///     `tables`: Parsed font tables providing glyph byte access.
///     `glyph_id`: Index of the glyph to decode.
///     `transform`: Transform to bake into every appended point.
///     `out_points`: List the transformed points are appended to.
///     `out_on_curve_flags`: List the on-curve flags are appended to, in the
///         same order as `out_points`.
///     `out_contours`: List the contour spans are appended to.
///     `recursion_depth`: Current composite nesting depth; decoding stops
///         silently when the depth exceeds 8.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
///     error.InvalidGlyph: The glyph bytes are missing or malformed.
fn decodeGlyphInto(
    allocator: std.mem.Allocator,
    tables: *const sfnt.FontTables,
    glyph_id: u16,
    transform: GlyphTransform,
    out_points: *std.ArrayList(Point),
    out_on_curve_flags: *std.ArrayList(bool),
    out_contours: *std.ArrayList(ContourSpan),
    recursion_depth: u32,
) DecodeError!void {
    if (recursion_depth > 8) return;
    const glyph_bytes = tables.glyphByteData(glyph_id) catch return error.InvalidGlyph;
    if (glyph_bytes.len < 10) return;

    var reader = Reader.init(glyph_bytes);
    const signed_contour_count = reader.readInt16() catch return error.InvalidGlyph;
    reader.skipBytes(8) catch return error.InvalidGlyph;

    const first_point_index_of_glyph = out_points.items.len;
    if (signed_contour_count >= 0) {
        try decodeSimpleGlyph(allocator, &reader, @intCast(signed_contour_count), transform, out_points, out_on_curve_flags, out_contours, first_point_index_of_glyph);
    } else {
        try decodeCompositeGlyph(allocator, tables, &reader, transform, out_points, out_on_curve_flags, out_contours, recursion_depth);
    }
}

/// Decodes a simple (non-composite) glyph.
///
/// Layout after the 10-byte glyph header: contour end points, instructions
/// (skipped, no hinting), a flag stream with run-length repeats, then
/// delta-encoded x coordinates followed by delta-encoded y coordinates.
/// Coordinate compression per point is controlled by the flag bits:
/// bit 1 (x short), bit 2 (y short), bit 4 (x same/positive),
/// bit 5 (y same/positive), bit 0 marks on-curve points and bit 3 marks a
/// repeated flag.
///
/// Parameters:
///     `allocator`: Allocator for temporary buffers and the output lists.
///     `reader`: Reader positioned right after the glyph header.
///     `contour_count`: Number of contours decoded from the glyph header.
///     `transform`: Transform to bake into every appended point.
///     `out_points`: List the transformed points are appended to.
///     `out_on_curve_flags`: List the on-curve flags are appended to.
///     `out_contours`: List the contour spans are appended to.
///     `first_point_index_of_glyph`: Index the glyph's first point will have
///         inside `out_points`; used to make contour spans absolute.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
///     error.InvalidGlyph: The glyph bytes are truncated, the point count is
///         implausible or the contour end points are non-monotonic.
fn decodeSimpleGlyph(
    allocator: std.mem.Allocator,
    reader: *Reader,
    contour_count: u16,
    transform: GlyphTransform,
    out_points: *std.ArrayList(Point),
    out_on_curve_flags: *std.ArrayList(bool),
    out_contours: *std.ArrayList(ContourSpan),
    first_point_index_of_glyph: usize,
) DecodeError!void {
    if (contour_count == 0) return;

    const contour_end_points = allocator.alloc(u16, contour_count) catch return error.OutOfMemory;
    defer allocator.free(contour_end_points);
    for (contour_end_points) |*end_point_value| {
        end_point_value.* = reader.readUInt16() catch return error.InvalidGlyph;
    }
    const total_point_count: usize = @as(usize, contour_end_points[contour_count - 1]) + 1;
    if (total_point_count == 0) return;
    if (total_point_count > 128 * 1024) return error.InvalidGlyph;

    const instruction_byte_count = reader.readUInt16() catch return error.InvalidGlyph;
    reader.skipBytes(instruction_byte_count) catch return error.InvalidGlyph;

    const point_flags = allocator.alloc(u8, total_point_count) catch return error.OutOfMemory;
    defer allocator.free(point_flags);
    var flag_index: usize = 0;
    while (flag_index < total_point_count) {
        const flag_byte = reader.readByte() catch return error.InvalidGlyph;
        point_flags[flag_index] = flag_byte;
        flag_index += 1;
        if (flag_byte & 0x08 != 0) {
            var repeat_count = reader.readByte() catch return error.InvalidGlyph;
            while (repeat_count > 0 and flag_index < total_point_count) : (repeat_count -= 1) {
                point_flags[flag_index] = flag_byte;
                flag_index += 1;
            }
        }
    }

    const x_coordinates = allocator.alloc(i32, total_point_count) catch return error.OutOfMemory;
    defer allocator.free(x_coordinates);
    const y_coordinates = allocator.alloc(i32, total_point_count) catch return error.OutOfMemory;
    defer allocator.free(y_coordinates);

    var running_coordinate: i32 = 0;
    var point_index: usize = 0;
    while (point_index < total_point_count) : (point_index += 1) {
        const flag_byte = point_flags[point_index];
        var x_delta: i32 = 0;
        if (flag_byte & 0x02 != 0) {
            const delta_byte = reader.readByte() catch return error.InvalidGlyph;
            x_delta = if (flag_byte & 0x10 != 0) delta_byte else -@as(i32, delta_byte);
        } else if (flag_byte & 0x10 == 0) {
            x_delta = reader.readInt16() catch return error.InvalidGlyph;
        }
        running_coordinate += x_delta;
        x_coordinates[point_index] = running_coordinate;
    }
    running_coordinate = 0;
    point_index = 0;
    while (point_index < total_point_count) : (point_index += 1) {
        const flag_byte = point_flags[point_index];
        var y_delta: i32 = 0;
        if (flag_byte & 0x04 != 0) {
            const delta_byte = reader.readByte() catch return error.InvalidGlyph;
            y_delta = if (flag_byte & 0x20 != 0) delta_byte else -@as(i32, delta_byte);
        } else if (flag_byte & 0x20 == 0) {
            y_delta = reader.readInt16() catch return error.InvalidGlyph;
        }
        running_coordinate += y_delta;
        y_coordinates[point_index] = running_coordinate;
    }

    point_index = 0;
    while (point_index < total_point_count) : (point_index += 1) {
        const transformed_point = transform.applyToPoint(.{
            .x = @floatFromInt(x_coordinates[point_index]),
            .y = @floatFromInt(y_coordinates[point_index]),
        });
        out_points.append(allocator, transformed_point) catch return error.OutOfMemory;
        out_on_curve_flags.append(allocator, point_flags[point_index] & 0x01 != 0) catch return error.OutOfMemory;
    }

    var previous_end_index: usize = 0;
    for (contour_end_points) |contour_end_point| {
        const contour_end_index: usize = contour_end_point;
        if (contour_end_index + 1 < previous_end_index or contour_end_index >= total_point_count) return error.InvalidGlyph;
        const points_in_contour = contour_end_index + 1 - previous_end_index;
        if (points_in_contour > 0) {
            out_contours.append(allocator, .{
                .first_point_index = @intCast(first_point_index_of_glyph + previous_end_index),
                .point_count = @intCast(points_in_contour),
            }) catch return error.OutOfMemory;
        }
        previous_end_index = contour_end_index + 1;
    }
}

/// Decodes a composite glyph by expanding each component recursively.
///
/// Each component record carries flags, a glyph id, an offset and an optional
/// transform. Supported flags: 0x0001 (word-sized arguments), 0x0002
/// (arguments are point offsets), 0x0008 (uniform scale), 0x0020 (more
/// components follow), 0x0040 (separate x/y scales) and 0x0080 (full 2x2
/// matrix). Scales use the F2Dot14 fixed-point format. Point-matching
/// placement is approximated as a plain offset.
///
/// Parameters:
///     `allocator`: Allocator forwarded to the component decoding.
///     `tables`: Parsed font tables providing component glyph byte access.
///     `reader`: Reader positioned right after the composite glyph header.
///     `transform`: Parent transform to combine every component with.
///     `out_points`: List the transformed points are appended to.
///     `out_on_curve_flags`: List the on-curve flags are appended to.
///     `out_contours`: List the contour spans are appended to.
///     `recursion_depth`: Current composite nesting depth forwarded to the
///         component decoding.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
///     error.InvalidGlyph: A component record or component glyph is malformed.
fn decodeCompositeGlyph(
    allocator: std.mem.Allocator,
    tables: *const sfnt.FontTables,
    reader: *Reader,
    transform: GlyphTransform,
    out_points: *std.ArrayList(Point),
    out_on_curve_flags: *std.ArrayList(bool),
    out_contours: *std.ArrayList(ContourSpan),
    recursion_depth: u32,
) DecodeError!void {
    while (true) {
        const component_flags = reader.readUInt16() catch return error.InvalidGlyph;
        const component_glyph_id = reader.readUInt16() catch return error.InvalidGlyph;
        var component_offset_x: f32 = 0;
        var component_offset_y: f32 = 0;
        if (component_flags & 0x0002 != 0) {
            if (component_flags & 0x0001 != 0) {
                component_offset_x = @floatFromInt(reader.readInt16() catch return error.InvalidGlyph);
                component_offset_y = @floatFromInt(reader.readInt16() catch return error.InvalidGlyph);
            } else {
                component_offset_x = @floatFromInt(reader.readByte() catch return error.InvalidGlyph);
                component_offset_y = @floatFromInt(reader.readByte() catch return error.InvalidGlyph);
            }
        }
        var component_xx: f32 = 1;
        var component_yx: f32 = 0;
        var component_xy: f32 = 0;
        var component_yy: f32 = 1;
        if (component_flags & 0x0008 != 0) {
            const uniform_scale = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
            component_xx = uniform_scale;
            component_yy = uniform_scale;
        } else if (component_flags & 0x0040 != 0) {
            component_xx = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
            component_yy = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
        } else if (component_flags & 0x0080 != 0) {
            component_xx = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
            component_yx = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
            component_xy = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
            component_yy = f2Dot14ToFloat(reader.readInt16() catch return error.InvalidGlyph);
        }
        const combined_transform = transform.combinedWith(component_xx, component_yx, component_xy, component_yy, component_offset_x, component_offset_y);
        try decodeGlyphInto(allocator, tables, component_glyph_id, combined_transform, out_points, out_on_curve_flags, out_contours, recursion_depth + 1);
        if (component_flags & 0x0020 == 0) break;
    }
}

/// Converts a raw F2Dot14 fixed-point value into a float.
///
/// F2Dot14 is a signed 16-bit value with 2 integer bits and 14 fraction bits,
/// used by TrueType for component transform coefficients.
///
/// Parameters:
///     `raw_value`: Raw 16-bit fixed-point value.
///
/// Returns:
///     The value divided by 16384 as a float.
fn f2Dot14ToFloat(raw_value: i16) f32 {
    return @as(f32, @floatFromInt(raw_value)) / 16384.0;
}
