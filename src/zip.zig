//! Taking a file out of a zip archive held in memory, for apps whose releases are zipped.

const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;

/// The content of the first file of `archive` whose name ends with `suffix`, e.g. ".app"
pub fn extract(allocator: std.mem.Allocator, archive: []const u8, suffix: []const u8) ![]u8 {
    // std.zip.EndRecord.findBuffer does not compile in this Zig version
    const end_at = std.mem.lastIndexOf(u8, archive, &zip.end_record_sig) orelse return error.NotAZip;
    const end = try read(zip.EndRecord, archive, end_at);
    var offset: usize = end.central_directory_offset;
    for (0..end.record_count_total) |_| {
        const header = try read(zip.CentralDirectoryFileHeader, archive, offset);
        if (!std.mem.eql(u8, &header.signature, &zip.central_file_header_sig)) return error.NotAZip;
        const name_start = offset + @sizeOf(zip.CentralDirectoryFileHeader);
        if (name_start + header.filename_len > archive.len) return error.NotAZip;
        const name = archive[name_start..][0..header.filename_len];
        offset = name_start + header.filename_len + header.extra_len + header.comment_len;
        if (!std.mem.endsWith(u8, name, suffix)) continue;
        return entryData(allocator, archive, header);
    }
    return error.FileNotInZip;
}

fn read(comptime T: type, bytes: []const u8, offset: usize) !T {
    if (offset + @sizeOf(T) > bytes.len) return error.NotAZip;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..][0..@sizeOf(T)]);
    return value;
}

fn entryData(allocator: std.mem.Allocator, archive: []const u8, header: zip.CentralDirectoryFileHeader) ![]u8 {
    const local = try read(zip.LocalFileHeader, archive, header.local_file_header_offset);
    if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig)) return error.NotAZip;
    const start = header.local_file_header_offset + @sizeOf(zip.LocalFileHeader) + local.filename_len + local.extra_len;
    // The sizes of the central directory are always set, the local ones may be left at 0
    if (start + header.compressed_size > archive.len) return error.NotAZip;
    const compressed = archive[start..][0..header.compressed_size];

    const data = try allocator.alloc(u8, header.uncompressed_size);
    errdefer allocator.free(data);
    switch (header.compression_method) {
        .store => {
            if (compressed.len != data.len) return error.NotAZip;
            @memcpy(data, compressed);
        },
        .deflate => {
            var input: std.Io.Reader = .fixed(compressed);
            var window: [flate.max_window_len]u8 = undefined;
            var inflate: flate.Decompress = .init(&input, .raw, &window);
            inflate.reader.readSliceAll(data) catch return error.BrokenZip;
        },
        else => return error.UnknownCompression,
    }
    if (std.hash.Crc32.hash(data) != header.crc32) return error.BrokenZip;
    return data;
}

test "extract takes the app out of a deflated archive" {
    const data = try extract(std.testing.allocator, @embedFile("testdata/app.zip"), ".app");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(20 + 9 * 200, data.len);
    try std.testing.expectEqualStrings("\x7fELF", data[0..4]);
    try std.testing.expectEqualStrings("app body ", data[20..29]);
}

test "extract reads stored files and tells what is missing" {
    const data = try extract(std.testing.allocator, @embedFile("testdata/stored.zip"), ".app");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("stored body", data);
    try std.testing.expectError(error.FileNotInZip, extract(std.testing.allocator, @embedFile("testdata/stored.zip"), ".epub"));
    try std.testing.expectError(error.NotAZip, extract(std.testing.allocator, "not a zip", ".app"));
}
