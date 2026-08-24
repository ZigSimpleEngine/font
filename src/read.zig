//! Bounds-checked reading utilities for big-endian binary data.
//!
//! TrueType font files store every integer in big-endian byte order. This module
//! provides a sequential `Reader` plus free functions that decode values at
//! explicit byte offsets inside a byte slice.

const std = @import("std");

/// Error set produced when a read or a seek would go past the end of the buffer.
pub const ReadError = error{
    /// The requested bytes extend beyond the end of the underlying buffer.
    OutOfBounds,
};

/// Sequential, bounds-checked reader over a byte slice with big-endian decoding.
///
/// All read methods advance `byte_offset` on success and leave it unchanged on
/// failure, so a failed read never corrupts the reader position.
pub const Reader = struct {
    /// The complete byte buffer this reader reads from. The buffer is borrowed,
    /// not owned, and must outlive the reader.
    data: []const u8,
    /// Absolute index of the next byte to be read within `data`.
    byte_offset: usize = 0,

    /// Creates a reader positioned at the very start of `data`.
    ///
    /// Parameters:
    ///     `data`: Byte buffer to read from. The buffer is borrowed, not owned,
    ///         and must remain valid for as long as the reader is used.
    ///
    /// Returns:
    ///     A new reader with `byte_offset` set to zero.
    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    /// Returns the number of bytes left between `byte_offset` and the end of
    /// `data`.
    ///
    /// Returns:
    ///     Count of bytes available for subsequent read operations.
    pub fn remainingByteCount(self: *const Reader) usize {
        return self.data.len - self.byte_offset;
    }

    /// Moves `byte_offset` to an explicit absolute position inside `data`.
    ///
    /// Parameters:
    ///     `absolute_offset`: New byte offset counted from the start of `data`.
    ///
    /// Errors:
    ///     error.OutOfBounds: `absolute_offset` is greater than `data.len`.
    pub fn seekToAbsoluteOffset(self: *Reader, absolute_offset: usize) ReadError!void {
        if (absolute_offset > self.data.len) return error.OutOfBounds;
        self.byte_offset = absolute_offset;
    }

    /// Advances `byte_offset` forward without interpreting the skipped bytes.
    ///
    /// Parameters:
    ///     `byte_count`: Number of bytes to skip past.
    ///
    /// Errors:
    ///     error.OutOfBounds: Fewer than `byte_count` bytes remain in the buffer.
    pub fn skipBytes(self: *Reader, byte_count: usize) ReadError!void {
        if (self.remainingByteCount() < byte_count) return error.OutOfBounds;
        self.byte_offset += byte_count;
    }

    /// Reads a single unsigned 8-bit byte.
    ///
    /// Returns:
    ///     The decoded byte value.
    ///
    /// Errors:
    ///     error.OutOfBounds: The buffer is already fully consumed.
    pub fn readByte(self: *Reader) ReadError!u8 {
        if (self.remainingByteCount() < 1) return error.OutOfBounds;
        const byte_value = self.data[self.byte_offset];
        self.byte_offset += 1;
        return byte_value;
    }

    /// Reads an unsigned 16-bit big-endian integer.
    ///
    /// Returns:
    ///     The decoded unsigned 16-bit value.
    ///
    /// Errors:
    ///     error.OutOfBounds: Fewer than 2 bytes remain in the buffer.
    pub fn readUInt16(self: *Reader) ReadError!u16 {
        if (self.remainingByteCount() < 2) return error.OutOfBounds;
        const value = std.mem.readInt(u16, self.data[self.byte_offset..][0..2], .big);
        self.byte_offset += 2;
        return value;
    }

    /// Reads a signed 16-bit big-endian integer in two's complement form.
    ///
    /// Returns:
    ///     The decoded signed 16-bit value.
    ///
    /// Errors:
    ///     error.OutOfBounds: Fewer than 2 bytes remain in the buffer.
    pub fn readInt16(self: *Reader) ReadError!i16 {
        return @bitCast(try self.readUInt16());
    }

    /// Reads an unsigned 32-bit big-endian integer.
    ///
    /// Returns:
    ///     The decoded unsigned 32-bit value.
    ///
    /// Errors:
    ///     error.OutOfBounds: Fewer than 4 bytes remain in the buffer.
    pub fn readUInt32(self: *Reader) ReadError!u32 {
        if (self.remainingByteCount() < 4) return error.OutOfBounds;
        const value = std.mem.readInt(u32, self.data[self.byte_offset..][0..4], .big);
        self.byte_offset += 4;
        return value;
    }

    /// Reads a signed 32-bit big-endian integer in two's complement form.
    ///
    /// Returns:
    ///     The decoded signed 32-bit value.
    ///
    /// Errors:
    ///     error.OutOfBounds: Fewer than 4 bytes remain in the buffer.
    pub fn readInt32(self: *Reader) ReadError!i32 {
        return @bitCast(try self.readUInt32());
    }

    /// Validates and converts a reader-relative offset into an absolute offset.
    ///
    /// Parameters:
    ///     `relative_offset`: Offset counted from the current `byte_offset`.
    ///     `value_byte_count`: Number of bytes the value at that offset occupies.
    ///
    /// Returns:
    ///     Absolute index inside `data` where the value begins.
    ///
    /// Errors:
    ///     error.OutOfBounds: The value would extend beyond the end of `data`,
    ///         or the offset arithmetic overflows.
    fn absoluteOffsetRange(self: *const Reader, relative_offset: usize, value_byte_count: usize) ReadError!usize {
        const absolute_offset = self.byte_offset + relative_offset;
        const end_offset = absolute_offset + value_byte_count;
        if (end_offset > self.data.len or end_offset < absolute_offset) return error.OutOfBounds;
        return absolute_offset;
    }

    /// Reads an unsigned 16-bit big-endian integer without advancing
    /// `byte_offset`.
    ///
    /// Parameters:
    ///     `relative_offset`: Offset of the value counted from the current
    ///         `byte_offset`.
    ///
    /// Returns:
    ///     The decoded unsigned 16-bit value.
    ///
    /// Errors:
    ///     error.OutOfBounds: The value would extend beyond the end of `data`.
    pub fn peekUInt16At(self: *const Reader, relative_offset: usize) ReadError!u16 {
        const absolute_offset = try self.absoluteOffsetRange(relative_offset, 2);
        return std.mem.readInt(u16, self.data[absolute_offset..][0..2], .big);
    }
};

/// Reads an unsigned 16-bit big-endian integer at an explicit byte offset.
///
/// Parameters:
///     `data`: Byte buffer to read from.
///     `byte_offset`: Absolute index of the first byte of the value.
///
/// Returns:
///     The decoded unsigned 16-bit value.
///
/// Errors:
///     error.OutOfBounds: `byte_offset + 2` extends beyond the end of `data`.
pub fn bigEndianUInt16At(data: []const u8, byte_offset: usize) ReadError!u16 {
    if (byte_offset + 2 > data.len) return error.OutOfBounds;
    return std.mem.readInt(u16, data[byte_offset..][0..2], .big);
}

/// Reads a signed 16-bit big-endian integer at an explicit byte offset.
///
/// Parameters:
///     `data`: Byte buffer to read from.
///     `byte_offset`: Absolute index of the first byte of the value.
///
/// Returns:
///     The decoded signed 16-bit value.
///
/// Errors:
///     error.OutOfBounds: `byte_offset + 2` extends beyond the end of `data`.
pub fn bigEndianInt16At(data: []const u8, byte_offset: usize) ReadError!i16 {
    return @bitCast(try bigEndianUInt16At(data, byte_offset));
}

/// Reads an unsigned 32-bit big-endian integer at an explicit byte offset.
///
/// Parameters:
///     `data`: Byte buffer to read from.
///     `byte_offset`: Absolute index of the first byte of the value.
///
/// Returns:
///     The decoded unsigned 32-bit value.
///
/// Errors:
///     error.OutOfBounds: `byte_offset + 4` extends beyond the end of `data`.
pub fn bigEndianUInt32At(data: []const u8, byte_offset: usize) ReadError!u32 {
    if (byte_offset + 4 > data.len) return error.OutOfBounds;
    return std.mem.readInt(u32, data[byte_offset..][0..4], .big);
}

test "reader bounds" {
    var reader = Reader.init(&[_]u8{ 1, 2, 3 });
    try std.testing.expectEqual(@as(u16, 0x0102), try reader.readUInt16());
    try std.testing.expectEqual(@as(u8, 3), try reader.readByte());
    try std.testing.expectError(error.OutOfBounds, reader.readUInt16());
}

test "at helpers" {
    const sample_data = [_]u8{ 0, 5, 0xFF, 0xFE };
    try std.testing.expectEqual(@as(u16, 5), try bigEndianUInt16At(&sample_data, 0));
    try std.testing.expectEqual(@as(i16, -2), try bigEndianInt16At(&sample_data, 2));
    try std.testing.expectError(error.OutOfBounds, bigEndianUInt16At(&sample_data, 3));
}
