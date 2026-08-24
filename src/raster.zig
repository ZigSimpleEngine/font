//! Anti-aliased scanline rasterizer for glyph outlines.
//!
//! The pipeline works in three stages:
//! 1. Contours (points plus on-curve flags) are converted into quadratic
//!    Béziers, resolving implied on-curve points, and every Bézier is
//!    adaptively flattened into straight line segments.
//! 2. Every segment is clipped to the bitmap, split at integer row and column
//!    boundaries, and each resulting cell piece deposits its exact signed
//!    trapezoid contribution (`cover` and `area` sums) into a per-cell
//!    accumulator — the same approach FreeType's smooth renderer uses.
//! 3. Each pixel row is swept left to right; the winding-accumulated coverage
//!    per cell is converted to an 8-bit alpha value and blended into the
//!    destination bitmap with a max-based blend so overlapping draws never
//!    darken each other.

const std = @import("std");
const outline_module = @import("outline.zig");

/// A single two-dimensional point in device pixel space (y grows downward).
pub const Point = outline_module.Point;

/// 8-bit coverage buffer that rasterization draws into.
///
/// The buffer holds one coverage byte per pixel; `stride` allows the bitmap
/// to be a region inside a larger buffer.
pub const Bitmap = struct {
    /// Number of usable pixels per row.
    width: u32,
    /// Number of rows in the bitmap.
    height: u32,
    /// Number of bytes between the starts of two consecutive rows.
    stride: u32,
    /// Pixel storage, at least `(height - 1) * stride + width` bytes long.
    data: []u8,

    /// Creates a tightly packed bitmap whose stride equals its width.
    ///
    /// Parameters:
    ///     `width`: Number of usable pixels per row.
    ///     `height`: Number of rows.
    ///     `data`: Pixel storage; must hold at least `width * height` bytes.
    ///
    /// Returns:
    ///     A bitmap with `stride` set to `width`.
    pub fn init(width: u32, height: u32, data: []u8) Bitmap {
        return .{ .width = width, .height = height, .stride = width, .data = data };
    }

    /// Creates a bitmap embedded in a larger buffer.
    ///
    /// Parameters:
    ///     `width`: Number of usable pixels per row.
    ///     `height`: Number of rows.
    ///     `stride`: Bytes between the starts of two consecutive rows; must
    ///         be greater than or equal to `width`.
    ///     `data`: Pixel storage; must hold at least
    ///         `(height - 1) * stride + width` bytes.
    ///
    /// Returns:
    ///     A bitmap with the given stride.
    pub fn initWithStride(width: u32, height: u32, stride: u32, data: []u8) Bitmap {
        return .{ .width = width, .height = height, .stride = stride, .data = data };
    }

    /// Returns a mutable pointer to one pixel of the bitmap.
    ///
    /// Parameters:
    ///     `x`: Zero-based column of the pixel.
    ///     `y`: Zero-based row of the pixel.
    ///
    /// Returns:
    ///     Pointer to the coverage byte, or `null` when the coordinates fall
    ///     outside the bitmap.
    pub fn pixelPointerAt(self: *const Bitmap, x: u32, y: u32) ?*u8 {
        if (x >= self.width or y >= self.height) return null;
        return &self.data[@as(usize, y) * self.stride + x];
    }

    /// Fills every usable pixel of the bitmap with one value.
    ///
    /// Parameters:
    ///     `fill_value`: Coverage byte written to every pixel.
    pub fn clear(self: *const Bitmap, fill_value: u8) void {
        var row_index: u32 = 0;
        while (row_index < self.height) : (row_index += 1) {
            const pixel_row = self.data[@as(usize, row_index) * self.stride ..][0..self.width];
            @memset(pixel_row, fill_value);
        }
    }
};

/// Error set produced by rasterization.
pub const RenderError = error{
    /// Allocation failed while building the segment list or the cell grid.
    OutOfMemory,
};

/// Default maximum distance between a Bézier curve and its flattening chord,
/// in pixels. Smaller values yield smoother curves at the cost of more
/// segments.
pub const default_tolerance: f32 = 0.2;

/// One straight line segment in device pixel space (y grows downward).
pub const LineSegment = struct {
    /// Horizontal position of the segment start, in pixels.
    start_x: f32,
    /// Vertical position of the segment start, in pixels.
    start_y: f32,
    /// Horizontal position of the segment end, in pixels.
    end_x: f32,
    /// Vertical position of the segment end, in pixels.
    end_y: f32,
};

/// Fills a shape into a bitmap using the nonzero winding rule with exact
/// anti-aliased coverage.
///
/// The shape is given as decoded outline contours already transformed into
/// device pixel space (y grows downward). Existing bitmap content is
/// preserved: new coverage is blended in with a max-based blend.
///
/// Parameters:
///     `allocator`: Allocator for temporary segment and cell buffers.
///     `bitmap`: Destination bitmap; its content is blended, not replaced.
///     `outline_points`: Flat list of contour points in device pixels.
///     `on_curve_flags`: For each point, `true` when the point lies on the
///         curve and `false` when it is a quadratic control point.
///     `contour_spans`: One span per contour describing its range inside
///         `outline_points`.
///     `tolerance`: Maximum distance between a curve and its flattening
///         chord, in pixels.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
pub fn renderShape(
    allocator: std.mem.Allocator,
    bitmap: *const Bitmap,
    outline_points: []const Point,
    on_curve_flags: []const bool,
    contour_spans: []const outline_module.ContourSpan,
    tolerance: f32,
) RenderError!void {
    var flattened_segments: std.ArrayList(LineSegment) = .empty;
    defer flattened_segments.deinit(allocator);

    var contour_context = ContourContext{
        .contour_points = outline_points,
        .on_curve_flags = on_curve_flags,
        .output_segments = &flattened_segments,
        .allocator = allocator,
        .tolerance = tolerance,
    };

    for (contour_spans) |contour_span| {
        if (contour_span.point_count < 2) continue;
        if (@as(usize, contour_span.first_point_index) + contour_span.point_count > outline_points.len) continue;
        appendContourSegments(&contour_context, contour_span.first_point_index, contour_span.point_count) catch return error.OutOfMemory;
    }

    try rasterizeSegments(allocator, bitmap, flattened_segments.items);
}

/// Inputs and outputs of the per-contour segment emission pass.
const ContourContext = struct {
    /// Flat list of points shared by all contours being emitted.
    contour_points: []const Point,
    /// On-curve flag for every entry of `contour_points`.
    on_curve_flags: []const bool,
    /// Segment list every flattened piece is appended to.
    output_segments: *std.ArrayList(LineSegment),
    /// Allocator used when appending segments.
    allocator: std.mem.Allocator,
    /// Maximum curve-to-chord distance allowed when flattening.
    tolerance: f32,
};

/// Converts one contour into flattened line segments.
///
/// TrueType contours may start or end on off-curve points; the emission
/// rotates the loop to start on an on-curve point (inserting implied
/// midpoints between consecutive off-curve points) so that the point
/// sequence alternates on/off/on and every pair forms either a line or a
/// quadratic Bézier. Contours without any on-curve point are treated as a
/// closed loop of implied quadratic segments.
///
/// Parameters:
///     `context`: Shared points, flags and output segment list.
///     `first_point_index`: Index of the contour's first point inside
///         `context.contour_points`.
///     `point_count`: Number of points belonging to the contour.
///
/// Errors:
///     error.OutOfMemory: Appending a segment failed.
fn appendContourSegments(context: *ContourContext, first_point_index: u32, point_count: u32) !void {
    const contour_size: usize = point_count;
    const contour_points = context.contour_points[first_point_index..][0..point_count];
    const contour_on_curve_flags = context.on_curve_flags[first_point_index..][0..point_count];

    var first_on_curve_position: ?usize = null;
    for (contour_points, 0..) |_, point_position| {
        if (contour_on_curve_flags[point_position]) {
            first_on_curve_position = point_position;
            break;
        }
    }

    if (first_on_curve_position == null) {
        if (contour_size == 2) {
            try flattenQuadratic(contour_points[0], contour_points[0], contour_points[1], context.tolerance, 20, context.output_segments, context.allocator);
            return;
        }
        var segment_start = midpoint(contour_points[contour_size - 1], contour_points[0]);
        var point_position: usize = 0;
        while (point_position < contour_size) : (point_position += 1) {
            const implied_on_curve_end = midpoint(contour_points[point_position], contour_points[(point_position + 1) % contour_size]);
            try flattenQuadratic(segment_start, contour_points[point_position], implied_on_curve_end, context.tolerance, 20, context.output_segments, context.allocator);
            segment_start = implied_on_curve_end;
        }
        return;
    }

    const rotation_offset = first_on_curve_position.?;
    var segment_start = contour_points[rotation_offset];
    var points_consumed: usize = 1;
    while (points_consumed <= contour_size) : (points_consumed += 1) {
        const current_point_index = (rotation_offset + points_consumed) % contour_size;
        if (contour_on_curve_flags[current_point_index]) {
            try appendLineSegment(context.output_segments, context.allocator, segment_start, contour_points[current_point_index]);
            segment_start = contour_points[current_point_index];
        } else {
            const next_point_index = (rotation_offset + points_consumed + 1) % contour_size;
            if (contour_on_curve_flags[next_point_index]) {
                try flattenQuadratic(segment_start, contour_points[current_point_index], contour_points[next_point_index], context.tolerance, 20, context.output_segments, context.allocator);
                segment_start = contour_points[next_point_index];
                points_consumed += 1;
            } else {
                const implied_on_curve_point = midpoint(contour_points[current_point_index], contour_points[next_point_index]);
                try flattenQuadratic(segment_start, contour_points[current_point_index], implied_on_curve_point, context.tolerance, 20, context.output_segments, context.allocator);
                segment_start = implied_on_curve_point;
            }
        }
    }
}

/// Returns the point exactly halfway between two points.
///
/// Parameters:
///     `first_point`: First input point.
///     `second_point`: Second input point.
///
/// Returns:
///     The midpoint `(a + b) / 2`.
fn midpoint(first_point: Point, second_point: Point) Point {
    return .{ .x = (first_point.x + second_point.x) * 0.5, .y = (first_point.y + second_point.y) * 0.5 };
}

/// Appends one straight segment to the output list, skipping non-finite
/// coordinates produced by malformed fonts.
///
/// Parameters:
///     `output_segments`: Segment list to append to.
///     `allocator`: Allocator used for the append.
///     `start_point`: Segment start in device pixels.
///     `end_point`: Segment end in device pixels.
///
/// Errors:
///     error.OutOfMemory: Appending failed.
fn appendLineSegment(output_segments: *std.ArrayList(LineSegment), allocator: std.mem.Allocator, start_point: Point, end_point: Point) !void {
    if (!std.math.isFinite(start_point.x) or !std.math.isFinite(start_point.y) or !std.math.isFinite(end_point.x) or !std.math.isFinite(end_point.y)) return;
    try output_segments.append(allocator, .{
        .start_x = start_point.x,
        .start_y = start_point.y,
        .end_x = end_point.x,
        .end_y = end_point.y,
    });
}

/// Recursively flattens one quadratic Bézier into line segments.
///
/// The curve is subdivided at its midpoint until the control point lies
/// within `tolerance` of the chord (measured via the cross-product
/// criterion) or the depth budget is exhausted.
///
/// Parameters:
///     `start_point`: Curve start in device pixels.
///     `control_point`: Quadratic control point in device pixels.
///     `end_point`: Curve end in device pixels.
///     `tolerance`: Maximum curve-to-chord distance, in pixels.
///     `remaining_depth`: Subdivision budget left; zero forces emission of
///         the remaining chord.
///     `output_segments`: Segment list the flattened pieces are appended to.
///     `allocator`: Allocator used for the appends.
///
/// Errors:
///     error.OutOfMemory: Appending failed.
fn flattenQuadratic(
    start_point: Point,
    control_point: Point,
    end_point: Point,
    tolerance: f32,
    remaining_depth: u32,
    output_segments: *std.ArrayList(LineSegment),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const control_offset_x = control_point.x * 2 - start_point.x - end_point.x;
    const control_offset_y = control_point.y * 2 - start_point.y - end_point.y;
    if (remaining_depth == 0 or control_offset_x * control_offset_x + control_offset_y * control_offset_y <= 4 * tolerance * tolerance) {
        try appendLineSegment(output_segments, allocator, start_point, end_point);
        return;
    }
    const start_control_midpoint = midpoint(start_point, control_point);
    const control_end_midpoint = midpoint(control_point, end_point);
    const curve_midpoint = midpoint(start_control_midpoint, control_end_midpoint);
    try flattenQuadratic(start_point, start_control_midpoint, curve_midpoint, tolerance, remaining_depth - 1, output_segments, allocator);
    try flattenQuadratic(curve_midpoint, control_end_midpoint, end_point, tolerance, remaining_depth - 1, output_segments, allocator);
}

/// Per-cell signed coverage deposits for the whole bitmap.
///
/// One extra column is allocated so pieces that end exactly on the right
/// bitmap border still have a valid column index.
const CoverageAccumulator = struct {
    /// Width of the bitmap the cells belong to.
    bitmap_width: u32,
    /// Signed vertical mass per cell: `winding_sign * piece_height`.
    cover_sums: []f32,
    /// Signed trapezoid area per cell: `winding_sign * x_mid * piece_height`.
    area_sums: []f32,
};

/// Rasterizes flattened segments into a bitmap.
///
/// Deposits every segment's exact trapezoid contributions into a cell grid,
/// then sweeps each row left to right: the running cover sum plus the
/// per-cell formula `|(c+1) * cover - area|` yields the anti-aliased
/// coverage of each pixel, which is max-blended into the bitmap.
///
/// Parameters:
///     `allocator`: Allocator for the cell grid.
///     `bitmap`: Destination bitmap; existing pixels act as a floor because
///         the blend is max-based.
///     `segments`: Flattened line segments in device pixel space.
///
/// Errors:
///     error.OutOfMemory: Allocating the cell grid failed.
fn rasterizeSegments(allocator: std.mem.Allocator, bitmap: *const Bitmap, segments: []const LineSegment) error{OutOfMemory}!void {
    const bitmap_height: usize = bitmap.height;
    const bitmap_width: usize = bitmap.width;
    if (bitmap_height == 0 or bitmap_width == 0) return;

    const cell_stride = bitmap_width + 1;
    var accumulator = CoverageAccumulator{
        .bitmap_width = @intCast(bitmap_width),
        .cover_sums = allocator.alloc(f32, bitmap_height * cell_stride) catch return error.OutOfMemory,
        .area_sums = allocator.alloc(f32, bitmap_height * cell_stride) catch return error.OutOfMemory,
    };
    defer allocator.free(accumulator.cover_sums);
    defer allocator.free(accumulator.area_sums);
    @memset(accumulator.cover_sums, 0);
    @memset(accumulator.area_sums, 0);

    for (segments) |segment| {
        accumulateSegment(&accumulator, bitmap_height, segment.start_x, segment.start_y, segment.end_x, segment.end_y);
    }

    var row_index: usize = 0;
    while (row_index < bitmap_height) : (row_index += 1) {
        var running_cover_sum: f32 = 0;
        const row_offset = row_index * cell_stride;
        const destination_pixel_row = bitmap.data[row_index * bitmap.stride ..][0..bitmap_width];
        for (destination_pixel_row, 0..) |*pixel, column_index| {
            const cell_cover = accumulator.cover_sums[row_offset + column_index];
            const cell_area = accumulator.area_sums[row_offset + column_index];
            const coverage_value = @abs(running_cover_sum + (@as(f32, @floatFromInt(column_index)) + 1.0) * cell_cover - cell_area);
            if (coverage_value > 0.0005) {
                const scaled_alpha: f32 = coverage_value * 255.0 + 0.5;
                const alpha_byte: u8 = if (scaled_alpha >= 255.0) 255 else @intFromFloat(scaled_alpha);
                if (alpha_byte > pixel.*) pixel.* = alpha_byte;
            }
            running_cover_sum += cell_cover;
        }
    }
}

/// Deposits one segment's trapezoid contributions into the cell grid.
///
/// The segment is oriented so it points downward (its winding sign becomes
/// negative), clipped vertically to the bitmap and split at every integer
/// row boundary so each row piece lies inside exactly one cell row.
///
/// Parameters:
///     `accumulator`: Cell grid receiving the deposits.
///     `bitmap_height`: Height of the bitmap, used for vertical clipping.
///     `segment_start_x`: Horizontal position of the segment start, in pixels.
///     `segment_start_y`: Vertical position of the segment start, in pixels.
///     `segment_end_x`: Horizontal position of the segment end, in pixels.
///     `segment_end_y`: Vertical position of the segment end, in pixels.
fn accumulateSegment(
    accumulator: *CoverageAccumulator,
    bitmap_height: usize,
    segment_start_x: f32,
    segment_start_y: f32,
    segment_end_x: f32,
    segment_end_y: f32,
) void {
    if (!std.math.isFinite(segment_start_x) or !std.math.isFinite(segment_start_y) or !std.math.isFinite(segment_end_x) or !std.math.isFinite(segment_end_y)) return;
    if (segment_start_y == segment_end_y) return;

    var x_start = segment_start_x;
    var y_start = segment_start_y;
    var x_end = segment_end_x;
    var y_end = segment_end_y;
    var winding_sign: f32 = -1;
    if (y_start > y_end) {
        std.mem.swap(f32, &x_start, &x_end);
        std.mem.swap(f32, &y_start, &y_end);
        winding_sign = 1;
    }

    const bitmap_height_float: f32 = @floatFromInt(bitmap_height);
    if (y_end <= 0 or y_start >= bitmap_height_float) return;
    if (y_start < 0) {
        const clip_ratio = (0 - y_start) / (y_end - y_start);
        x_start = x_start + (x_end - x_start) * clip_ratio;
        y_start = 0;
    }
    if (y_end > bitmap_height_float) {
        const clip_ratio = (bitmap_height_float - y_start) / (y_end - y_start);
        x_end = x_start + (x_end - x_start) * clip_ratio;
        y_end = bitmap_height_float;
    }

    var row_piece_start_x = x_start;
    var row_piece_start_y = y_start;
    var row_split_y = @ceil(y_start);
    while (row_split_y < y_end - 1e-6) : (row_split_y += 1) {
        if (row_split_y - row_piece_start_y > 1e-9) {
            const split_ratio = (row_split_y - row_piece_start_y) / (y_end - row_piece_start_y);
            const row_split_x = row_piece_start_x + (x_end - row_piece_start_x) * split_ratio;
            accumulateRowPiece(accumulator, row_piece_start_x, row_split_x, row_piece_start_y, row_split_y, winding_sign);
            row_piece_start_x = row_split_x;
            row_piece_start_y = row_split_y;
        }
    }
    accumulateRowPiece(accumulator, row_piece_start_x, x_end, row_piece_start_y, y_end, winding_sign);
}

/// Deposits one row piece's contributions, splitting it at every integer
/// column boundary.
///
/// The piece is oriented left to right (swapping the y endpoints together
/// with the x endpoints when needed), clipped horizontally to the bitmap and
/// parametrically split at each column border so every cell piece carries its
/// true vertical extent.
///
/// Parameters:
///     `accumulator`: Cell grid receiving the deposits.
///     `piece_x_start`: Horizontal position of the piece start, in pixels.
///     `piece_x_end`: Horizontal position of the piece end, in pixels.
///     `piece_y_start`: Vertical position of the piece start, in pixels.
///     `piece_y_end`: Vertical position of the piece end, in pixels.
///     `winding_sign`: Signed multiplier applied to every deposit; `-1` for
///         downward edges and `+1` for upward edges.
fn accumulateRowPiece(
    accumulator: *CoverageAccumulator,
    piece_x_start: f32,
    piece_x_end: f32,
    piece_y_start: f32,
    piece_y_end: f32,
    winding_sign: f32,
) void {
    if (piece_y_end - piece_y_start <= 1e-9) return;
    const row_index_signed: i64 = @intFromFloat(@floor(piece_y_start));
    if (row_index_signed < 0) return;
    const row_index: usize = @intCast(row_index_signed);

    var segment_left_x = piece_x_start;
    var segment_right_x = piece_x_end;
    var y_at_left_x = piece_y_start;
    var y_at_right_x = piece_y_end;
    if (segment_left_x > segment_right_x) {
        std.mem.swap(f32, &segment_left_x, &segment_right_x);
        std.mem.swap(f32, &y_at_left_x, &y_at_right_x);
    }

    const bitmap_width_float: f32 = @floatFromInt(accumulator.bitmap_width);
    if (segment_right_x <= 0 or segment_left_x >= bitmap_width_float) return;
    if (segment_left_x < 0) {
        const clip_ratio = (0 - segment_left_x) / (segment_right_x - segment_left_x);
        y_at_left_x = y_at_left_x + (y_at_right_x - y_at_left_x) * clip_ratio;
        segment_left_x = 0;
    }
    if (segment_right_x > bitmap_width_float) {
        const clip_ratio = (bitmap_width_float - segment_left_x) / (segment_right_x - segment_left_x);
        y_at_right_x = y_at_left_x + (y_at_right_x - y_at_left_x) * clip_ratio;
        segment_right_x = bitmap_width_float;
    }
    if (segment_right_x - segment_left_x <= 1e-9 and y_at_right_x - y_at_left_x <= 1e-9) return;

    const row_offset = row_index * (@as(usize, accumulator.bitmap_width) + 1);
    var cell_x_start = segment_left_x;
    var cell_y_start = y_at_left_x;
    var column_split_x = @ceil(segment_left_x);
    while (column_split_x < segment_right_x - 1e-6) : (column_split_x += 1) {
        if (column_split_x - cell_x_start > 1e-9) {
            const split_ratio = (column_split_x - cell_x_start) / (segment_right_x - cell_x_start);
            const cell_y_end = cell_y_start + (y_at_right_x - cell_y_start) * split_ratio;
            accumulateCellPiece(accumulator, row_offset, cell_x_start, column_split_x, cell_y_start, cell_y_end, winding_sign);
            cell_x_start = column_split_x;
            cell_y_start = cell_y_end;
        }
    }
    accumulateCellPiece(accumulator, row_offset, cell_x_start, segment_right_x, cell_y_start, y_at_right_x, winding_sign);
}

/// Deposits one cell piece's exact trapezoid contribution.
///
/// A zero-width piece (vertical edge fragment) still deposits its full
/// height; a zero-height piece deposits nothing.
///
/// Parameters:
///     `accumulator`: Cell grid receiving the deposit.
///     `row_offset`: Start index of the piece's row inside the cell arrays.
///     `piece_x_start`: Horizontal position of the piece start, in pixels.
///     `piece_x_end`: Horizontal position of the piece end, in pixels.
///     `piece_y_start`: Vertical position of the piece start, in pixels.
///     `piece_y_end`: Vertical position of the piece end, in pixels.
///     `winding_sign`: Signed multiplier applied to the deposit.
fn accumulateCellPiece(
    accumulator: *CoverageAccumulator,
    row_offset: usize,
    piece_x_start: f32,
    piece_x_end: f32,
    piece_y_start: f32,
    piece_y_end: f32,
    winding_sign: f32,
) void {
    const piece_height = @abs(piece_y_end - piece_y_start);
    if (piece_height <= 1e-9 and piece_x_end - piece_x_start <= 1e-9) return;
    const column_index_signed: i64 = @intFromFloat(@floor(piece_x_start));
    if (column_index_signed < 0 or column_index_signed > @as(i64, @intCast(accumulator.bitmap_width))) return;
    const column_index: usize = @intCast(column_index_signed);
    const cell_index = row_offset + column_index;
    accumulator.cover_sums[cell_index] += winding_sign * piece_height;
    accumulator.area_sums[cell_index] += winding_sign * (piece_x_start + piece_x_end) * 0.5 * piece_height;
}
