//! Legacy kerning pairs (`kern` table, format 0 subtable).
//!
//! Only the classic ordered pair list is supported; GPOS-based kerning is out
//! of scope for this library.

const std = @import("std");
const read_module = @import("read.zig");

/// Format 0 `kern` subtable providing pairwise glyph spacing adjustments.
///
/// `pair_record_bytes` is a zero-copy slice into the font data and must remain
/// valid for as long as this structure is used.
pub const KerningSubtable = struct {
    /// Raw bytes of the ordered kerning pair records, 6 bytes each:
    /// left glyph id (u16), right glyph id (u16), kerning value (i16).
    pair_record_bytes: []const u8,
    /// Number of pair records stored in `pair_record_bytes`.
    pair_count: u16,

    /// Scans a `kern` table and selects the first format 0 subtable.
    ///
    /// Both the classic 16-bit header (version 0) and the OpenType 1.0
    /// 32-bit header variant are accepted. Subtables with any other format
    /// number are skipped.
    ///
    /// Parameters:
    ///     `kern_table`: Raw bytes of the whole `kern` table. Borrowed, must
    ///         outlive the result.
    ///
    /// Returns:
    ///     A subtable view over the pair records, or `null` when the table is
    ///     malformed or contains no format 0 subtable.
    pub fn selectFormatZeroSubtable(kern_table: []const u8) ?KerningSubtable {
        if (kern_table.len < 4) return null;
        const header_version = read_module.bigEndianUInt16At(kern_table, 0) catch return null;
        if (header_version != 0) {
            const wide_version = read_module.bigEndianUInt32At(kern_table, 0) catch return null;
            if ((wide_version & 0xFFFF0000) != 0x00010000 and wide_version != 0x00010000) return null;
        }
        const subtable_count = read_module.bigEndianUInt16At(kern_table, 2) catch return null;
        var subtable_offset: usize = 4;
        var subtable_index: u32 = 0;
        while (subtable_index < subtable_count) : (subtable_index += 1) {
            if (subtable_offset + 6 > kern_table.len) break;
            const subtable_length = read_module.bigEndianUInt16At(kern_table, subtable_offset + 2) catch break;
            const coverage_flags = read_module.bigEndianUInt16At(kern_table, subtable_offset + 4) catch break;
            const subtable_format = coverage_flags >> 8;
            if (subtable_format == 0 and subtable_offset + 14 <= kern_table.len) {
                const pair_count = read_module.bigEndianUInt16At(kern_table, subtable_offset + 6) catch break;
                const pair_records_offset = subtable_offset + 14;
                if (pair_records_offset + @as(usize, pair_count) * 6 <= kern_table.len) {
                    return .{
                        .pair_record_bytes = kern_table[pair_records_offset..][0 .. @as(usize, pair_count) * 6],
                        .pair_count = pair_count,
                    };
                }
                return null;
            }
            if (subtable_length == 0) break;
            subtable_offset += subtable_length;
        }
        return null;
    }

    /// Returns the kerning adjustment for one glyph pair.
    ///
    /// The pair records are sorted by the combined key
    /// `(left_glyph_id << 16) | right_glyph_id`, so the lookup is a binary
    /// search.
    ///
    /// Parameters:
    ///     `left_glyph_id`: Glyph index drawn first.
    ///     `right_glyph_id`: Glyph index drawn immediately after the left one.
    ///
    /// Returns:
    ///     Kerning adjustment in font units to add to the pen advance between
    ///     the two glyphs, or 0 when the pair is not kerned.
    pub fn kerningValue(self: *const KerningSubtable, left_glyph_id: u16, right_glyph_id: u16) i16 {
        const pair_lookup_key = (@as(u32, left_glyph_id) << 16) | right_glyph_id;
        var low_index: usize = 0;
        var high_index: usize = self.pair_count;
        while (low_index < high_index) {
            const middle_index = low_index + (high_index - low_index) / 2;
            const record_offset = middle_index * 6;
            const record_key = read_module.bigEndianUInt32At(self.pair_record_bytes, record_offset) catch return 0;
            if (record_key < pair_lookup_key) low_index = middle_index + 1 else high_index = middle_index;
        }
        if (low_index >= self.pair_count) return 0;
        const record_offset = low_index * 6;
        const record_key = read_module.bigEndianUInt32At(self.pair_record_bytes, record_offset) catch return 0;
        if (record_key != pair_lookup_key) return 0;
        return read_module.bigEndianInt16At(self.pair_record_bytes, record_offset + 4) catch 0;
    }
};
