# font

A minimal, dependency-free TrueType (`.ttf`) font rendering library written in pure Zig.

No C, no libc, no external rasterizers — just the Zig standard library. The library parses
the font, decodes glyph outlines (including composite glyphs), and rasterizes anti-aliased
text into an 8-bit coverage bitmap that is easy to upload to a GPU or composite in software.

## Features

- **sfnt/TrueType container parsing** — `head`, `hhea`, `maxp`, `hmtx`, `loca`, `glyf`, `cmap`, `kern`
- **Glyph outlines** — simple glyphs and composite glyphs (uniform scale, x/y scale and full 2×2 component transforms)
- **Unicode mapping** — `cmap` formats 0, 4, 6 and 12 (BMP + full Unicode), with the classic Macintosh Symbol `(3,0)` `0xF000` fallback
- **Kerning** — `kern` format 0 ordered pairs with binary-search lookup
- **Anti-aliased rasterizer** — cell-based exact trapezoid coverage (FreeType-smooth style), nonzero winding rule, adaptive quadratic curve flattening
- **UTF-8 text** — kerned text layout with `\n` line breaks; invalid bytes decode as U+FFFD
- **Zero-copy** — the library borrows the font bytes; loading a `Font` performs no allocation
- **No hidden state** — a `Font` is immutable after `init` and safe to share

## Contents

- [Project structure](#project-structure)
- [Requirements](#requirements)
- [Using as a package](#using-as-a-package)
- [Architecture overview](#architecture-overview)
- [Coordinates and the pen model](#coordinates-and-the-pen-model)
- [Quick start](#quick-start)
- [Examples](#examples)
  - [Rendering text into a bitmap](#rendering-text-into-a-bitmap)
  - [Rendering a single glyph](#rendering-a-single-glyph)
  - [Inspecting glyph metrics](#inspecting-glyph-metrics)
  - [Multi-line text](#multi-line-text)
  - [Drawing into a framebuffer region (stride)](#drawing-into-a-framebuffer-region-stride)
  - [Building a glyph atlas](#building-a-glyph-atlas)
  - [Converting coverage to RGBA for GPUs](#converting-coverage-to-rgba-for-gpus)
  - [Iterating UTF-8 manually](#iterating-utf-8-manually)
  - [Loading a font file (Zig 0.16 I/O)](#loading-a-font-file-zig-016-io)
- [Command-line demo](#command-line-demo)
- [Public API reference](#public-api-reference)
  - [`Font`](#font)
  - [`GlyphMetrics`](#glyphmetrics)
  - [`TextMetrics`](#textmetrics)
  - [`Bitmap`](#bitmap)
  - [`Utf8Iterator`](#utf8iterator)
  - [`Outline` and `Point`](#outline-and-point)
  - [Error sets](#error-sets)
- [Internal modules](#internal-modules)
  - [Module: `read.zig`](#module-readzig)
  - [Module: `sfnt.zig`](#module-sfntzig)
  - [Module: `cmap.zig`](#module-cmapzig)
  - [Module: `kern.zig`](#module-kernzig)
  - [Module: `outline.zig`](#module-outlinezig)
  - [Module: `raster.zig`](#module-rasterzig)
- [Supported features and limitations](#supported-features-and-limitations)
- [Testing](#testing)
- [License](#license)

## Project structure

```
font/
├── build.zig            build script: library module, demo executable, tests
├── build.zig.zon        package manifest (name, version, fingerprint)
├── LICENSE              MIT
├── README.md            this file
└── src/
    ├── root.zig         package root: public re-exports (Font, Bitmap, ...)
    ├── font.zig         Font facade — the main public API
    ├── read.zig         bounds-checked big-endian byte reader
    ├── sfnt.zig         sfnt container + header table parser
    ├── cmap.zig         character → glyph index mapping (formats 0/4/6/12)
    ├── kern.zig         kerning pair lookup (kern format 0)
    ├── outline.zig      glyf outline decoding (simple + composite glyphs)
    ├── raster.zig       anti-aliased cell-based scanline rasterizer
    ├── main.zig         demo CLI: text → BMP/PGM
    └── tests.zig        integration tests built around a synthetic font
```

Every source file carries full `///` documentation comments; this README mirrors them.
Internal modules are described in [Internal modules](#internal-modules); the types
consumers actually touch are covered in [Public API reference](#public-api-reference).

## Requirements

- Zig **0.16.0** or newer (the demo uses the `std.process.Init` / `std.Io` runtime API)
- No libc, no third-party dependencies

## Using as a package

Add the dependency to your `build.zig.zon`:

```sh
zig fetch --save <url-or-path-of-this-repo>
```

and wire the module into your executable in `build.zig`:

```zig
const font_dep = b.dependency("font", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("font", font_dep.module("font"));
```

Then import it in code:

```zig
const font = @import("font");
```

## Architecture overview

```
 font file bytes ([]const u8, borrowed, never copied)
        │
        ▼
 Font.init ──► sfnt.FontTables ──► table slices (head/hhea/maxp/hmtx/glyf/loca/cmap/kern)
        │                 │
        │                 ├──► cmap.CharacterMap   codepoint → glyph id
        │                 ├──► kern.KerningSubtable pair → kerning offset
        │                 └──► outline.decode        glyph id → Outline (points + flags)
        ▼
 renderText / renderGlyph / glyphMetrics
        │  (font units → device pixels, y flipped)
        ▼
 raster.renderShape ──► flatten curves ──► cell coverage ──► Bitmap (8-bit coverage)
```

- **Font units** are the font's design coordinates (scaled by `units_per_em`).
- **Device pixels** are what the rasterizer consumes; y grows downward there.
- All rendering functions take an allocator only for temporaries; nothing is cached
  between calls, which keeps the API stateless and thread-friendly.

## Coordinates and the pen model

Text is drawn with a **pen** that starts at a baseline position and advances to the
right after every glyph. A glyph's ink is placed relative to the pen:

```
            ┌──────────────┐  ─┬─
            │   glyph ink  │   │
            │     box      │   │ bearing_y (ink top above baseline)
            │              │   │
 pen ──►  ──┴──────────────┴─ ──┼── baseline  (pen_baseline_y)
 (pen_x)  │◄─────────────►│      │
          │  bearing_x    │
          └──────────────┘
          ◄──────────────►
               width         ◄──── advance_width ────► next pen position
```

- `renderGlyph`/`renderText` position the **pen**, not the bitmap corner.
- `bearing_x`/`bearing_y` from `glyphMetrics` tell you where the ink lands relative
  to the pen; `advance_width` tells you how far the pen moves.
- Fractional pen positions are allowed — the anti-aliased rasterizer handles
  subpixel placement naturally.

## Quick start

```zig
const std = @import("std");
const font = @import("font");

/// Renders one line of text into `out_pixels` (must hold width*height bytes).
fn renderBanner(
    allocator: std.mem.Allocator,
    font_data: []const u8,   // raw .ttf bytes; must outlive `typeface`
    out_pixels: []u8,
    width: usize,
    height: usize,
) !void {
    // Parse the font. Zero-copy: `font_data` is borrowed, not copied.
    var typeface = try font.Font.init(font_data);

    const text = "Hello, Zig!";
    const pixel_size: f32 = 48;
    const scale = typeface.scaleForPixelSize(pixel_size);

    const bitmap = font.Bitmap.init(@intCast(width), @intCast(height), out_pixels);
    bitmap.clear(0);

    // Baseline sits 8 px below the top edge, after the ascent.
    try typeface.renderText(allocator, text, scale, &bitmap, 8, 8 + typeface.ascentPixels(scale));
}
```

That is the whole API surface you need for basic rendering. The bitmap contains one
coverage byte per pixel: `0` = untouched, `255` = fully covered — treat it as alpha.

## Examples

### Rendering text into a bitmap

A complete, self-contained flow: measure the text, size a bitmap to fit, render.

```zig
const std = @import("std");
const font = @import("font");

fn drawText(allocator: std.mem.Allocator, font_data: []const u8) !void {
    var typeface = try font.Font.init(font_data);

    const text = "Score: 128500";
    const pixel_size: f32 = 32;
    const scale = typeface.scaleForPixelSize(pixel_size);

    // 1. Measure to size the surface (adds 8 px padding on every side).
    const text_metrics = typeface.measureText(text, scale);
    const width: usize = @as(usize, @intFromFloat(@ceil(text_metrics.width))) + 16;
    const height: usize = @as(usize, @intFromFloat(@ceil(text_metrics.height))) + 16;

    // 2. Allocate and clear the coverage bitmap.
    const pixels = try allocator.alloc(u8, width * height);
    defer allocator.free(pixels);
    const bitmap = font.Bitmap.init(@intCast(width), @intCast(height), pixels);
    bitmap.clear(0);

    // 3. Render: pen starts at (8, 8 + ascent) so nothing clips at the top.
    try typeface.renderText(
        allocator,
        text,
        scale,
        &bitmap,
        8,
        8 + typeface.ascentPixels(scale),
    );

    // `pixels` now holds 8-bit coverage — use it as alpha for white text, e.g.
    for (pixels, 0..) |coverage, i| {
        if (coverage != 0) { /* composite coverage onto your framebuffer here */ }
    }
}
```

### Rendering a single glyph

```zig
var pixels: [40 * 40]u8 = undefined;
const bitmap = font.Bitmap.init(40, 40, &pixels);
bitmap.clear(0);

const glyph_id = typeface.glyphIndexForCodepoint('g');
try typeface.renderGlyph(allocator, glyph_id, scale, &bitmap, 4, 36);
// The glyph is drawn with its baseline at y = 36 and its left edge at
// pen_x + bearing_x — exactly like a real text shaper would place it.
```

### Inspecting glyph metrics

```zig
const glyph_id = typeface.glyphIndexForCodepoint('Ä');
const metrics = typeface.glyphMetrics(allocator, glyph_id, scale);

std.debug.print("advance {d:.2}px, ink {d:.2}x{d:.2}px at ({d:.2}, {d:.2})\n", .{
    metrics.advance_width,
    metrics.width,
    metrics.height,
    metrics.bearing_x,
    metrics.bearing_y,
});

// Missing glyphs map to 0 (`.notdef`) — check explicitly:
if (typeface.glyphIndexForCodepoint('☃') == 0) {
    std.debug.print("snowman not covered by this font\n", .{});
}
```

For an empty glyph (e.g. a space) all ink fields are `0` and only `advance_width`
is meaningful.

### Multi-line text

`\n` advances the pen by the line height and restores the pen x; `\r` only breaks
kerning. `measureText` accounts for both, so sizing works the same way:

```zig
const text = "first line\nsecond line\nthird line";
const text_metrics = typeface.measureText(text, scale);
// text_metrics.height == 3 * typeface.lineHeightPixels(scale)
```

### Drawing into a framebuffer region (stride)

`Bitmap.initWithStride` embeds a rendering surface inside a larger buffer — useful
for HUD overlays on a software framebuffer:

```zig
var framebuffer: [640 * 480]u8 = undefined;
@memset(&framebuffer, 0);

// Top-left 200x40 region of a 640-wide framebuffer.
const overlay = font.Bitmap.initWithStride(200, 40, 640, &framebuffer);
try typeface.renderText(
    allocator,
    "overlay",
    scale,
    &overlay,
    4,
    4 + typeface.ascentPixels(scale),
);
```

### Building a glyph atlas

A common engine pattern: pre-render a set of glyphs once, upload the bitmap as a
texture, and remember each glyph's rectangle.

```zig
const cell_width = 32;
const cell_height = 32;
const first_codepoint: u21 = 0x21; // '!'
const last_codepoint: u21 = 0x7E;  // '~'
const glyph_total = last_codepoint - first_codepoint + 1;

const atlas_pixels = try allocator.alloc(u8, cell_width * glyph_total * cell_height);
defer allocator.free(atlas_pixels);
@memset(atlas_pixels, 0);
const atlas = font.Bitmap.init(cell_width * glyph_total, cell_height, atlas_pixels);

const AtlasEntry = struct { glyph_id: u16, x: u32, advance: f32 };
const entries = try allocator.alloc(AtlasEntry, glyph_total);
defer allocator.free(entries);

for (first_codepoint..last_codepoint + 1, 0..) |codepoint, i| {
    const glyph_id = typeface.glyphIndexForCodepoint(codepoint);
    try typeface.renderGlyph(
        allocator,
        glyph_id,
        scale,
        &atlas,
        @floatFromInt(@as(usize, i) * cell_width + 1),
        cell_height - 4, // baseline 4 px above the cell bottom
    );
    entries[i] = .{
        .glyph_id = glyph_id,
        .x = @intCast(i * cell_width),
        .advance = typeface.advanceWidthPixels(glyph_id, scale),
    };
}
// Upload `atlas_pixels` as an alpha texture; use `entries` for UVs.
```

### Converting coverage to RGBA for GPUs

The bitmap stores coverage only. To upload as a white RGBA texture:

```zig
const rgba = try allocator.alloc(u8, width * height * 4);
defer allocator.free(rgba);
for (pixels, 0..) |coverage, i| {
    rgba[i * 4 + 0] = 0xFF; // R
    rgba[i * 4 + 1] = 0xFF; // G
    rgba[i * 4 + 2] = 0xFF; // B
    rgba[i * 4 + 3] = coverage; // A
}
```

Tint by replacing the `0xFF` channels with your color. Because rendering is
max-blended into the bitmap, drawing the same glyph twice never darkens it.

### Iterating UTF-8 manually

`Utf8Iterator` is the same decoder the text functions use:

```zig
var iterator = font.Utf8Iterator{ .bytes = "héllo 🌍" };
while (iterator.next()) |codepoint| {
    const glyph_id = typeface.glyphIndexForCodepoint(codepoint);
    // draw / measure / cache ...
}
```

Invalid bytes yield `0xFFFD` (U+FFFD replacement) and the iterator always makes
progress, so no infinite loops on corrupt input.

### Loading a font file (Zig 0.16 I/O)

The library never touches the file system; loading is up to you. With Zig 0.16's
I/O interface:

```zig
var current_directory = std.Io.Dir.cwd();
const font_data = try current_directory.readFileAlloc(
    io,                                        // std.Io instance
    allocator,
    "assets/Inter-Regular.ttf",
    std.Io.Limit.limited(64 * 1024 * 1024),
);
defer allocator.free(font_data);
```

A complete runnable program (argument parsing, BMP/PGM export) lives in
`src/main.zig` — see [Command-line demo](#command-line-demo).

## Command-line demo

```sh
zig build run -- [options] [path/to/font.ttf]
```

| Option | Default | Description |
|---|---|---|
| `--text "..."` | `Hello, ZigSimpleEngine! Привет, мир! TTF 123` | Text to render |
| `--size N` | `48` | Em size in pixels (1..512) |
| `--out prefix` | `font_demo` | Output file prefix |

Writes `<prefix>.bmp` (24-bit grayscale BMP) and `<prefix>.pgm` (P5) and prints a
short report. Without a font path it tries `C:\Windows\Fonts\segoeui.ttf`, then
`arial.ttf`:

```sh
zig build run -- --text "Привет, мир!" --size 64 --out hello
# font       : 5344 glyphs, upem 2048
# text       : 11 codepoints
# bitmap     : 452x84, lit pixels 4102/37968 (10.8%)
# written    : hello.bmp, hello.pgm
```

## Public API reference

Everything below is importable from the package root:

```zig
const font = @import("font");
// font.Font, font.Bitmap, font.GlyphMetrics, font.TextMetrics,
// font.Utf8Iterator, font.Outline, font.Point
```

### `Font`

A loaded TrueType font. Immutable after `init` — safe to share freely, as long
as the backing font bytes outlive every use.

#### Fields

| Field | Type | Description |
|---|---|---|
| `tables` | `FontTables` | Parsed sfnt table set (slices into the font data) |
| `character_map` | `?CharacterMap` | Selected `cmap` subtable, `null` if the font has none |
| `kerning_subtable` | `?KerningSubtable` | Selected `kern` subtable, `null` if the font has none |
| `units_per_em` | `f32` | Em square size in font units (design space) |
| `ascender_units` | `f32` | Ascender height in font units, positive above the baseline |
| `descender_units` | `f32` | Descender depth in font units, usually negative |
| `line_gap_units` | `f32` | Recommended extra spacing between lines, in font units |

#### `Font.init`

```zig
pub fn init(font_file_data: []const u8) InitError!Font
```

Parses a TrueType font and prepares it for rendering. Performs **no allocation** —
the font stores slices into `font_file_data`.

- **`font_file_data`** — raw bytes of the whole `.ttf` file; borrowed, must outlive the font.
- **Returns** — ready-to-use font instance.
- **Errors** — see [Error sets](#error-sets): `InvalidFont`, `MissingHead`, `MissingHhea`,
  `MissingMaxp`, `MissingHmtx`, `MissingTable`, `OutOfBounds`.

#### `Font.glyphCount`

```zig
pub fn glyphCount(self: *const Font) u16
```

- **Returns** — total number of glyphs; valid glyph ids are `0 .. glyphCount() - 1`.

#### `Font.scaleForPixelSize`

```zig
pub fn scaleForPixelSize(self: *const Font, pixel_size: f32) f32
```

Converts a requested em size into the scale factor used by every other method.
Multiply any font-unit value by it to get pixels.

- **`pixel_size`** — desired em square size in pixels.
- **Returns** — `pixel_size / units_per_em` (or `0` for a broken font).

#### `Font.lineHeightPixels`

```zig
pub fn lineHeightPixels(self: *const Font, pixel_scale: f32) f32
```

- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — distance between consecutive baselines in pixels:
  `(ascender - descender + line_gap) * scale`.

#### `Font.ascentPixels`

```zig
pub fn ascentPixels(self: *const Font, pixel_scale: f32) f32
```

- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — baseline-to-line-top distance in pixels. A convenient y position
  for the first text line inside a bitmap.

#### `Font.descentPixels`

```zig
pub fn descentPixels(self: *const Font, pixel_scale: f32) f32
```

- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — baseline-to-line-bottom distance in pixels (usually negative).

#### `Font.glyphIndexForCodepoint`

```zig
pub fn glyphIndexForCodepoint(self: *const Font, codepoint: u21) u16
```

- **`codepoint`** — Unicode scalar value.
- **Returns** — glyph index, or `0` (`.notdef`) when the font has no `cmap` or the
  codepoint is unmapped. Includes the Symbol `(3,0)` `0xF000` fallback.

#### `Font.kerningInFontUnits`

```zig
pub fn kerningInFontUnits(self: *const Font, left_glyph_id: u16, right_glyph_id: u16) f32
```

- **`left_glyph_id`** — glyph drawn first.
- **`right_glyph_id`** — glyph drawn immediately after.
- **Returns** — kerning offset in **font units** to add to the pen advance between
  the pair; `0` when unkerned or no `kern` table. Multiply by the scale for pixels.

#### `Font.advanceWidthPixels`

```zig
pub fn advanceWidthPixels(self: *const Font, glyph_id: u16, pixel_scale: f32) f32
```

- **`glyph_id`** — glyph to query.
- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — horizontal pen advance in pixels.

#### `Font.glyphMetrics`

```zig
pub fn glyphMetrics(
    self: *const Font,
    allocator: std.mem.Allocator,
    glyph_id: u16,
    pixel_scale: f32,
) GlyphMetrics
```

Measures one glyph. The outline is decoded only to compute the ink box.

- **`allocator`** — temporary allocator for decoding (nothing is retained).
- **`glyph_id`** — glyph to measure.
- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — [`GlyphMetrics`](#glyphmetrics); for empty glyphs only
  `advance_width` is meaningful.
- **Errors** — none surfaced: decode failures yield zeroed ink fields.

#### `Font.renderGlyph`

```zig
pub fn renderGlyph(
    self: *const Font,
    allocator: std.mem.Allocator,
    glyph_id: u16,
    pixel_scale: f32,
    destination_bitmap: *const Bitmap,
    pen_x: f32,
    pen_baseline_y: f32,
) RenderError!void
```

Renders one glyph with pen-position placement. Coverage is **max-blended** into
the destination; empty glyphs and glyphs fully outside the bitmap are skipped.

- **`allocator`** — temporary allocator for decoding.
- **`glyph_id`** — glyph to render.
- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **`destination_bitmap`** — coverage bitmap drawn into.
- **`pen_x`** — horizontal pen position in pixels (fractional values allowed).
- **`pen_baseline_y`** — baseline y position in pixels.
- **Errors** — `OutOfMemory`.

#### `Font.measureText`

```zig
pub fn measureText(self: *const Font, utf8_text: []const u8, pixel_scale: f32) TextMetrics
```

Measures a text run without drawing. Handles kerning, `\n` and `\r` exactly like
`renderText`, so it can be used to size a bitmap.

- **`utf8_text`** — text to measure; invalid bytes count as U+FFFD.
- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **Returns** — [`TextMetrics`](#textmetrics).

#### `Font.renderText`

```zig
pub fn renderText(
    self: *const Font,
    allocator: std.mem.Allocator,
    utf8_text: []const u8,
    pixel_scale: f32,
    destination_bitmap: *const Bitmap,
    pen_start_x: f32,
    pen_start_baseline_y: f32,
) RenderError!void
```

Renders a UTF-8 text run. The pen advances by each glyph's kerned advance;
`\n` moves to the next line (by the line height, restoring the start x), `\r`
only breaks kerning. Max-blended, so overlaps never darken.

- **`allocator`** — temporary allocator used while decoding each outline.
- **`utf8_text`** — text to render; invalid bytes render as `.notdef`.
- **`pixel_scale`** — factor from `scaleForPixelSize`.
- **`destination_bitmap`** — coverage bitmap drawn into.
- **`pen_start_x`** — starting pen x in pixels.
- **`pen_start_baseline_y`** — starting baseline y in pixels.
- **Errors** — `OutOfMemory`.

### `GlyphMetrics`

Scaled bounding box and advance of a single glyph (all values in pixels).

| Field | Type | Description |
|---|---|---|
| `advance_width` | `f32` | Pen advance after drawing the glyph |
| `width` | `f32` | Ink box width (`0` for empty glyphs) |
| `height` | `f32` | Ink box height (`0` for empty glyphs) |
| `bearing_x` | `f32` | Pen-to-left-ink-edge distance |
| `bearing_y` | `f32` | Baseline-to-ink-top distance |

### `TextMetrics`

Measured extents of a whole text run (all values in pixels).

| Field | Type | Description |
|---|---|---|
| `width` | `f32` | Width of the widest line |
| `height` | `f32` | Line count × `lineHeightPixels` |

### `Bitmap`

An 8-bit coverage buffer. One byte per pixel: `0` untouched, `255` fully covered.
`stride` allows a bitmap to live inside a larger buffer.

| Field | Type | Description |
|---|---|---|
| `width` | `u32` | Usable pixels per row |
| `height` | `u32` | Row count |
| `stride` | `u32` | Bytes between row starts (≥ `width`) |
| `data` | `[]u8` | Pixel storage |

#### `Bitmap.init`

```zig
pub fn init(width: u32, height: u32, data: []u8) Bitmap
```

Tightly packed bitmap (`stride == width`).

- **`width`/`height`** — surface dimensions.
- **`data`** — must hold at least `width * height` bytes.
- **Returns** — the bitmap.

#### `Bitmap.initWithStride`

```zig
pub fn initWithStride(width: u32, height: u32, stride: u32, data: []u8) Bitmap
```

Bitmap inside a larger buffer (see the [framebuffer example](#drawing-into-a-framebuffer-region-stride)).

- **`width`/`height`** — usable surface dimensions.
- **`stride`** — bytes between row starts, `≥ width`.
- **`data`** — must hold at least `(height - 1) * stride + width` bytes.
- **Returns** — the bitmap.

#### `Bitmap.pixelPointerAt`

```zig
pub fn pixelPointerAt(self: *const Bitmap, x: u32, y: u32) ?*u8
```

- **`x`/`y`** — zero-based column and row.
- **Returns** — mutable pointer to the coverage byte, or `null` when outside.

#### `Bitmap.clear`

```zig
pub fn clear(self: *const Bitmap, fill_value: u8) void
```

- **`fill_value`** — coverage byte written to every usable pixel.

### `Utf8Iterator`

Incremental UTF-8 decoder — the same one the text functions use. Malformed
sequences yield `0xFFFD` and resynchronize on the next byte.

| Field | Type | Description |
|---|---|---|
| `bytes` | `[]const u8` | Byte slice being decoded |
| `byte_offset` | `usize` | Index of the next byte to decode |

#### `Utf8Iterator.next`

```zig
pub fn next(self: *Utf8Iterator) ?u21
```

- **Returns** — the next codepoint, `0xFFFD` for malformed input, or `null` when
  the input is consumed.

### `Outline` and `Point`

`Outline` is the decoded shape of one glyph: a flat `points: []Point` list, a
parallel `on_curve_flags: []bool` list (`false` = quadratic control point), one
`contours: []ContourSpan` per contour, and the bounding box (`min_x`, `min_y`,
`max_x`, `max_y`, plus `is_empty`). The type is exported for consumers who want
to inspect shapes; decoding is performed internally by the metrics and rendering
functions. `Point` is `{ x: f32, y: f32 }` — font units (y up) inside outlines,
device pixels (y down) inside the rasterizer.

### Error sets

| Error set | Where | Members |
|---|---|---|
| `Font.InitError` | `Font.init` | `InvalidFont` — bad sfnt header; `MissingHead` / `MissingHhea` / `MissingMaxp` / `MissingHmtx` — required table absent or truncated; `MissingTable` — no `glyf`/`loca` (CFF-style font); `OutOfBounds` — file truncated mid-directory |
| `Font.RenderError` | `renderGlyph`, `renderText` | `OutOfMemory` |
| `DecodeError` *(internal)* | outline decoding | `OutOfMemory`, `InvalidGlyph` — malformed glyph bytes |
| `ParseError` *(internal)* | table parsing | `InvalidFont`, `MissingTable`, `MissingHead`, `MissingHhea`, `MissingMaxp`, `MissingHmtx` |
| `ReadError` *(internal)* | byte reading | `OutOfBounds` |

## Internal modules

These modules are implementation details, but every declaration carries full
`///` documentation in the source, and the files can be imported directly if you
vendor the source tree.

### Module: `read.zig`

Bounds-checked big-endian reading primitives.

| Declaration | Description |
|---|---|
| `Reader` | Sequential reader over a byte slice; failed reads never move the position |
| `Reader.init(data)` | Create a reader at offset 0 |
| `Reader.remainingByteCount()` | Bytes left until the end of the buffer |
| `Reader.seekToAbsoluteOffset(offset)` | Jump to an absolute position |
| `Reader.skipBytes(n)` | Advance without interpreting |
| `Reader.readByte()` / `readUInt16()` / `readInt16()` / `readUInt32()` / `readInt32()` | Read one big-endian value and advance |
| `Reader.peekUInt16At(offset)` | Read a `u16` at a reader-relative offset without advancing |
| `bigEndianUInt16At(data, offset)` / `bigEndianInt16At` / `bigEndianUInt32At` | Read a value at an absolute offset in any slice |

All of them return `error.OutOfBounds` instead of panicking on truncation.

### Module: `sfnt.zig`

The sfnt container parser and typed accessors for the fixed-layout tables.

| Declaration | Description |
|---|---|
| `FontTables.parse(font_file_data)` | Walk the table directory, validate ranges, collect table slices |
| `FontTables.unitsPerEm()` | Em square size (falls back to 1000 on a zero value) |
| `FontTables.glyphCount()` | Total glyph count from `maxp` |
| `FontTables.ascender()` / `descender()` / `lineGap()` | Vertical metrics from `hhea` (font units) |
| `FontTables.usesLongLocaFormat()` | `true` when `loca` entries are 32-bit |
| `FontTables.horizontalMetricsCount()` | Explicit `hmtx` record count (clamped to glyph count) |
| `FontTables.glyphByteRange(glyph_id)` | `[start, end)` byte range of a glyph inside `glyf` |
| `FontTables.glyphByteData(glyph_id)` | Raw `glyf` bytes of one glyph (empty for blank glyphs) |
| `FontTables.advanceWidthOfGlyph(glyph_id)` | Advance width in font units (last record reused past the count) |

### Module: `cmap.zig`

Character mapping. `CharacterMap.selectBestSubtable` scores every encoding record
by format capability and Unicode suitability, then `glyphIndexForCodepoint`
dispatches to the format decoder:

| Format | Coverage | Lookup strategy |
|---|---|---|
| 0 | 0x00–0xFF | Flat 256-byte table |
| 4 | BMP (≤ 0xFFFF) | Binary search over segments; delta or offset-indirect glyph ids |
| 6 | One contiguous range | Direct indexing |
| 12 | Full Unicode | Binary search over sorted groups |

The Symbol encoding `(3,0)` additionally retries with the `0xF000 + codepoint`
remap when the direct lookup misses.

### Module: `kern.zig`

Legacy pairwise kerning.

| Declaration | Description |
|---|---|
| `KerningSubtable.selectFormatZeroSubtable(kern_table)` | Pick the first format 0 subtable (accepts 16-bit and OpenType 1.0 headers) |
| `KerningSubtable.kerningValue(left_glyph_id, right_glyph_id)` | Binary search over the sorted `(left << 16) \| right` keys; returns font units |

GPOS kerning is not supported (see [Limitations](#supported-features-and-limitations)).

### Module: `outline.zig`

`glyf` decoding into resolution-independent shapes.

| Declaration | Description |
|---|---|
| `decode(allocator, tables, glyph_id)` | Decode one glyph into an arena-owned `Outline`; composites are expanded recursively (depth ≤ 8) with transforms baked in |
| `Point` | `{ x: f32, y: f32 }` in font units |
| `ContourSpan` | `{ first_point_index, point_count }` — one contour inside the flat list |
| `Outline` | Points, on-curve flags, contour spans, bounding box, `is_empty`, `deinit()` |
| `GlyphTransform` | Affine matrix (`xx, yx, xy, yy, offset_x, offset_y`) used for composite components |

The decoder skips hinting instructions and computes bounding boxes from decoded
points (composite headers are often stale). Flag run-length repeats, short and
long delta encodings, F2Dot14 scales and 2×2 matrices are all handled.

### Module: `raster.zig`

The anti-aliased rasterizer. Pipeline:

1. **Contour emission** — resolves implied on-curve points (TrueType allows
   consecutive off-curve points; their midpoint is implied) and rotates the loop
   to start on an on-curve point.
2. **Flattening** — every quadratic Bézier is subdivided until the control point
   is within `default_tolerance` (0.2 px) of the chord.
3. **Cell deposition** — each segment is clipped to the bitmap, split at every
   integer row *and* column boundary, and each cell piece deposits its exact
   signed trapezoid (`cover` and `area` sums). This is the same scheme FreeType's
   smooth renderer uses, which is what keeps shallow curves artifact-free.
4. **Row sweep** — per row, `coverage = |running_cover + (c+1)·cover − area|`
   converts deposits into 8-bit alpha with the nonzero winding rule, max-blended
   into the destination.

| Declaration | Description |
|---|---|
| `Bitmap` | Coverage surface (see [public API](#bitmap)) |
| `renderShape(allocator, bitmap, points, on_curve_flags, contour_spans, tolerance)` | Fill a shape in device pixels |
| `LineSegment` | `{ start_x, start_y, end_x, end_y }` in device pixels |
| `default_tolerance` | 0.2 px curve flattening tolerance |

## Supported features and limitations

| Feature | Status |
|---|---|
| TrueType outlines (`glyf`) | ✅ full support |
| Composite glyphs (scale, x/y scale, 2×2) | ✅ full support |
| `cmap` 0 / 4 / 6 / 12 + Symbol fallback | ✅ full support |
| `kern` format 0 | ✅ supported |
| Grayscale anti-aliasing, subpixel positioning | ✅ supported |
| UTF-8 text, kerning, `\n` / `\r` | ✅ supported |
| CFF/OTF outlines (`.otf`) | ❌ rejected (`error.MissingTable`) |
| GPOS kerning | ❌ ignored (legacy `kern` only) |
| Hinting | ❌ none (unhinted AA rendering) |
| Vertical text, color fonts (CBDT/sbix), variable fonts | ❌ out of scope |
| WOFF/WOFF2 containers | ❌ raw sfnt only |

## Testing

```sh
zig build test
```

The suite builds a **synthetic TrueType font byte-by-byte** in memory (table
directory, `head`, `hhea`, `maxp`, `hmtx`, `cmap` format 4, long `loca`, `glyf`
with a triangle and a half-scale composite glyph, and a `kern` table) and then
verifies the whole pipeline against known answers:

- sfnt parsing and table extraction
- `cmap` format 4 lookups (hits, misses, delta encoding)
- simple and composite outline decoding with transforms
- kerning pair lookup
- glyph metrics against hand-computed values
- rasterizer exactness (rectangle interior = 255, exterior = 0, bounded AA border)
- truncated-input rejection

No external font files are required, so the tests are deterministic and
hermetic. `src/tests.zig` documents the synthetic font layout in detail.

## License

MIT — see [LICENSE](LICENSE).


