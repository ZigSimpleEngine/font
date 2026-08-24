//! Root source file of the `font` package.
//!
//! Re-exports the public API: `Font` for loading and querying TrueType
//! fonts, `Bitmap` as the rendering target, the metrics types and the decoded
//! outline types. Importing this module as `font` gives access to everything
//! a consumer needs.

const std = @import("std");

/// A loaded TrueType font: parsing, glyph lookup, metrics and rendering.
pub const Font = @import("font.zig").Font;
/// Incremental UTF-8 decoder used by the text functions and available to
/// consumers.
pub const Utf8Iterator = @import("font.zig").Utf8Iterator;
/// 8-bit coverage buffer that glyphs and text are rendered into.
pub const Bitmap = @import("raster.zig").Bitmap;
/// Scaled bounding box and advance of a single glyph.
pub const GlyphMetrics = Font.GlyphMetrics;
/// Measured extents of a whole text run.
pub const TextMetrics = Font.TextMetrics;
/// Decoded outline of one glyph: points, on-curve flags and contour spans.
pub const Outline = @import("outline.zig").Outline;
/// A single two-dimensional point in font units or device pixels.
pub const Point = @import("outline.zig").Point;

test {
    std.testing.refAllDecls(@This());
    _ = @import("read.zig");
    _ = @import("sfnt.zig");
    _ = @import("cmap.zig");
    _ = @import("kern.zig");
    _ = @import("font.zig");
    _ = @import("tests.zig");
}
