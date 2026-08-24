//! Integration tests for the font library.
//!
//! The centerpiece is `buildFont`: it assembles a complete, valid TrueType
//! font byte-by-byte in memory (table directory, `head`, `hhea`, `maxp`,
//! `hmtx`, `cmap` format 4, `loca` long format, `glyf` with a simple triangle
//! glyph plus a scaled composite glyph, and a `kern` table). This makes every
//! stage of the pipeline — parsing, cmap lookup, outline decoding, kerning,
//! metrics and rasterization — verifiable without any external font file.

const std = @import("std");
const font_module = @import("font.zig");
const Font = font_module.Font;
const raster = @import("raster.zig");
const outline_module = @import("outline.zig");

/// Growable byte buffer used by the fixture builders.
const ByteList = std.ArrayList(u8);

/// Appends one unsigned 16-bit value in big-endian order to the buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to append to.
///     `allocator`: Allocator used for the append.
///     `value`: Unsigned 16-bit value to encode.
fn appendUInt16(buffer: *ByteList, allocator: std.mem.Allocator, value: u16) !void {
    var encoded_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded_bytes, value, .big);
    try buffer.appendSlice(allocator, &encoded_bytes);
}

/// Appends one signed 16-bit value in big-endian order to the buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to append to.
///     `allocator`: Allocator used for the append.
///     `value`: Signed 16-bit value to encode.
fn appendInt16(buffer: *ByteList, allocator: std.mem.Allocator, value: i16) !void {
    try appendUInt16(buffer, allocator, @bitCast(value));
}

/// Appends one unsigned 32-bit value in big-endian order to the buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to append to.
///     `allocator`: Allocator used for the append.
///     `value`: Unsigned 32-bit value to encode.
fn appendUInt32(buffer: *ByteList, allocator: std.mem.Allocator, value: u32) !void {
    var encoded_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_bytes, value, .big);
    try buffer.appendSlice(allocator, &encoded_bytes);
}

/// Appends one signed 32-bit value in big-endian order to the buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to append to.
///     `allocator`: Allocator used for the append.
///     `value`: Signed 32-bit value to encode.
fn appendInt32(buffer: *ByteList, allocator: std.mem.Allocator, value: i32) !void {
    try appendUInt32(buffer, allocator, @bitCast(value));
}

/// Appends a single byte to the buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to append to.
///     `allocator`: Allocator used for the append.
///     `value`: Byte value to append.
fn appendByte(buffer: *ByteList, allocator: std.mem.Allocator, value: u8) !void {
    try buffer.append(allocator, value);
}

/// Pads the buffer with zero bytes until its length is a multiple of four.
///
/// Parameters:
///     `buffer`: Buffer to pad in place.
///     `allocator`: Allocator used for the appended padding bytes.
fn padToFourByteAlignment(buffer: *ByteList, allocator: std.mem.Allocator) !void {
    while (buffer.items.len % 4 != 0) try buffer.append(allocator, 0);
}

/// One entry of the sfnt table directory being assembled.
const TableEntry = struct {
    /// Four-character table tag, for example "head".
    tag: *const [4]u8,
    /// Complete raw bytes of the table.
    data: []const u8,
};

/// Assembles a complete font file from a set of built tables.
///
/// Writes the sfnt header, the sorted table directory with computed offsets,
/// then every table padded to a four-byte boundary. Checksums are left at
/// zero because the library does not verify them.
///
/// Parameters:
///     `allocator`: Allocator for the output bytes and the offset table.
///     `input_table_entries`: Table entries to embed; the array is sorted in
///         place by tag.
///
/// Returns:
///     Caller-owned bytes of the complete font file.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
fn assembleFont(allocator: std.mem.Allocator, input_table_entries: []TableEntry) ![]u8 {
    std.mem.sort(TableEntry, input_table_entries, {}, struct {
        fn lessThan(_: void, first_entry: TableEntry, second_entry: TableEntry) bool {
            return std.mem.lessThan(u8, first_entry.tag, second_entry.tag);
        }
    }.lessThan);

    var font_bytes: ByteList = .empty;
    errdefer font_bytes.deinit(allocator);

    const table_directory_size = 12 + input_table_entries.len * 16;
    var current_offset: u32 = @intCast(table_directory_size);
    const table_offsets = try allocator.alloc(u32, input_table_entries.len);
    defer allocator.free(table_offsets);

    for (input_table_entries, 0..) |table_entry, entry_index| {
        table_offsets[entry_index] = current_offset;
        current_offset += @intCast(table_entry.data.len);
        current_offset = (current_offset + 3) & ~@as(u32, 3);
    }

    try appendUInt32(&font_bytes, allocator, 0x00010000);
    try appendUInt16(&font_bytes, allocator, @intCast(input_table_entries.len));
    try appendUInt16(&font_bytes, allocator, 0);
    try appendUInt16(&font_bytes, allocator, 0);
    try appendUInt16(&font_bytes, allocator, 0);

    for (input_table_entries, 0..) |table_entry, entry_index| {
        try font_bytes.appendSlice(allocator, table_entry.tag);
        try appendUInt32(&font_bytes, allocator, 0);
        try appendUInt32(&font_bytes, allocator, table_offsets[entry_index]);
        try appendUInt32(&font_bytes, allocator, @intCast(table_entry.data.len));
    }
    while (font_bytes.items.len < table_directory_size) try font_bytes.append(allocator, 0);

    for (input_table_entries) |table_entry| {
        try font_bytes.appendSlice(allocator, table_entry.data);
        while (font_bytes.items.len % 4 != 0) try font_bytes.append(allocator, 0);
    }

    return font_bytes.toOwnedSlice(allocator);
}

/// Builds the synthetic test font used by every integration test.
///
/// The font declares three glyphs with an em square of 1024 units:
/// glyph 0 is empty (`.notdef`), glyph 1 is a triangle with corners
/// (0,0), (400,700), (700,0), and glyph 2 is a composite that places a
/// half-scaled copy of glyph 1 at offset (200,0). The `cmap` maps 'A' to
/// glyph 1 and 'B' to glyph 2, and `kern` defines a pair (1,1) worth -50
/// font units.
///
/// Parameters:
///     `allocator`: Allocator for every temporary table buffer and the
///         assembled result.
///
/// Returns:
///     Caller-owned bytes of the complete synthetic font.
///
/// Errors:
///     error.OutOfMemory: Allocation failed.
pub fn buildFont(allocator: std.mem.Allocator) ![]u8 {
    var head_table: ByteList = .empty;
    defer head_table.deinit(allocator);
    try appendUInt32(&head_table, allocator, 0x00010000);
    try appendUInt32(&head_table, allocator, 0x00010000);
    try appendUInt32(&head_table, allocator, 0);
    try appendUInt32(&head_table, allocator, 0x5F0F3CF5);
    try appendUInt16(&head_table, allocator, 0);
    try appendUInt16(&head_table, allocator, 1024);
    try head_table.appendNTimes(allocator, 0, 16);
    try appendInt16(&head_table, allocator, 0);
    try appendInt16(&head_table, allocator, 0);
    try appendInt16(&head_table, allocator, 700);
    try appendInt16(&head_table, allocator, 700);
    try appendUInt16(&head_table, allocator, 0);
    try appendUInt16(&head_table, allocator, 8);
    try appendInt16(&head_table, allocator, 2);
    try appendInt16(&head_table, allocator, 1);
    try appendInt16(&head_table, allocator, 0);

    var hhea_table: ByteList = .empty;
    defer hhea_table.deinit(allocator);
    try appendUInt32(&hhea_table, allocator, 0x00010000);
    try appendInt16(&hhea_table, allocator, 800);
    try appendInt16(&hhea_table, allocator, -200);
    try appendInt16(&hhea_table, allocator, 10);
    try appendUInt16(&hhea_table, allocator, 700);
    try appendInt16(&hhea_table, allocator, 0);
    try appendInt16(&hhea_table, allocator, 0);
    try appendInt16(&hhea_table, allocator, 700);
    try appendInt16(&hhea_table, allocator, 1);
    try appendInt16(&hhea_table, allocator, 0);
    try appendInt16(&hhea_table, allocator, 0);
    try hhea_table.appendNTimes(allocator, 0, 8);
    try appendInt16(&hhea_table, allocator, 0);
    try appendUInt16(&hhea_table, allocator, 3);

    var maxp_table: ByteList = .empty;
    defer maxp_table.deinit(allocator);
    try appendUInt32(&maxp_table, allocator, 0x00010000);
    try appendUInt16(&maxp_table, allocator, 3);
    try maxp_table.appendNTimes(allocator, 0, 26);

    var hmtx_table: ByteList = .empty;
    defer hmtx_table.deinit(allocator);
    inline for (.{ 500, 700, 700 }) |advance_width| {
        try appendUInt16(&hmtx_table, allocator, advance_width);
        try appendInt16(&hmtx_table, allocator, 0);
    }

    var format4_subtable: ByteList = .empty;
    defer format4_subtable.deinit(allocator);
    try appendUInt16(&format4_subtable, allocator, 4);
    try appendUInt16(&format4_subtable, allocator, 40);
    try appendUInt16(&format4_subtable, allocator, 0);
    try appendUInt16(&format4_subtable, allocator, 6);
    try appendUInt16(&format4_subtable, allocator, 4);
    try appendUInt16(&format4_subtable, allocator, 1);
    try appendUInt16(&format4_subtable, allocator, 2);
    try appendUInt16(&format4_subtable, allocator, 0x41);
    try appendUInt16(&format4_subtable, allocator, 0x42);
    try appendUInt16(&format4_subtable, allocator, 0xFFFF);
    try appendUInt16(&format4_subtable, allocator, 0);
    try appendUInt16(&format4_subtable, allocator, 0x41);
    try appendUInt16(&format4_subtable, allocator, 0x42);
    try appendUInt16(&format4_subtable, allocator, 0xFFFF);
    try appendInt16(&format4_subtable, allocator, -64);
    try appendInt16(&format4_subtable, allocator, -64);
    try appendInt16(&format4_subtable, allocator, 1);
    try appendUInt16(&format4_subtable, allocator, 0);
    try appendUInt16(&format4_subtable, allocator, 0);
    try appendUInt16(&format4_subtable, allocator, 0);

    var cmap_table: ByteList = .empty;
    defer cmap_table.deinit(allocator);
    try appendUInt16(&cmap_table, allocator, 0);
    try appendUInt16(&cmap_table, allocator, 1);
    try appendUInt16(&cmap_table, allocator, 3);
    try appendUInt16(&cmap_table, allocator, 1);
    try appendUInt32(&cmap_table, allocator, 12);
    try cmap_table.appendSlice(allocator, format4_subtable.items);

    var glyf_table: ByteList = .empty;
    defer glyf_table.deinit(allocator);
    try appendInt16(&glyf_table, allocator, 1);
    try appendInt16(&glyf_table, allocator, 0);
    try appendInt16(&glyf_table, allocator, 0);
    try appendInt16(&glyf_table, allocator, 700);
    try appendInt16(&glyf_table, allocator, 700);
    try appendUInt16(&glyf_table, allocator, 2);
    try appendUInt16(&glyf_table, allocator, 0);
    try appendByte(&glyf_table, allocator, 0x01);
    try appendByte(&glyf_table, allocator, 0x01);
    try appendByte(&glyf_table, allocator, 0x01);
    try appendInt16(&glyf_table, allocator, 0);
    try appendInt16(&glyf_table, allocator, 400);
    try appendInt16(&glyf_table, allocator, 300);
    try appendInt16(&glyf_table, allocator, 0);
    try appendInt16(&glyf_table, allocator, 700);
    try appendInt16(&glyf_table, allocator, -700);
    const triangle_glyph_byte_length = glyf_table.items.len;

    try appendInt16(&glyf_table, allocator, -1);
    try appendInt16(&glyf_table, allocator, 200);
    try appendInt16(&glyf_table, allocator, 0);
    try appendInt16(&glyf_table, allocator, 550);
    try appendInt16(&glyf_table, allocator, 350);
    try appendUInt16(&glyf_table, allocator, 0x000B);
    try appendUInt16(&glyf_table, allocator, 1);
    try appendInt16(&glyf_table, allocator, 200);
    try appendInt16(&glyf_table, allocator, 0);
    try appendUInt16(&glyf_table, allocator, 0x2000);

    var loca_table: ByteList = .empty;
    defer loca_table.deinit(allocator);
    try appendUInt32(&loca_table, allocator, 0);
    try appendUInt32(&loca_table, allocator, 0);
    try appendUInt32(&loca_table, allocator, @intCast(triangle_glyph_byte_length));
    try appendUInt32(&loca_table, allocator, @intCast(glyf_table.items.len));

    var kern_table: ByteList = .empty;
    defer kern_table.deinit(allocator);
    try appendUInt16(&kern_table, allocator, 0);
    try appendUInt16(&kern_table, allocator, 1);
    try appendUInt16(&kern_table, allocator, 0);
    try appendUInt16(&kern_table, allocator, 20);
    try appendUInt16(&kern_table, allocator, 0x0001);
    try appendUInt16(&kern_table, allocator, 1);
    try appendUInt16(&kern_table, allocator, 0);
    try appendUInt16(&kern_table, allocator, 0);
    try appendUInt16(&kern_table, allocator, 0);
    try appendUInt16(&kern_table, allocator, 1);
    try appendUInt16(&kern_table, allocator, 1);
    try appendInt16(&kern_table, allocator, -50);

    var table_entries = [_]TableEntry{
        .{ .tag = "cmap", .data = cmap_table.items },
        .{ .tag = "glyf", .data = glyf_table.items },
        .{ .tag = "head", .data = head_table.items },
        .{ .tag = "hhea", .data = hhea_table.items },
        .{ .tag = "hmtx", .data = hmtx_table.items },
        .{ .tag = "kern", .data = kern_table.items },
        .{ .tag = "loca", .data = loca_table.items },
        .{ .tag = "maxp", .data = maxp_table.items },
    };
    return assembleFont(allocator, &table_entries);
}

// Verifies font parsing, cmap lookups, glyph metrics for the simple and the
// composite glyph, and the kerning pair of the synthetic test font.
test "synthetic font parse and lookup" {
    const allocator = std.testing.allocator;
    const font_data = try buildFont(allocator);
    defer allocator.free(font_data);

    var typeface = try Font.init(font_data);
    try std.testing.expectEqual(@as(f32, 1024), typeface.units_per_em);
    try std.testing.expectEqual(@as(u16, 1), typeface.glyphIndexForCodepoint('A'));
    try std.testing.expectEqual(@as(u16, 2), typeface.glyphIndexForCodepoint('B'));
    try std.testing.expectEqual(@as(u16, 0), typeface.glyphIndexForCodepoint('C'));

    const pixel_scale = typeface.scaleForPixelSize(128);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), pixel_scale, 0.0001);

    const triangle_glyph_metrics = typeface.glyphMetrics(allocator, 1, pixel_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 87.5), triangle_glyph_metrics.advance_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 87.5), triangle_glyph_metrics.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 87.5), triangle_glyph_metrics.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 87.5), triangle_glyph_metrics.bearing_y, 0.001);

    const composite_glyph_metrics = typeface.glyphMetrics(allocator, 2, pixel_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 43.75), composite_glyph_metrics.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 43.75), composite_glyph_metrics.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), composite_glyph_metrics.bearing_x, 0.001);

    try std.testing.expectApproxEqAbs(@as(f32, -50), typeface.kerningInFontUnits(1, 1), 0.001);
}

// Verifies glyph and text rendering of the synthetic font: a known pixel
// inside the triangle must be nearly opaque, the corners transparent, and
// both single-glyph and text rendering must produce a plausible amount of
// lit pixels. Also checks the measured text width including kerning.
test "synthetic font rendering" {
    const allocator = std.testing.allocator;
    const font_data = try buildFont(allocator);
    defer allocator.free(font_data);

    var typeface = try Font.init(font_data);
    const pixel_scale = typeface.scaleForPixelSize(128);

    var pixels: [100 * 100]u8 = undefined;
    const bitmap = raster.Bitmap.init(100, 100, &pixels);
    bitmap.clear(0);

    try typeface.renderGlyph(allocator, 1, pixel_scale, &bitmap, 6, 94);

    try std.testing.expect(pixels[64 * 100 + 51] >= 200);
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), pixels[99 * 100 + 99]);

    var lit_pixel_count: usize = 0;
    for (pixels) |coverage_value| {
        if (coverage_value > 127) lit_pixel_count += 1;
    }
    try std.testing.expect(lit_pixel_count > 800);

    const measured_text_metrics = typeface.measureText("AA", pixel_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 168.75), measured_text_metrics.width, 0.01);

    var text_pixels: [100 * 40]u8 = undefined;
    const text_bitmap = raster.Bitmap.init(100, 40, &text_pixels);
    text_bitmap.clear(0);
    try typeface.renderText(allocator, "AB", pixel_scale, &text_bitmap, 4, 36);
    var text_lit_pixel_count: usize = 0;
    for (text_pixels) |coverage_value| {
        if (coverage_value > 127) text_lit_pixel_count += 1;
    }
    try std.testing.expect(text_lit_pixel_count > 1200);
}

// Verifies that truncated font files are rejected with `error.InvalidFont`
// instead of crashing or being accepted.
test "truncated font rejected" {
    const allocator = std.testing.allocator;
    const font_data = try buildFont(allocator);
    defer allocator.free(font_data);
    try std.testing.expectError(error.InvalidFont, Font.init(font_data[0..40]));
    try std.testing.expectError(error.InvalidFont, Font.init(font_data[0..8]));
}

// Verifies exact rasterizer output on an axis-aligned rectangle: the center
// must be fully covered, the outside untouched, and the count of fully
// covered pixels must stay within the tolerance band around the rectangle
// area (allowing for anti-aliased borders).
test "rectangle rasterization exact coverage" {
    var pixels: [24 * 24]u8 = undefined;
    const bitmap = raster.Bitmap.init(24, 24, &pixels);
    bitmap.clear(0);

    const rectangle_points = [_]outline_module.Point{
        .{ .x = 3.2, .y = 3.7 },
        .{ .x = 19.8, .y = 3.7 },
        .{ .x = 19.8, .y = 17.3 },
        .{ .x = 3.2, .y = 17.3 },
    };
    const rectangle_on_curve_flags = [_]bool{ true, true, true, true };
    const rectangle_contour_spans = [_]outline_module.ContourSpan{.{ .first_point_index = 0, .point_count = 4 }};

    try raster.renderShape(std.testing.allocator, &bitmap, &rectangle_points, &rectangle_on_curve_flags, &rectangle_contour_spans, 0.2);

    try std.testing.expectEqual(@as(u8, 255), pixels[10 * 24 + 10]);
    try std.testing.expectEqual(@as(u8, 0), pixels[1 * 24 + 1]);
    try std.testing.expectEqual(@as(u8, 0), pixels[22 * 24 + 22]);

    const inner_width = 19 - 5 + 1;
    const inner_height = 17 - 5 + 1;
    var fully_covered_pixel_count: usize = 0;
    for (pixels) |coverage_value| {
        if (coverage_value >= 250) fully_covered_pixel_count += 1;
    }
    try std.testing.expect(fully_covered_pixel_count <= inner_width * inner_height + inner_width + inner_height + 8);
    try std.testing.expect(fully_covered_pixel_count >= inner_width * inner_height - inner_width - inner_height - 8);
}
