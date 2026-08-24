//! Command-line demo for the font library.
//!
//! Renders a UTF-8 text string with a TrueType font into an 8-bit coverage
//! bitmap and writes it out as a 24-bit BMP (grayscale) and a PGM file.
//! Without an explicit font path, common Windows system fonts are tried.

const std = @import("std");
const Io = std.Io;

const font = @import("font");

/// Text rendered when the `--text` option is not given.
const default_render_text = "Hello, ZigSimpleEngine! Привет, мир! TTF 123";

/// Program entry point: parses arguments, renders the text and writes the
/// output files. On error prints the error name to stdout and exits with
/// status code 1.
///
/// Parameters:
///     `init`: Process initialization context provided by the Zig runtime,
///         giving access to command line arguments, the I/O implementation
///         and an arena allocator.
///
/// Errors:
///     Forwards any error from `run`.
pub fn main(init: std.process.Init) !void {
    const arena_allocator: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    run(init, arena_allocator, io, stdout_writer) catch |run_error| {
        try stdout_writer.print("error: {s}\n", .{@errorName(run_error)});
        try stdout_writer.flush();
        std.process.exit(1);
    };
    try stdout_writer.flush();
}

/// Loads the font, measures and renders the requested text and writes the
/// resulting bitmap to disk.
///
/// Parameters:
///     `init`: Process initialization context used for command line arguments.
///     `arena_allocator`: Arena allocator for the font data and the bitmap.
///     `io`: I/O implementation used for file access.
///     `stdout_writer`: Buffered writer the report is printed to.
///
/// Errors:
///     error.NoFontFound: No font path was given and none of the default
///         system fonts could be read.
///     Any file or font parsing error is propagated to the caller.
fn run(
    init: std.process.Init,
    arena_allocator: std.mem.Allocator,
    io: Io,
    stdout_writer: *Io.Writer,
) !void {
    const command_line_arguments = try init.minimal.args.toSlice(arena_allocator);

    var render_text: []const u8 = default_render_text;
    var pixel_size: f32 = 48;
    var output_file_prefix: []const u8 = "font_demo";
    var font_file_path: ?[]const u8 = null;

    var argument_index: usize = 1;
    while (argument_index < command_line_arguments.len) : (argument_index += 1) {
        const argument = command_line_arguments[argument_index];
        if (std.mem.eql(u8, argument, "--text") and argument_index + 1 < command_line_arguments.len) {
            argument_index += 1;
            render_text = command_line_arguments[argument_index];
        } else if (std.mem.eql(u8, argument, "--size") and argument_index + 1 < command_line_arguments.len) {
            argument_index += 1;
            pixel_size = std.fmt.parseFloat(f32, command_line_arguments[argument_index]) catch 48;
            if (!(pixel_size > 0 and pixel_size <= 512)) pixel_size = 48;
        } else if (std.mem.eql(u8, argument, "--out") and argument_index + 1 < command_line_arguments.len) {
            argument_index += 1;
            output_file_prefix = command_line_arguments[argument_index];
        } else if (std.mem.eql(u8, argument, "--help")) {
            try stdout_writer.print(
                \\usage: font [options] [path/to/font.ttf]
                \\  --text "..."   text to render
                \\  --size N       pixel size (default 48)
                \\  --out prefix   output files prefix (default font_demo)
                \\
            , .{});
            try stdout_writer.flush();
            return;
        } else {
            font_file_path = argument;
        }
    }

    const font_file_data = blk: {
        if (font_file_path) |explicit_path| break :blk try loadFontFile(io, arena_allocator, explicit_path);
        inline for (.{ "C:\\Windows\\Fonts\\segoeui.ttf", "C:\\Windows\\Fonts\\arial.ttf" }) |system_font_path| {
            if (loadFontFile(io, arena_allocator, system_font_path)) |loaded_data| break :blk loaded_data else |_| {}
        }
        return error.NoFontFound;
    };

    var typeface = try font.Font.init(font_file_data);

    const pixel_scale = typeface.scaleForPixelSize(pixel_size);
    const text_metrics = typeface.measureText(render_text, pixel_scale);

    const padding: f32 = 10;
    const bitmap_width: usize = @max(1, @as(usize, @intFromFloat(@ceil(text_metrics.width + padding * 2))));
    const bitmap_height: usize = @max(1, @as(usize, @intFromFloat(@ceil(text_metrics.height + padding * 2))));

    const pixel_buffer = try arena_allocator.alloc(u8, bitmap_width * bitmap_height);
    const bitmap = font.Bitmap.init(@intCast(bitmap_width), @intCast(bitmap_height), pixel_buffer);
    bitmap.clear(0);

    try typeface.renderText(arena_allocator, render_text, pixel_scale, &bitmap, padding, padding + typeface.ascentPixels(pixel_scale));

    var lit_pixel_count: usize = 0;
    for (pixel_buffer) |coverage_value| {
        if (coverage_value > 127) lit_pixel_count += 1;
    }

    const bmp_output_path = try std.fmt.allocPrint(arena_allocator, "{s}.bmp", .{output_file_prefix});
    const pgm_output_path = try std.fmt.allocPrint(arena_allocator, "{s}.pgm", .{output_file_prefix});

    try writeBmpFile(io, arena_allocator, bmp_output_path, &bitmap);
    try writePgmFile(io, arena_allocator, pgm_output_path, &bitmap);

    try stdout_writer.print("font       : {d} glyphs, upem {d:.0}\n", .{ typeface.glyphCount(), typeface.units_per_em });
    try stdout_writer.print("text       : {d} codepoints\n", .{countCodepoints(render_text)});
    try stdout_writer.print("bitmap     : {d}x{d}, lit pixels {d}/{d} ({d:.1}%)\n", .{
        bitmap_width, bitmap_height, lit_pixel_count, bitmap_width * bitmap_height, @as(f32, @floatFromInt(lit_pixel_count)) * 100 / @as(f32, @floatFromInt(bitmap_width * bitmap_height)),
    });
    try stdout_writer.print("written    : {s}, {s}\n", .{ bmp_output_path, pgm_output_path });
}

/// Reads a whole font file into memory.
///
/// Parameters:
///     `io`: I/O implementation used to open and read the file.
///     `allocator`: Allocator that receives the file contents.
///     `path`: Path of the font file to load.
///
/// Returns:
///     Caller-owned bytes of the whole file.
///
/// Errors:
///     Any file open or read error is propagated.
fn loadFontFile(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var current_directory = Io.Dir.cwd();
    return current_directory.readFileAlloc(io, path, allocator, Io.Limit.limited(64 * 1024 * 1024));
}

/// Counts the Unicode codepoints of a UTF-8 text run.
///
/// Parameters:
///     `utf8_text`: Text to scan. Invalid bytes count as one codepoint each.
///
/// Returns:
///     Number of decoded codepoints.
fn countCodepoints(utf8_text: []const u8) usize {
    var utf8_iterator = font.Utf8Iterator{ .bytes = utf8_text };
    var codepoint_count: usize = 0;
    while (utf8_iterator.next()) |_| codepoint_count += 1;
    return codepoint_count;
}

/// Writes the coverage bitmap as a bottom-up 24-bit BMP with the coverage
/// byte replicated into all three channels (grayscale).
///
/// Parameters:
///     `io`: I/O implementation used to create and write the file.
///     `allocator`: Allocator for the in-memory image and the writer buffer.
///     `path`: Path of the BMP file to create.
///     `bitmap`: Coverage bitmap to encode.
///
/// Errors:
///     Any allocation or file write error is propagated.
fn writeBmpFile(io: Io, allocator: std.mem.Allocator, path: []const u8, bitmap: *const font.Bitmap) !void {
    const width: usize = bitmap.width;
    const height: usize = bitmap.height;
    const row_stride_bytes = (width * 3 + 3) & ~@as(usize, 3);
    const file_size_bytes = 54 + row_stride_bytes * height;

    const file_bytes = try allocator.alloc(u8, file_size_bytes);
    defer allocator.free(file_bytes);
    @memset(file_bytes, 0);

    file_bytes[0] = 'B';
    file_bytes[1] = 'M';
    writeIntLittleEndian(u32, file_bytes[2..6], @intCast(file_size_bytes));
    writeIntLittleEndian(u32, file_bytes[10..14], 54);
    writeIntLittleEndian(u32, file_bytes[14..18], 40);
    writeIntLittleEndian(i32, file_bytes[18..22], @intCast(width));
    writeIntLittleEndian(i32, file_bytes[22..26], @intCast(height));
    writeIntLittleEndian(u16, file_bytes[26..28], 1);
    writeIntLittleEndian(u16, file_bytes[28..30], 24);
    writeIntLittleEndian(u32, file_bytes[34..38], @intCast(row_stride_bytes * height));

    var row_index: usize = 0;
    while (row_index < height) : (row_index += 1) {
        const source_row_pixels = bitmap.data[(height - 1 - row_index) * bitmap.stride ..][0..width];
        const destination_row_bytes = file_bytes[54 + row_index * row_stride_bytes ..][0 .. width * 3];
        for (source_row_pixels, 0..) |coverage_value, column_index| {
            destination_row_bytes[column_index * 3] = coverage_value;
            destination_row_bytes[column_index * 3 + 1] = coverage_value;
            destination_row_bytes[column_index * 3 + 2] = coverage_value;
        }
    }

    try writeFileBytes(io, allocator, path, file_bytes);
}

/// Writes the coverage bitmap as a binary PGM (P5) grayscale image.
///
/// Parameters:
///     `io`: I/O implementation used to create and write the file.
///     `allocator`: Allocator for the in-memory image and the writer buffer.
///     `path`: Path of the PGM file to create.
///     `bitmap`: Coverage bitmap to encode.
///
/// Errors:
///     Any allocation or file write error is propagated.
fn writePgmFile(io: Io, allocator: std.mem.Allocator, path: []const u8, bitmap: *const font.Bitmap) !void {
    var header_buffer: [64]u8 = undefined;
    const file_header = try std.fmt.bufPrint(&header_buffer, "P5\n{d} {d}\n255\n", .{ bitmap.width, bitmap.height });

    const file_size_bytes = file_header.len + bitmap.width * bitmap.height;
    const file_bytes = try allocator.alloc(u8, file_size_bytes);
    defer allocator.free(file_bytes);

    @memcpy(file_bytes[0..file_header.len], file_header);
    var row_index: usize = 0;
    while (row_index < bitmap.height) : (row_index += 1) {
        const source_row_pixels = bitmap.data[row_index * bitmap.stride ..][0..bitmap.width];
        const destination_offset = file_header.len + row_index * bitmap.width;
        @memcpy(file_bytes[destination_offset..][0..bitmap.width], source_row_pixels);
    }

    try writeFileBytes(io, allocator, path, file_bytes);
}

/// Creates a file and writes a complete byte buffer into it.
///
/// Parameters:
///     `io`: I/O implementation used to create and write the file.
///     `allocator`: Allocator for the buffered writer's scratch buffer.
///     `path`: Path of the file to create (overwritten if it exists).
///     `file_bytes`: Complete file content to write.
///
/// Errors:
///     Any allocation, file creation or write error is propagated.
fn writeFileBytes(io: Io, allocator: std.mem.Allocator, path: []const u8, file_bytes: []const u8) !void {
    var current_directory = Io.Dir.cwd();
    var output_file = try current_directory.createFile(io, path, .{});
    defer output_file.close(io);

    const writer_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(writer_buffer);
    var file_writer = output_file.writer(io, writer_buffer);
    try file_writer.interface.writeAll(file_bytes);
    try file_writer.interface.flush();
}

/// Writes one integer in little-endian byte order into a byte buffer.
///
/// Parameters:
///     `IntegerType`: Comptime integer type to encode; the destination must
///         hold exactly `@sizeOf(IntegerType)` bytes.
///     `destination_bytes`: Buffer slice receiving the encoded bytes.
///     `value`: Integer value to encode.
fn writeIntLittleEndian(comptime IntegerType: type, destination_bytes: []u8, value: IntegerType) void {
    std.mem.writeInt(IntegerType, destination_bytes[0..@sizeOf(IntegerType)], value, .little);
}
