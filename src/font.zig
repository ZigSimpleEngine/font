//! Public facade of the font rendering library.
//!
//! `Font` ties together table parsing, character mapping, kerning and
//! rasterization behind a small API: load once from a byte slice, then query
//! glyph indices, metrics and draw glyphs or whole UTF-8 strings into an
//! 8-bit coverage bitmap. The font data is borrowed, never copied.

const std = @import("std");
const read_module = @import("read.zig");
const sfnt_module = @import("sfnt.zig");
const cmap_module = @import("cmap.zig");
const kern_module = @import("kern.zig");
const outline_module = @import("outline.zig");
const raster_module = @import("raster.zig");

/// 8-bit coverage bitmap type re-exported for library users.
pub const Bitmap = raster_module.Bitmap;

/// A loaded TrueType font ready for glyph queries and rendering.
///
/// All data is borrowed from the byte slice passed to `init`; that slice must
/// remain valid and unmodified for as long as the font is used. The font
/// itself needs no allocation and holds no mutable state, so a single
/// instance can be shared freely.
pub const Font = struct {
    /// Parsed sfnt table set pointing into the original font data.
    tables: sfnt_module.FontTables,
    /// Selected character to glyph mapping subtable, if the font has a `cmap`.
    character_map: ?cmap_module.CharacterMap,
    /// Selected legacy kerning subtable, if the font has a `kern` table.
    kerning_subtable: ?kern_module.KerningSubtable,
    /// Design-space size of the em square in font units.
    units_per_em: f32,
    /// Typographic ascender in font units (positive above the baseline).
    ascender_units: f32,
    /// Typographic descender in font units (usually negative).
    descender_units: f32,
    /// Recommended extra spacing between consecutive text lines, in font units.
    line_gap_units: f32,

    /// Error set produced by `init`.
    pub const InitError = sfnt_module.ParseError || read_module.ReadError;

    /// Parses a TrueType font file and prepares it for rendering.
    ///
    /// No allocation is performed; the font only stores slices into
    /// `font_file_data`.
    ///
    /// Parameters:
    ///     `font_file_data`: Raw bytes of the whole font file. Borrowed, must
    ///         outlive the returned font.
    ///
    /// Returns:
    ///     A ready-to-use font instance.
    ///
    /// Errors:
    ///     error.InvalidFont: The sfnt container is malformed.
    ///     error.MissingHead / error.MissingHhea / error.MissingMaxp /
    ///     error.MissingHmtx / error.MissingTable: A required table is absent
    ///         or truncated.
    ///     error.OutOfBounds: The file ends inside the table directory.
    pub fn init(font_file_data: []const u8) InitError!Font {
        const parsed_tables = sfnt_module.FontTables.parse(font_file_data) catch return error.InvalidFont;
        return .{
            .tables = parsed_tables,
            .character_map = if (parsed_tables.cmap) |cmap_table| cmap_module.CharacterMap.selectBestSubtable(cmap_table) else null,
            .kerning_subtable = if (parsed_tables.kern) |kern_table| kern_module.KerningSubtable.selectFormatZeroSubtable(kern_table) else null,
            .units_per_em = parsed_tables.unitsPerEm(),
            .ascender_units = @floatFromInt(parsed_tables.ascender()),
            .descender_units = @floatFromInt(parsed_tables.descender()),
            .line_gap_units = @floatFromInt(parsed_tables.lineGap()),
        };
    }

    /// Returns the total number of glyphs declared by the font.
    ///
    /// Returns:
    ///     Glyph count; valid glyph ids are `0 .. glyphCount() - 1`.
    pub fn glyphCount(self: *const Font) u16 {
        return self.tables.glyphCount();
    }

    /// Converts a requested em size in pixels into a scale factor.
    ///
    /// Multiply any font-unit value by the returned factor to obtain pixels.
    ///
    /// Parameters:
    ///     `pixel_size`: Desired size of the em square, in pixels.
    ///
    /// Returns:
    ///     Scale factor `pixel_size / units_per_em`, or 0 for a broken font.
    pub fn scaleForPixelSize(self: *const Font, pixel_size: f32) f32 {
        if (self.units_per_em == 0) return 0;
        return pixel_size / self.units_per_em;
    }

    /// Returns the recommended distance between consecutive text baselines.
    ///
    /// Parameters:
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Line height in pixels: `(ascender - descender + line_gap) * scale`.
    pub fn lineHeightPixels(self: *const Font, pixel_scale: f32) f32 {
        return (self.ascender_units - self.descender_units + self.line_gap_units) * pixel_scale;
    }

    /// Returns the distance from the baseline to the top of the line.
    ///
    /// Parameters:
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Ascender height in pixels.
    pub fn ascentPixels(self: *const Font, pixel_scale: f32) f32 {
        return self.ascender_units * pixel_scale;
    }

    /// Returns the distance from the baseline to the bottom of the line.
    ///
    /// Parameters:
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Descender depth in pixels (usually negative).
    pub fn descentPixels(self: *const Font, pixel_scale: f32) f32 {
        return self.descender_units * pixel_scale;
    }

    /// Translates a Unicode codepoint into a glyph index.
    ///
    /// Parameters:
    ///     `codepoint`: Unicode scalar value to look up.
    ///
    /// Returns:
    ///     Glyph index, or 0 (`.notdef`) when the font has no `cmap` or the
    ///     codepoint is unmapped.
    pub fn glyphIndexForCodepoint(self: *const Font, codepoint: u21) u16 {
        const character_map = self.character_map orelse return 0;
        return character_map.glyphIndexForCodepoint(codepoint);
    }

    /// Returns the kerning adjustment between two glyphs.
    ///
    /// Parameters:
    ///     `left_glyph_id`: Glyph index drawn first.
    ///     `right_glyph_id`: Glyph index drawn immediately afterwards.
    ///
    /// Returns:
    ///     Kerning offset in font units to add to the pen advance, or 0 when
    ///     the font has no `kern` table or the pair is not kerned.
    pub fn kerningInFontUnits(self: *const Font, left_glyph_id: u16, right_glyph_id: u16) f32 {
        const kerning_subtable = self.kerning_subtable orelse return 0;
        return @floatFromInt(kerning_subtable.kerningValue(left_glyph_id, right_glyph_id));
    }

    /// Returns the horizontal advance of one glyph.
    ///
    /// Parameters:
    ///     `glyph_id`: Index of the glyph to query.
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Distance the pen moves forward after drawing the glyph, in pixels.
    pub fn advanceWidthPixels(self: *const Font, glyph_id: u16, pixel_scale: f32) f32 {
        return @as(f32, @floatFromInt(self.tables.advanceWidthOfGlyph(glyph_id))) * pixel_scale;
    }

    /// Scaled bounding box and advance of one glyph, in pixels.
    pub const GlyphMetrics = struct {
        /// Distance the pen moves forward after drawing the glyph.
        advance_width: f32 = 0,
        /// Width of the ink bounding box (zero for empty glyphs).
        width: f32 = 0,
        /// Height of the ink bounding box (zero for empty glyphs).
        height: f32 = 0,
        /// Horizontal distance from the pen position to the left edge of the
        /// ink box.
        bearing_x: f32 = 0,
        /// Vertical distance from the baseline to the top of the ink box.
        bearing_y: f32 = 0,
    };

    /// Measures one glyph at a given scale.
    ///
    /// The outline is decoded only to compute the bounding box; for empty
    /// glyphs (such as a space) all ink fields are zero and only
    /// `advance_width` is meaningful.
    ///
    /// Parameters:
    ///     `allocator`: Temporary allocator used while decoding the outline.
    ///     `glyph_id`: Index of the glyph to measure.
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Scaled metrics of the glyph.
    pub fn glyphMetrics(
        self: *const Font,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        pixel_scale: f32,
    ) GlyphMetrics {
        var metrics = GlyphMetrics{
            .advance_width = self.advanceWidthPixels(glyph_id, pixel_scale),
        };
        var glyph_outline = outline_module.decode(allocator, &self.tables, glyph_id) catch return metrics;
        defer glyph_outline.deinit();
        if (glyph_outline.is_empty) return metrics;
        metrics.width = (glyph_outline.max_x - glyph_outline.min_x) * pixel_scale;
        metrics.height = (glyph_outline.max_y - glyph_outline.min_y) * pixel_scale;
        metrics.bearing_x = glyph_outline.min_x * pixel_scale;
        metrics.bearing_y = glyph_outline.max_y * pixel_scale;
        return metrics;
    }

    /// Error set produced by rendering functions.
    pub const RenderError = raster_module.RenderError;

    /// Renders one glyph into a bitmap using pen-position placement.
    ///
    /// The glyph is drawn as if the pen were at `(pen_x, pen_baseline_y)` on
    /// the baseline: bearings place the ink relative to that point. Coverage
    /// is max-blended into the bitmap, preserving existing content. Empty
    /// glyphs and glyphs outside the bitmap are silently skipped.
    ///
    /// Parameters:
    ///     `allocator`: Temporary allocator used while decoding the outline.
    ///     `glyph_id`: Index of the glyph to render.
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///     `destination_bitmap`: Coverage bitmap drawn into.
    ///     `pen_x`: Horizontal pen position, in pixels.
    ///     `pen_baseline_y`: Vertical position of the baseline, in pixels.
    ///
    /// Errors:
    ///     error.OutOfMemory: Allocation failed.
    pub fn renderGlyph(
        self: *const Font,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        pixel_scale: f32,
        destination_bitmap: *const Bitmap,
        pen_x: f32,
        pen_baseline_y: f32,
    ) RenderError!void {
        var glyph_outline = outline_module.decode(allocator, &self.tables, glyph_id) catch return error.OutOfMemory;
        defer glyph_outline.deinit();
        if (glyph_outline.is_empty) return;

        const device_space_points = allocator.alloc(outline_module.Point, glyph_outline.points.len) catch return error.OutOfMemory;
        defer allocator.free(device_space_points);
        for (glyph_outline.points, 0..) |font_space_point, point_index| {
            device_space_points[point_index] = .{
                .x = pen_x + font_space_point.x * pixel_scale,
                .y = pen_baseline_y - font_space_point.y * pixel_scale,
            };
        }
        try raster_module.renderShape(allocator, destination_bitmap, device_space_points, glyph_outline.on_curve_flags, glyph_outline.contours, raster_module.default_tolerance);
    }

    /// Measured extents of a whole text run.
    pub const TextMetrics = struct {
        /// Width of the widest line, in pixels.
        width: f32 = 0,
        /// Total height: line count times `lineHeightPixels`, in pixels.
        height: f32 = 0,
    };

    /// Measures a UTF-8 text run without drawing anything.
    ///
    /// Handles kerning and line breaks exactly like `renderText`, so the
    /// result can be used to size a bitmap for drawing.
    ///
    /// Parameters:
    ///     `utf8_text`: Text to measure. Invalid bytes decode as U+FFFD.
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///
    /// Returns:
    ///     Width of the widest line and total height of the run, in pixels.
    pub fn measureText(self: *const Font, utf8_text: []const u8, pixel_scale: f32) TextMetrics {
        var utf8_iterator = Utf8Iterator{ .bytes = utf8_text };
        var pen_x: f32 = 0;
        var widest_line_width: f32 = 0;
        var line_count: u32 = 1;
        var previous_glyph_id: ?u16 = null;
        while (utf8_iterator.next()) |codepoint| {
            if (codepoint == '\n') {
                widest_line_width = @max(widest_line_width, pen_x);
                pen_x = 0;
                line_count += 1;
                previous_glyph_id = null;
                continue;
            }
            if (codepoint == '\r') {
                previous_glyph_id = null;
                continue;
            }
            const glyph_id = self.glyphIndexForCodepoint(codepoint);
            if (previous_glyph_id) |previous_id| {
                pen_x += self.kerningInFontUnits(previous_id, glyph_id) * pixel_scale;
            }
            pen_x += self.advanceWidthPixels(glyph_id, pixel_scale);
            previous_glyph_id = glyph_id;
        }
        widest_line_width = @max(widest_line_width, pen_x);
        return .{
            .width = widest_line_width,
            .height = @as(f32, @floatFromInt(line_count)) * self.lineHeightPixels(pixel_scale),
        };
    }

    /// Renders a UTF-8 text run into a bitmap.
    ///
    /// The pen starts at `(pen_start_x, pen_start_baseline_y)` and advances
    /// by each glyph's kerned advance width. `\n` moves the pen to the next
    /// line (advancing by the line height and restoring the start x);
    /// `\r` only breaks kerning. Coverage is max-blended into the bitmap.
    ///
    /// Parameters:
    ///     `allocator`: Temporary allocator used while decoding each outline.
    ///     `utf8_text`: Text to render. Invalid bytes decode as U+FFFD and
    ///         render as `.notdef`.
    ///     `pixel_scale`: Scale factor obtained from `scaleForPixelSize`.
    ///     `destination_bitmap`: Coverage bitmap drawn into.
    ///     `pen_start_x`: Horizontal pen start position, in pixels.
    ///     `pen_start_baseline_y`: Vertical baseline start position, in pixels.
    ///
    /// Errors:
    ///     error.OutOfMemory: Allocation failed.
    pub fn renderText(
        self: *const Font,
        allocator: std.mem.Allocator,
        utf8_text: []const u8,
        pixel_scale: f32,
        destination_bitmap: *const Bitmap,
        pen_start_x: f32,
        pen_start_baseline_y: f32,
    ) RenderError!void {
        var utf8_iterator = Utf8Iterator{ .bytes = utf8_text };
        var pen_x = pen_start_x;
        var pen_y = pen_start_baseline_y;
        const line_start_pen_x = pen_start_x;
        var previous_glyph_id: ?u16 = null;
        while (utf8_iterator.next()) |codepoint| {
            if (codepoint == '\n') {
                pen_y += self.lineHeightPixels(pixel_scale);
                pen_x = line_start_pen_x;
                previous_glyph_id = null;
                continue;
            }
            if (codepoint == '\r') {
                previous_glyph_id = null;
                continue;
            }
            const glyph_id = self.glyphIndexForCodepoint(codepoint);
            if (previous_glyph_id) |previous_id| {
                pen_x += self.kerningInFontUnits(previous_id, glyph_id) * pixel_scale;
            }
            try self.renderGlyph(allocator, glyph_id, pixel_scale, destination_bitmap, pen_x, pen_y);
            pen_x += self.advanceWidthPixels(glyph_id, pixel_scale);
            previous_glyph_id = glyph_id;
        }
    }
};

/// Incremental decoder that yields one Unicode codepoint per step from a
/// UTF-8 byte slice.
///
/// Malformed sequences (bad lead bytes, truncated sequences, missing
/// continuation bytes) yield the replacement character U+FFFD and resynchronize
/// on the next byte, so the iterator always makes progress.
pub const Utf8Iterator = struct {
    /// Byte slice being decoded. Borrowed, must outlive the iterator.
    bytes: []const u8,
    /// Index of the next byte to decode.
    byte_offset: usize = 0,

    /// Decodes the next codepoint.
    ///
    /// Returns:
    ///     The next Unicode scalar value, the replacement character U+FFFD for
    ///     malformed input, or `null` when the input is fully consumed.
    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.byte_offset >= self.bytes.len) return null;
        const lead_byte = self.bytes[self.byte_offset];
        if (lead_byte < 0x80) {
            self.byte_offset += 1;
            return lead_byte;
        }
        var sequence_length: usize = undefined;
        var codepoint: u21 = undefined;
        if (lead_byte & 0xE0 == 0xC0) {
            sequence_length = 2;
            codepoint = lead_byte & 0x1F;
        } else if (lead_byte & 0xF0 == 0xE0) {
            sequence_length = 3;
            codepoint = lead_byte & 0x0F;
        } else if (lead_byte & 0xF8 == 0xF0) {
            sequence_length = 4;
            codepoint = lead_byte & 0x07;
        } else {
            self.byte_offset += 1;
            return 0xFFFD;
        }
        var continuation_offset: usize = 1;
        while (continuation_offset < sequence_length) : (continuation_offset += 1) {
            if (self.byte_offset + continuation_offset >= self.bytes.len or self.bytes[self.byte_offset + continuation_offset] & 0xC0 != 0x80) {
                self.byte_offset += 1;
                return 0xFFFD;
            }
            const continuation_byte = self.bytes[self.byte_offset + continuation_offset];
            codepoint = (codepoint << 6) | (continuation_byte & 0x3F);
        }
        self.byte_offset += sequence_length;
        return codepoint;
    }
};

test "utf8 iterator" {
    var utf8_iterator = Utf8Iterator{ .bytes = "aж\u{1F600}" };
    try std.testing.expectEqual(@as(u21, 'a'), utf8_iterator.next().?);
    try std.testing.expectEqual(@as(u21, 0x0436), utf8_iterator.next().?);
    try std.testing.expectEqual(@as(u21, 0x1F600), utf8_iterator.next().?);
    try std.testing.expectEqual(@as(?u21, null), utf8_iterator.next());
}
