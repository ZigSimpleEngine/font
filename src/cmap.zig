//! Character to glyph index mapping (`cmap` table).
//!
//! Supports the subtable formats commonly found in real fonts:
//! format 0 (byte encoding), format 4 (BMP segmented mapping), format 6
//! (trimmed table mapping) and format 12 (full Unicode segmented mapping).
//! `selectBestSubtable` picks the most capable Unicode-capable subtable and
//! `glyphIndexForCodepoint` performs the lookup, including the classic
//! Macintosh Symbol (3,0) 0xF000 fallback.

const std = @import("std");
const read_module = @import("read.zig");

/// Selected `cmap` subtable that maps Unicode codepoints to glyph indices.
///
/// `subtable_bytes` is a zero-copy slice into the font data and must remain
/// valid for as long as this structure is used.
pub const CharacterMap = struct {
    /// Raw bytes of the chosen encoding subtable.
    subtable_bytes: []const u8,
    /// Platform id of the chosen subtable (for example 3 = Microsoft).
    platform_id: u16,
    /// Encoding id of the chosen subtable (for example 1 = Unicode BMP).
    encoding_id: u16,
    /// Format number of the chosen subtable (0, 4, 6 or 12).
    subtable_format: u8,

    /// Scans every encoding record of a `cmap` table and picks the subtable
    /// with the best supported format and encoding combination.
    ///
    /// Scoring prefers richer formats (12 > 6 > {0,4}) and Unicode-oriented
    /// encodings: (3,10) and (0,4)/(0,6) rank highest, followed by (3,1) and
    /// (0,3)/(0,x), with the legacy symbol encoding (3,0) last.
    ///
    /// Parameters:
    ///     `cmap_table`: Raw bytes of the whole `cmap` table including its
    ///         header and encoding records. Borrowed, must outlive the result.
    ///
    /// Returns:
    ///     The best supported subtable, or `null` when the table is malformed
    ///     or contains no supported format.
    pub fn selectBestSubtable(cmap_table: []const u8) ?CharacterMap {
        if (cmap_table.len < 4) return null;
        const encoding_record_count = read_module.bigEndianUInt16At(cmap_table, 2) catch return null;
        var best_subtable: ?CharacterMap = null;
        var best_subtable_score: u32 = 0;
        var record_index: u32 = 0;
        while (record_index < encoding_record_count) : (record_index += 1) {
            const encoding_record_offset = 4 + @as(usize, record_index) * 8;
            if (encoding_record_offset + 8 > cmap_table.len) break;
            const platform_id = read_module.bigEndianUInt16At(cmap_table, encoding_record_offset) catch continue;
            const encoding_id = read_module.bigEndianUInt16At(cmap_table, encoding_record_offset + 2) catch continue;
            const subtable_offset = read_module.bigEndianUInt32At(cmap_table, encoding_record_offset + 4) catch continue;
            if (subtable_offset >= cmap_table.len) continue;
            const subtable_bytes = cmap_table[subtable_offset..];
            if (subtable_bytes.len < 4) continue;
            const subtable_format = read_module.bigEndianUInt16At(subtable_bytes, 0) catch continue;
            const format_score: u32 = switch (subtable_format) {
                0, 4 => 1,
                6 => 2,
                12 => 3,
                else => 0,
            };
            if (format_score == 0) continue;
            const encoding_score: u32 = switch (platform_id) {
                3 => switch (encoding_id) {
                    10 => 40,
                    1 => 30,
                    else => 10,
                },
                0 => switch (encoding_id) {
                    3, 4, 6 => 35,
                    else => 20,
                },
                else => 5,
            };
            const combined_score = format_score * 100 + encoding_score;
            if (best_subtable == null or combined_score > best_subtable_score) {
                best_subtable = .{
                    .subtable_bytes = subtable_bytes,
                    .platform_id = platform_id,
                    .encoding_id = encoding_id,
                    .subtable_format = @intCast(subtable_format),
                };
                best_subtable_score = combined_score;
            }
        }
        return best_subtable;
    }

    /// Maps a Unicode codepoint to a glyph index.
    ///
    /// When the selected subtable is a Macintosh Symbol encoding (3,0) and the
    /// direct lookup misses, the lookup is retried with the classic 0xF000
    /// range remap used by most Windows symbol fonts.
    ///
    /// Parameters:
    ///     `codepoint`: Unicode scalar value to translate.
    ///
    /// Returns:
    ///     Glyph index for the codepoint, or 0 (`.notdef`) when unmapped.
    pub fn glyphIndexForCodepoint(self: *const CharacterMap, codepoint: u21) u16 {
        const direct_glyph_index = self.lookupWithoutFallback(codepoint);
        if (direct_glyph_index != 0) return direct_glyph_index;
        if (self.platform_id == 3 and self.encoding_id == 0 and codepoint <= 0xFF) {
            return self.lookupWithoutFallback(0xF000 | @as(u21, codepoint));
        }
        return 0;
    }

    /// Dispatches a lookup to the decoder of the selected subtable format
    /// without applying any symbol fallback.
    ///
    /// Parameters:
    ///     `codepoint`: Unicode scalar value to translate.
    ///
    /// Returns:
    ///     Glyph index for the codepoint, or 0 when unmapped or when the
    ///     format decoder rejects the input.
    fn lookupWithoutFallback(self: *const CharacterMap, codepoint: u21) u16 {
        return switch (self.subtable_format) {
            0 => lookupFormat0(self.subtable_bytes, codepoint),
            4 => lookupFormat4(self.subtable_bytes, codepoint),
            6 => lookupFormat6(self.subtable_bytes, codepoint),
            12 => lookupFormat12(self.subtable_bytes, codepoint),
            else => 0,
        };
    }
};

/// Looks up a codepoint in a `cmap` format 0 subtable (byte encoding).
///
/// Format 0 stores a flat array of 256 one-byte glyph indices starting at
/// offset 10, one entry per byte-sized codepoint.
///
/// Parameters:
///     `subtable_bytes`: Raw bytes of the format 0 subtable.
///     `codepoint`: Unicode scalar value to translate.
///
/// Returns:
///     Glyph index for the codepoint, or 0 when the codepoint exceeds 0xFF or
///     the subtable is truncated.
fn lookupFormat0(subtable_bytes: []const u8, codepoint: u21) u16 {
    if (codepoint > 0xFF or subtable_bytes.len < 262) return 0;
    return subtable_bytes[10 + codepoint];
}

/// Looks up a codepoint in a `cmap` format 4 subtable (segmented BMP mapping).
///
/// Format 4 divides the BMP into segments described by parallel arrays of end
/// codes, start codes, id deltas and id range offsets. The segment containing
/// the codepoint is located with a binary search over the end codes; the glyph
/// index is then either `codepoint + id_delta` or read through an offset
/// table indirection, depending on the segment.
///
/// Parameters:
///     `subtable_bytes`: Raw bytes of the format 4 subtable.
///     `codepoint`: Unicode scalar value to translate.
///
/// Returns:
///     Glyph index for the codepoint, or 0 when the codepoint is outside the
///     BMP, unmapped, or the subtable is malformed.
fn lookupFormat4(subtable_bytes: []const u8, codepoint: u21) u16 {
    if (codepoint > 0xFFFF or subtable_bytes.len < 16) return 0;
    const segment_count_x2 = read_module.bigEndianUInt16At(subtable_bytes, 6) catch return 0;
    if (segment_count_x2 == 0 or segment_count_x2 % 2 != 0) return 0;
    const segment_count: usize = segment_count_x2 / 2;
    const end_codes_offset: usize = 14;
    const start_codes_offset: usize = end_codes_offset + segment_count * 2 + 2;
    const id_deltas_offset: usize = start_codes_offset + segment_count * 2;
    const id_range_offsets_offset: usize = id_deltas_offset + segment_count * 2;
    if (id_range_offsets_offset + segment_count * 2 > subtable_bytes.len) return 0;

    const codepoint_value: u32 = codepoint;
    var low_index: usize = 0;
    var high_index: usize = segment_count;
    while (low_index < high_index) {
        const middle_index = low_index + (high_index - low_index) / 2;
        const segment_end_code = read_module.bigEndianUInt16At(subtable_bytes, end_codes_offset + middle_index * 2) catch return 0;
        if (segment_end_code < codepoint_value) low_index = middle_index + 1 else high_index = middle_index;
    }
    if (low_index >= segment_count) return 0;
    const segment_start_code = read_module.bigEndianUInt16At(subtable_bytes, start_codes_offset + low_index * 2) catch return 0;
    if (codepoint_value < segment_start_code) return 0;
    const id_delta = read_module.bigEndianInt16At(subtable_bytes, id_deltas_offset + low_index * 2) catch return 0;
    const id_range_offset = read_module.bigEndianUInt16At(subtable_bytes, id_range_offsets_offset + low_index * 2) catch return 0;
    if (id_range_offset == 0) {
        return @truncate(@as(u32, @bitCast(@as(i32, @intCast(codepoint_value)) + id_delta)));
    }
    const id_range_offset_absolute_position = id_range_offsets_offset + low_index * 2;
    const glyph_id_byte_offset_signed = @as(i64, @intCast(id_range_offset_absolute_position)) + id_range_offset + 2 * (@as(i64, codepoint_value) - segment_start_code);
    if (glyph_id_byte_offset_signed < 0 or glyph_id_byte_offset_signed + 2 > subtable_bytes.len) return 0;
    const referenced_glyph_id = read_module.bigEndianUInt16At(subtable_bytes, @intCast(glyph_id_byte_offset_signed)) catch return 0;
    if (referenced_glyph_id == 0) return 0;
    return @truncate(@as(u32, @bitCast(@as(i32, referenced_glyph_id) + id_delta)));
}

/// Looks up a codepoint in a `cmap` format 6 subtable (trimmed mapping).
///
/// Format 6 stores glyph indices for one contiguous codepoint range starting
/// at `first_code`, addressed directly by `codepoint - first_code`.
///
/// Parameters:
///     `subtable_bytes`: Raw bytes of the format 6 subtable.
///     `codepoint`: Unicode scalar value to translate.
///
/// Returns:
///     Glyph index for the codepoint, or 0 when the codepoint lies outside
///     the stored range or the subtable is truncated.
fn lookupFormat6(subtable_bytes: []const u8, codepoint: u21) u16 {
    if (subtable_bytes.len < 10) return 0;
    const first_code = read_module.bigEndianUInt16At(subtable_bytes, 6) catch return 0;
    const entry_count = read_module.bigEndianUInt16At(subtable_bytes, 8) catch return 0;
    const codepoint_value: u32 = codepoint;
    if (codepoint_value < first_code or codepoint_value - first_code >= entry_count) return 0;
    const glyph_id_offset = (codepoint_value - first_code) * 2 + 10;
    return read_module.bigEndianUInt16At(subtable_bytes, glyph_id_offset) catch 0;
}

/// Looks up a codepoint in a `cmap` format 12 subtable (full Unicode).
///
/// Format 12 stores a sorted list of groups, each mapping a contiguous
/// codepoint range to a contiguous glyph id range. The group containing the
/// codepoint is located with a binary search over the group start codes.
///
/// Parameters:
///     `subtable_bytes`: Raw bytes of the format 12 subtable.
///     `codepoint`: Unicode scalar value to translate.
///
/// Returns:
///     Glyph index for the codepoint, or 0 when no group covers the codepoint
///     or the subtable is truncated.
fn lookupFormat12(subtable_bytes: []const u8, codepoint: u21) u16 {
    if (subtable_bytes.len < 32) return 0;
    const group_count = read_module.bigEndianUInt32At(subtable_bytes, 12) catch return 0;
    const groups_offset: usize = 16;
    const codepoint_value: u32 = codepoint;
    var low_index: u32 = 0;
    var high_index: u32 = group_count;
    while (low_index < high_index) {
        const middle_index = low_index + (high_index - low_index) / 2;
        const group_record_offset = groups_offset + @as(usize, middle_index) * 12;
        const group_start_char_code = read_module.bigEndianUInt32At(subtable_bytes, group_record_offset) catch return 0;
        if (group_start_char_code > codepoint_value) high_index = middle_index else low_index = middle_index + 1;
    }
    if (low_index == 0) return 0;
    const group_record_offset = groups_offset + @as(usize, low_index - 1) * 12;
    const group_start_char_code = read_module.bigEndianUInt32At(subtable_bytes, group_record_offset) catch return 0;
    const group_end_char_code = read_module.bigEndianUInt32At(subtable_bytes, group_record_offset + 4) catch return 0;
    if (codepoint_value < group_start_char_code or codepoint_value > group_end_char_code) return 0;
    const group_start_glyph_id = read_module.bigEndianUInt32At(subtable_bytes, group_record_offset + 8) catch return 0;
    return @truncate(group_start_glyph_id + (codepoint_value - group_start_char_code));
}

test "cmap format 4 lookup" {
    var format4_subtable: [40]u8 = undefined;
    inline for (&format4_subtable) |*byte_value| byte_value.* = 0;
    writeBigEndianUInt16(&format4_subtable, 0, 4);
    writeBigEndianUInt16(&format4_subtable, 2, 40);
    writeBigEndianUInt16(&format4_subtable, 6, 6);
    writeBigEndianUInt16(&format4_subtable, 14, 0x42);
    writeBigEndianUInt16(&format4_subtable, 16, 0x50);
    writeBigEndianUInt16(&format4_subtable, 18, 0xFFFF);
    writeBigEndianUInt16(&format4_subtable, 22, 0x42);
    writeBigEndianUInt16(&format4_subtable, 24, 0x50);
    writeBigEndianUInt16(&format4_subtable, 26, 0xFFFF);
    writeBigEndianUInt16(&format4_subtable, 28, 0xFFBF);
    writeBigEndianUInt16(&format4_subtable, 30, 0);
    writeBigEndianUInt16(&format4_subtable, 32, 1);
    writeBigEndianUInt16(&format4_subtable, 34, 0);
    writeBigEndianUInt16(&format4_subtable, 36, 0);
    writeBigEndianUInt16(&format4_subtable, 38, 0);
    const character_map = CharacterMap{ .subtable_bytes = &format4_subtable, .platform_id = 3, .encoding_id = 1, .subtable_format = 4 };
    try std.testing.expectEqual(@as(u16, 1), character_map.glyphIndexForCodepoint(0x42));
    try std.testing.expectEqual(@as(u16, 0), character_map.glyphIndexForCodepoint(0x43));
    try std.testing.expectEqual(@as(u16, 0x50), character_map.glyphIndexForCodepoint(0x50));
    try std.testing.expectEqual(@as(u16, 0), character_map.glyphIndexForCodepoint(0x51));
}

/// Writes one unsigned 16-bit value in big-endian order into a test buffer.
///
/// Parameters:
///     `buffer`: Destination buffer to modify.
///     `byte_offset`: Absolute index of the first written byte.
///     `value`: Unsigned 16-bit value to encode.
fn writeBigEndianUInt16(buffer: []u8, byte_offset: usize, value: u16) void {
    std.mem.writeInt(u16, buffer[byte_offset..][0..2], value, .big);
}
