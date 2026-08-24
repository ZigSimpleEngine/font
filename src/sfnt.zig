//! sfnt container parser for TrueType font files.
//!
//! An sfnt file starts with a version tag and a directory of table records
//! (tag, checksum, offset, length). This module locates every table the library
//! needs and exposes typed accessors for the fixed-layout header tables
//! (`head`, `hhea`, `maxp`, `hmtx`) and for glyph data lookup through `loca`.

const std = @import("std");
const read_module = @import("read.zig");
const Reader = read_module.Reader;

/// Error set produced while validating the sfnt container and its tables.
pub const ParseError = error{
    /// The sfnt version tag is neither 0x00010000 nor `'true'`.
    InvalidFont,
    /// A required table (`glyf` or `loca`) is missing from the directory.
    MissingTable,
    /// The `head` table is missing or shorter than its fixed 54-byte layout.
    MissingHead,
    /// The `hhea` table is missing or shorter than its fixed 36-byte layout.
    MissingHhea,
    /// The `maxp` table is missing or shorter than its fixed 6-byte minimum.
    MissingMaxp,
    /// The `hmtx` table is missing or shorter than one horizontal metric record.
    MissingHmtx,
};

/// Parsed sfnt table directory with direct slices into the original font data.
///
/// Every field is a zero-copy slice into `data`; the caller must keep the
/// original font file bytes alive and unmodified for as long as this structure
/// is used.
pub const FontTables = struct {
    /// The complete font file bytes every table slice points into.
    data: []const u8,
    /// `head` table bytes: font-wide header (units per em, loca format, ...).
    head: []const u8,
    /// `hhea` table bytes: horizontal header (ascender, descender, ...).
    hhea: []const u8,
    /// `maxp` table bytes: maximum profile (total glyph count).
    maxp: []const u8,
    /// `hmtx` table bytes: horizontal metrics (advance widths and side bearings).
    hmtx: []const u8,
    /// `cmap` table bytes: character to glyph mapping, if present.
    cmap: ?[]const u8 = null,
    /// `glyf` table bytes: glyph outline data, if present.
    glyf: ?[]const u8 = null,
    /// `loca` table bytes: glyph data index (offsets into `glyf`), if present.
    loca: ?[]const u8 = null,
    /// `kern` table bytes: legacy kerning pairs, if present.
    kern: ?[]const u8 = null,

    /// Walks the sfnt table directory and collects slices of every table this
    /// library understands.
    ///
    /// Checksums stored in the directory are intentionally not verified; the
    /// parser only validates that each recorded range lies inside the file.
    ///
    /// Parameters:
    ///     `font_file_data`: Raw bytes of the whole font file. The data is
    ///         borrowed and must outlive the returned `FontTables`.
    ///
    /// Returns:
    ///     A `FontTables` with all located table slices filled in.
    ///
    /// Errors:
    ///     error.InvalidFont: The sfnt version tag is unrecognized, the table
    ///         count is implausible, or a recorded table range lies outside
    ///         the file.
    ///     error.OutOfBounds: The file ends in the middle of the table
    ///         directory or of one of the fixed-size header tables.
    ///     error.MissingHead: The `head` table is missing or truncated.
    ///     error.MissingHhea: The `hhea` table is missing or truncated.
    ///     error.MissingMaxp: The `maxp` table is missing or truncated.
    ///     error.MissingHmtx: The `hmtx` table is missing or truncated.
    ///     error.MissingTable: The `glyf` or `loca` table is missing, which
    ///         means the font does not use TrueType outlines.
    pub fn parse(font_file_data: []const u8) (ParseError || read_module.ReadError)!FontTables {
        var reader = Reader.init(font_file_data);
        const sfnt_version = try reader.readUInt32();
        const sfnt_version_true_type_1_0: u32 = 0x00010000;
        const sfnt_version_apple_true: u32 = 0x74727565;
        if (sfnt_version != sfnt_version_true_type_1_0 and sfnt_version != sfnt_version_apple_true) return error.InvalidFont;
        const table_count = try reader.readUInt16();
        if (table_count > 512) return error.InvalidFont;
        try reader.skipBytes(6);

        var tables = FontTables{
            .data = font_file_data,
            .head = &.{},
            .hhea = &.{},
            .maxp = &.{},
            .hmtx = &.{},
        };

        var record_index: usize = 0;
        while (record_index < table_count) : (record_index += 1) {
            if (reader.remainingByteCount() < 16) return error.InvalidFont;
            const table_tag = reader.data[reader.byte_offset..][0..4];
            reader.byte_offset += 4;
            _ = try reader.readUInt32();
            const table_offset = try reader.readUInt32();
            const table_length = try reader.readUInt32();
            if (table_offset > font_file_data.len or table_length > font_file_data.len - table_offset) return error.InvalidFont;
            const table_bytes = font_file_data[table_offset..][0..table_length];
            if (std.mem.eql(u8, table_tag, "head")) {
                tables.head = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "hhea")) {
                tables.hhea = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "maxp")) {
                tables.maxp = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "hmtx")) {
                tables.hmtx = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "cmap")) {
                tables.cmap = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "glyf")) {
                tables.glyf = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "loca")) {
                tables.loca = table_bytes;
            } else if (std.mem.eql(u8, table_tag, "kern")) {
                tables.kern = table_bytes;
            }
        }

        if (tables.head.len < 54) return error.MissingHead;
        if (tables.hhea.len < 36) return error.MissingHhea;
        if (tables.maxp.len < 6) return error.MissingMaxp;
        if (tables.hmtx.len < 4) return error.MissingHmtx;
        if (tables.glyf == null or tables.loca == null) return error.MissingTable;
        return tables;
    }

    /// Returns the design-space size of the em square taken from `head`.
    ///
    /// All outline coordinates in the font are expressed in units of this em
    /// square. Values of zero are replaced with the common fallback of 1000.
    ///
    /// Returns:
    ///     Units per em as a float, always greater than zero.
    pub fn unitsPerEm(self: *const FontTables) f32 {
        const raw_value = read_module.bigEndianUInt16At(self.head, 18) catch 1000;
        if (raw_value == 0) return 1000;
        return @floatFromInt(raw_value);
    }

    /// Returns the total number of glyphs declared in `maxp`.
    ///
    /// Returns:
    ///     Glyph count; glyph ids are valid in the range `0 .. count - 1`.
    pub fn glyphCount(self: *const FontTables) u16 {
        return read_module.bigEndianUInt16At(self.maxp, 4) catch 0;
    }

    /// Returns the typographic ascender from `hhea` in font units.
    ///
    /// Returns:
    ///     Distance from the baseline to the recommended top of the line
    ///     (positive value, font units).
    pub fn ascender(self: *const FontTables) i16 {
        return read_module.bigEndianInt16At(self.hhea, 4) catch 0;
    }

    /// Returns the typographic descender from `hhea` in font units.
    ///
    /// Returns:
    ///     Distance from the baseline to the recommended bottom of the line
    ///     (usually negative, font units).
    pub fn descender(self: *const FontTables) i16 {
        return read_module.bigEndianInt16At(self.hhea, 6) catch 0;
    }

    /// Returns the recommended extra line spacing from `hhea` in font units.
    ///
    /// Returns:
    ///     Gap to add between consecutive text lines (font units, may be zero).
    pub fn lineGap(self: *const FontTables) i16 {
        return read_module.bigEndianInt16At(self.hhea, 8) catch 0;
    }

    /// Reports whether `loca` stores long (32-bit) offsets.
    ///
    /// Returns:
    ///     `true` when `loca` entries are unsigned 32-bit byte offsets,
    ///     `false` when they are unsigned 16-bit values that must be
    ///     multiplied by two to obtain byte offsets.
    pub fn usesLongLocaFormat(self: *const FontTables) bool {
        const raw_value = read_module.bigEndianUInt16At(self.head, 50) catch 0;
        return raw_value != 0;
    }

    /// Returns the number of leading glyphs that have their own entry in
    /// `hmtx`.
    ///
    /// Glyphs beyond this count reuse the advance width of the last recorded
    /// glyph, as mandated by the TrueType specification.
    ///
    /// Returns:
    ///     Number of explicit horizontal metric records, clamped to the total
    ///     glyph count.
    pub fn horizontalMetricsCount(self: *const FontTables) u16 {
        const raw_value = read_module.bigEndianUInt16At(self.hhea, 34) catch 0;
        return @min(raw_value, self.glyphCount());
    }

    /// Byte range of one glyph's data inside the `glyf` table.
    pub const GlyphByteRange = struct {
        /// Absolute offset of the first byte of the glyph inside `glyf`.
        byte_start: usize,
        /// Absolute offset one past the last byte of the glyph inside `glyf`.
        byte_end: usize,
    };

    /// Looks up where a glyph's data lives inside the `glyf` table.
    ///
    /// Handles both short and long `loca` encodings transparently.
    ///
    /// Parameters:
    ///     `glyph_id`: Index of the glyph; `glyphCount()` is a valid id that
    ///         addresses the sentinel entry at the end of `loca`.
    ///
    /// Returns:
    ///     Half-open byte range `[byte_start, byte_end)` of the glyph data.
    ///
    /// Errors:
    ///     error.OutOfBounds: `glyph_id` exceeds the sentinel position.
    pub fn glyphByteRange(self: *const FontTables, glyph_id: u16) read_module.ReadError!GlyphByteRange {
        const loca_table = self.loca.?;
        const total_glyph_count = self.glyphCount();
        if (glyph_id >= total_glyph_count + 1) return error.OutOfBounds;
        if (self.usesLongLocaFormat()) {
            const range_byte_start = read_module.bigEndianUInt32At(loca_table, @as(usize, glyph_id) * 4) catch 0;
            const range_byte_end = read_module.bigEndianUInt32At(loca_table, @as(usize, glyph_id) * 4 + 4) catch 0;
            return .{ .byte_start = range_byte_start, .byte_end = range_byte_end };
        }
        const first_entry = read_module.bigEndianUInt16At(loca_table, @as(usize, glyph_id) * 2) catch 0;
        const second_entry = read_module.bigEndianUInt16At(loca_table, @as(usize, glyph_id) * 2 + 2) catch 0;
        return .{
            .byte_start = @as(usize, first_entry) * 2,
            .byte_end = @as(usize, second_entry) * 2,
        };
    }

    /// Returns the raw `glyf` bytes belonging to one glyph.
    ///
    /// An empty slice means the glyph has no outline (for example a space).
    ///
    /// Parameters:
    ///     `glyph_id`: Index of the glyph to fetch.
    ///
    /// Returns:
    ///     Zero-copy slice into the font data covering exactly this glyph.
    ///
    /// Errors:
    ///     error.OutOfBounds: The glyph id is invalid or its `loca` range
    ///         points outside the `glyf` table.
    pub fn glyphByteData(self: *const FontTables, glyph_id: u16) read_module.ReadError![]const u8 {
        const byte_range = try self.glyphByteRange(glyph_id);
        const glyf_table = self.glyf.?;
        if (byte_range.byte_start > glyf_table.len or byte_range.byte_end > glyf_table.len or byte_range.byte_end < byte_range.byte_start) return error.OutOfBounds;
        return glyf_table[byte_range.byte_start..byte_range.byte_end];
    }

    /// Returns the horizontal advance width of a glyph in font units.
    ///
    /// Glyphs past `horizontalMetricsCount()` reuse the advance width of the
    /// last recorded glyph, as required by the specification.
    ///
    /// Parameters:
    ///     `glyph_id`: Index of the glyph to query.
    ///
    /// Returns:
    ///     Distance the pen moves forward after drawing the glyph (font units).
    pub fn advanceWidthOfGlyph(self: *const FontTables, glyph_id: u16) u16 {
        const horizontal_metric_count = self.horizontalMetricsCount();
        if (horizontal_metric_count == 0) return 0;
        const clamped_glyph_id = @min(glyph_id, horizontal_metric_count - 1);
        return read_module.bigEndianUInt16At(self.hmtx, @as(usize, clamped_glyph_id) * 4) catch 0;
    }
};
