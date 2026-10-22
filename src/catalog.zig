//! The apps on offer (catalog.txt) and the builds their releases publish (version.txt).

const std = @import("std");
const i18n = @import("i18n.zig");

/// Where the catalog is read from. The copy built into the app is used when it cannot be loaded.
pub const url = "https://raw.githubusercontent.com/Aluriak/pb-apps/main/catalog.txt";
pub const built_in = @embedFile("catalog_txt");

pub const App = struct {
    id: []const u8,
    /// GitHub owner/name
    repo: []const u8,
    /// Start of the names of its release files: <asset>-<platform>.bin
    asset: []const u8,
    /// Its name in the applications folder, without ".app"
    file: []const u8,
    names: [2][]const u8,
    descriptions: [2][]const u8,
    /// Earlier names of the app file, comma separated
    old_files: []const u8 = "",

    pub fn name(app: App) []const u8 {
        return app.names[@backingInt(i18n.lang)];
    }

    pub fn description(app: App) []const u8 {
        return app.descriptions[@backingInt(i18n.lang)];
    }
};

/// Reads catalog.txt. The strings point into `text`. Lines that cannot be read are skipped.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]App {
    var apps: std.ArrayList(App) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields: [9][]const u8 = @splat("");
        var it = std.mem.splitScalar(u8, line, '\t');
        var count: usize = 0;
        while (it.next()) |field| : (count += 1) {
            if (count == fields.len) break;
            fields[count] = std.mem.trim(u8, field, " ");
        }
        // The old file names are optional
        if (count < 8 or !valid(fields[0]) or !valid(fields[2]) or !valid(fields[3])) continue;
        if (std.mem.indexOfScalar(u8, fields[8], '/') != null) continue;

        try apps.append(allocator, .{
            .id = fields[0],
            .repo = fields[1],
            .asset = fields[2],
            .file = fields[3],
            .names = .{ fields[4], fields[5] },
            .descriptions = .{ fields[6], fields[7] },
            .old_files = fields[8],
        });
    }
    return apps.toOwnedSlice(allocator);
}

/// Ids and asset names end up in paths and URLs
fn valid(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return false;
    }
    return true;
}

pub const Channel = enum {
    /// Releases made from a tag
    stable,
    /// Built from every change of the code
    nightly,

    pub fn parse(text: []const u8) Channel {
        return std.meta.stringToEnum(Channel, std.mem.trim(u8, text, " \t\r\n")) orelse .stable;
    }

    /// Where its version.txt is, below https://github.com/<repo>/releases/
    pub fn path(channel: Channel) []const u8 {
        return switch (channel) {
            // "latest" is the newest release that is not a pre-release, so never a nightly build
            .stable => "latest/download",
            .nightly => "download/nightly",
        };
    }
};

/// A build of an app, as its version.txt describes it
pub const Build = struct {
    /// "release", "nightly" or "dev"
    kind: []const u8 = "",
    /// The version from build.zig.zon, e.g. "0.3.1"
    version: []const u8 = "",
    /// The git commit it was built from
    commit: []const u8 = "",
    /// The tag of the release its files are attached to, e.g. "nightly" or "v0.4.0"
    tag: []const u8 = "",
    /// When it was built, e.g. "2026-10-17"
    date: []const u8 = "",

    /// Reads the "key=value" lines of a version.txt. The slices point into `text`.
    pub fn parse(text: []const u8) !Build {
        var build: Build = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " ");
            const value = std.mem.trim(u8, line[eq + 1 ..], " ");
            if (std.mem.eql(u8, key, "channel")) build.kind = value;
            if (std.mem.eql(u8, key, "version")) build.version = value;
            if (std.mem.eql(u8, key, "commit")) build.commit = value;
            if (std.mem.eql(u8, key, "tag")) build.tag = value;
            if (std.mem.eql(u8, key, "date")) build.date = value;
        }
        if (build.version.len == 0 or build.commit.len == 0 or !validTag(build.tag)) return error.IncompleteVersionFile;
        return build;
    }

    /// "0.4.0 (nightly, 9606907, 2026-10-17)"
    pub fn describe(build: Build, buf: []u8) []const u8 {
        const commit = build.commit[0..@min(7, build.commit.len)];
        const text = if (build.date.len > 0)
            std.fmt.bufPrint(buf, "{s} ({s}, {s}, {s})", .{ build.version, build.kind, commit, build.date })
        else
            std.fmt.bufPrint(buf, "{s} ({s}, {s})", .{ build.version, build.kind, commit });
        return text catch buf[0..0];
    }

    /// Whether two builds come from the same commit. Either may be shortened.
    pub fn sameCommit(a: Build, b: Build) bool {
        const len = @min(a.commit.len, b.commit.len);
        return len >= 7 and std.mem.eql(u8, a.commit[0..len], b.commit[0..len]);
    }
};

/// Tags end up in URLs: letters, digits, dots and dashes
fn validTag(tag: []const u8) bool {
    if (tag.len == 0) return false;
    for (tag) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '.' and char != '_') return false;
    }
    return true;
}

/// The address of the version.txt of `app` on `channel`
pub fn versionUrl(buf: []u8, app: App, channel: Channel) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "https://github.com/{s}/releases/{s}/version.txt", .{ app.repo, channel.path() }, 0);
}

/// The address of the app file of `build` for `platform`
pub fn binaryUrl(buf: []u8, app: App, build: Build, platform: []const u8) ![:0]const u8 {
    if (!validTag(build.tag)) return error.IncompleteVersionFile;
    return std.fmt.bufPrintSentinel(buf, "https://github.com/{s}/releases/download/{s}/{s}-{s}.bin", .{ app.repo, build.tag, app.asset, platform }, 0);
}

/// The address of the notes of `build`: what changed since the release before it
pub fn notesUrl(buf: []u8, app: App, build: Build) ![:0]const u8 {
    if (!validTag(build.tag)) return error.IncompleteVersionFile;
    return std.fmt.bufPrintSentinel(buf, "https://github.com/{s}/releases/download/{s}/notes.txt", .{ app.repo, build.tag }, 0);
}

/// The first lines of release notes, one change per line, each cut to `width` bytes,
/// with "…" when there are more. Cuts do not split a UTF-8 character.
pub fn shortNotes(buf: []u8, notes: []const u8, max_lines: usize, width: usize) []const u8 {
    var len: usize = 0;
    var lines = std.mem.tokenizeAny(u8, notes, "\r\n");
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (count == max_lines) {
            const more = "\n…";
            if (len + more.len <= buf.len) {
                @memcpy(buf[len..][0..more.len], more);
                len += more.len;
            }
            break;
        }
        var cut = @min(line.len, width);
        while (cut < line.len and cut > 0 and line[cut] & 0xc0 == 0x80) cut -= 1;
        const sep: []const u8 = if (count == 0) "" else "\n";
        const tail: []const u8 = if (cut < line.len) "…" else "";
        if (len + sep.len + cut + tail.len > buf.len) break;
        for ([_][]const u8{ sep, line[0..cut], tail }) |part| {
            @memcpy(buf[len..][0..part.len], part);
            len += part.len;
        }
        count += 1;
    }
    return buf[0..len];
}

test "shortNotes keeps the first lines and cuts long ones" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("- one\n- two", shortNotes(&buf, "- one\n\n- two\n", 5, 40));
    try std.testing.expectEqualStrings("- one\n- two\n…", shortNotes(&buf, "- one\n- two\n- three", 2, 40));
    try std.testing.expectEqualStrings("- abc…", shortNotes(&buf, "- abcdef", 5, 5));
    // "é" is two bytes, the cut goes before it
    try std.testing.expectEqualStrings("- d…", shortNotes(&buf, "- dé", 5, 4));
    try std.testing.expectEqualStrings("", shortNotes(&buf, "", 5, 40));
}

test "the built-in catalog lists the three apps" {
    const apps = try parse(std.testing.allocator, built_in);
    defer std.testing.allocator.free(apps);
    try std.testing.expectEqual(3, apps.len);
    try std.testing.expectEqualStrings("app-manager", apps[0].id);
    try std.testing.expectEqualStrings("opds-connector", apps[1].file);
    try std.testing.expectEqualStrings("OPDS Connector", apps[1].old_files);
    i18n.lang = .fr;
    defer i18n.lang = .en;
    try std.testing.expectEqualStrings("Statistiques de lecture", apps[2].name());
}

test "parse skips comments, short lines and unsafe names" {
    const text =
        "# a comment\n" ++
        "short\tline\n" ++
        "bad id\tA/b\ta\tA\tA\tA\tA\tA\n" ++
        "ok\tA/b\ta\t../escape\tA\tA\tA\tA\n" ++
        "spaces\tA/b\ta\tGood App\tA\tA\tA\tA\n" ++
        "good\tA/b\tasset\tgood-app\tGood\tBon\tdesc\tdesc fr\r\n";
    const apps = try parse(std.testing.allocator, text);
    defer std.testing.allocator.free(apps);
    try std.testing.expectEqual(1, apps.len);
    try std.testing.expectEqualStrings("good-app", apps[0].file);
    try std.testing.expectEqualStrings("", apps[0].old_files);
}

test "Build reads a version file and describes it" {
    const build = try Build.parse("channel=nightly\nversion=0.3.1\ncommit=9606907cc806\ntag=nightly\ndate=2026-10-17\n");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.3.1 (nightly, 9606907, 2026-10-17)", build.describe(&buf));
    try std.testing.expect(build.sameCommit(.{ .version = "0.3.1", .commit = "9606907" }));
    try std.testing.expect(!build.sameCommit(.{ .version = "0.3.1", .commit = "" }));
    try std.testing.expectError(error.IncompleteVersionFile, Build.parse("channel=nightly\n"));
}

test "addresses of version files and app files" {
    const apps = try parse(std.testing.allocator, built_in);
    defer std.testing.allocator.free(apps);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://github.com/Aluriak/pb-stats/releases/latest/download/version.txt",
        try versionUrl(&buf, apps[2], .stable),
    );
    try std.testing.expectEqualStrings(
        "https://github.com/Aluriak/pb-opds-connector/releases/download/nightly/opds-connector-allwinner.bin",
        try binaryUrl(&buf, apps[1], .{ .version = "0.3.1", .commit = "a", .tag = "nightly" }, "allwinner"),
    );
    try std.testing.expectError(error.IncompleteVersionFile, binaryUrl(&buf, apps[1], .{ .tag = "../x y" }, "allwinner"));
}

/// Whether `head`, the first bytes of a file, start an ARM executable
pub fn isArmExecutable(head: []const u8) bool {
    // e_machine at offset 18, little endian, 40 is ARM
    if (head.len < 20) return false;
    return std.mem.eql(u8, head[0..4], "\x7fELF") and head[18] == 40 and head[19] == 0;
}

test "isArmExecutable checks the ELF header and the machine" {
    var head: [20]u8 = @splat(0);
    @memcpy(head[0..4], "\x7fELF");
    head[18] = 40;
    try std.testing.expect(isArmExecutable(&head));
    head[18] = 62; // x86-64
    try std.testing.expect(!isArmExecutable(&head));
    try std.testing.expect(!isArmExecutable("<html>Not Found</html>"));
}
