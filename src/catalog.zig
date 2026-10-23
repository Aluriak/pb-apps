//! The apps on offer (catalog.txt) and the builds their releases publish (version.txt).

const std = @import("std");
const i18n = @import("i18n.zig");

/// Where the catalog is read from. The copy built into the app is used when it cannot be loaded.
pub const url = "https://raw.githubusercontent.com/Aluriak/pb-apps/main/catalog.txt";
pub const built_in = @embedFile("catalog_txt");

pub const App = struct {
    id: []const u8,
    /// GitHub owner/name, or "codeberg:owner/name" for an app published on Codeberg
    repo: []const u8,
    /// Start of the names of its release files: <asset>-<platform>.bin on GitHub,
    /// <asset>-<tag or nightly build>-<platform>.zip on Codeberg
    asset: []const u8,
    /// Its name in the applications folder, without ".app"
    file: []const u8,
    names: [2][]const u8,
    descriptions: [2][]const u8,
    /// Earlier names of the app file, comma separated
    old_files: []const u8 = "",
    /// Apps of the same group do the same job: one of them only is installed
    group: []const u8 = "",
    /// The app of its group to choose when in doubt
    recommended: bool = false,

    pub fn name(app: App) []const u8 {
        return app.names[@backingInt(i18n.lang)];
    }

    pub fn description(app: App) []const u8 {
        return app.descriptions[@backingInt(i18n.lang)];
    }

    pub fn source(app: App) Source {
        return if (std.mem.startsWith(u8, app.repo, codeberg_prefix)) .codeberg else .github;
    }

    /// owner/name, without the forge
    pub fn repoPath(app: App) []const u8 {
        return if (app.source() == .codeberg) app.repo[codeberg_prefix.len..] else app.repo;
    }
};

pub const Source = enum {
    /// Apps of this project: releases with version.txt and unzipped <asset>-<platform>.bin
    github,
    /// The original OPDS Connector: releases with zipped apps, read through Codeberg's API
    codeberg,
};

const codeberg_prefix = "codeberg:";

/// Reads catalog.txt. The strings point into `text`. Lines that cannot be read are skipped.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]App {
    var apps: std.ArrayList(App) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields: [11][]const u8 = @splat("");
        var it = std.mem.splitScalar(u8, line, '\t');
        var count: usize = 0;
        while (it.next()) |field| : (count += 1) {
            if (count == fields.len) break;
            fields[count] = std.mem.trim(u8, field, " ");
        }
        // The old file names are optional
        if (count < 8 or !valid(fields[0]) or !valid(fields[2]) or !valid(fields[3])) continue;
        if (std.mem.indexOfScalar(u8, fields[8], '/') != null) continue;
        if (fields[9].len > 0 and !valid(fields[9])) continue;

        try apps.append(allocator, .{
            .id = fields[0],
            .repo = fields[1],
            .asset = fields[2],
            .file = fields[3],
            .names = .{ fields[4], fields[5] },
            .descriptions = .{ fields[6], fields[7] },
            .old_files = fields[8],
            .group = fields[9],
            .recommended = std.mem.eql(u8, fields[10], "recommended"),
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
    /// The name of the zip to download for the reader's platform, for apps from Codeberg
    zip: []const u8 = "",

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

    /// Reads a release as Codeberg's API gives it, for `platform`. The slices point into
    /// what `allocator` gets, an arena.
    pub fn parseCodeberg(allocator: std.mem.Allocator, json: []const u8, asset: []const u8, platform: []const u8) !Build {
        const release = std.json.parseFromSliceLeaky(CodebergRelease, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.IncompleteVersionFile;
        if (!validTag(release.tag_name)) return error.IncompleteVersionFile;

        // "<asset>-v0.5.0-allwinner.zip", or "<asset>-nightly-20261021-a071a2b-allwinner.zip"
        var suffix_buf: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "-{s}.zip", .{platform}) catch return error.IncompleteVersionFile;
        for (release.assets) |file| {
            if (!std.mem.startsWith(u8, file.name, asset) or !std.mem.endsWith(u8, file.name, suffix)) continue;
            if (file.name.len <= asset.len + suffix.len + 1 or file.name[asset.len] != '-') continue;
            if (!validTag(file.name)) continue;
            const middle = file.name[asset.len + 1 .. file.name.len - suffix.len];

            var build: Build = .{ .tag = release.tag_name, .zip = file.name, .date = release.published_at[0..@min(10, release.published_at.len)] };
            if (release.prerelease) {
                // nightly-<date>-<commit>
                var parts = std.mem.splitScalar(u8, middle, '-');
                build.kind = "nightly";
                build.version = parts.next() orelse "nightly";
                _ = parts.next();
                build.commit = parts.next() orelse release.tag_name;
            } else {
                build.kind = "release";
                build.version = std.mem.trimStart(u8, release.tag_name, "v");
                // Releases are known by their tag, the API gives no commit
                build.commit = release.tag_name;
            }
            return build;
        }
        return error.IncompleteVersionFile;
    }

    /// Whether two builds come from the same commit. Either may be shortened. Builds known by
    /// a tag instead of a commit are the same when their tags are.
    pub fn sameCommit(a: Build, b: Build) bool {
        if (a.commit.len < 7 or b.commit.len < 7) return a.commit.len > 0 and std.mem.eql(u8, a.commit, b.commit);
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

const CodebergRelease = struct {
    tag_name: []const u8 = "",
    prerelease: bool = false,
    published_at: []const u8 = "",
    assets: []const struct { name: []const u8 = "" } = &.{},
};

/// The address of the version.txt of `app` on `channel`; for an app from Codeberg, of its
/// release in Codeberg's API
pub fn versionUrl(buf: []u8, app: App, channel: Channel) ![:0]const u8 {
    if (app.source() == .codeberg) {
        const which = switch (channel) {
            .stable => "latest",
            .nightly => "tags/nightly",
        };
        return std.fmt.bufPrintSentinel(buf, "https://codeberg.org/api/v1/repos/{s}/releases/{s}", .{ app.repoPath(), which }, 0);
    }
    return std.fmt.bufPrintSentinel(buf, "https://github.com/{s}/releases/{s}/version.txt", .{ app.repo, channel.path() }, 0);
}

/// The address of the app file of `build` for `platform`
pub fn binaryUrl(buf: []u8, app: App, build: Build, platform: []const u8) ![:0]const u8 {
    if (!validTag(build.tag)) return error.IncompleteVersionFile;
    if (app.source() == .codeberg) {
        if (!validTag(build.zip)) return error.IncompleteVersionFile;
        return std.fmt.bufPrintSentinel(buf, "https://codeberg.org/{s}/releases/download/{s}/{s}", .{ app.repoPath(), build.tag, build.zip }, 0);
    }
    return std.fmt.bufPrintSentinel(buf, "https://github.com/{s}/releases/download/{s}/{s}-{s}.bin", .{ app.repo, build.tag, app.asset, platform }, 0);
}

/// The address of the notes of `build`: what changed since the release before it
pub fn notesUrl(buf: []u8, app: App, build: Build) ![:0]const u8 {
    if (!validTag(build.tag)) return error.IncompleteVersionFile;
    if (app.source() == .codeberg) return error.NoNotes;
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

test "a release on Codeberg gives the zip for the platform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const release =
        \\{"tag_name":"v0.5.0","prerelease":false,"published_at":"2026-10-20T12:26:12+02:00","target_commitish":"main",
        \\ "assets":[{"name":"opds-connector-v0.5.0-allwinner.zip","size":99651},{"name":"opds-connector-v0.5.0-rk3566.zip"},{"name":"SHA256SUMS"}]}
    ;
    const build = try Build.parseCodeberg(a, release, "opds-connector", "rk3566");
    try std.testing.expectEqualStrings("0.5.0", build.version);
    try std.testing.expectEqualStrings("release", build.kind);
    try std.testing.expectEqualStrings("opds-connector-v0.5.0-rk3566.zip", build.zip);
    try std.testing.expectEqualStrings("2026-10-20", build.date);
    try std.testing.expect(build.sameCommit(.{ .commit = "v0.5.0" }));
    try std.testing.expect(!build.sameCommit(.{ .commit = "v0.4.0" }));

    const nightly =
        \\{"tag_name":"nightly","prerelease":true,"published_at":"2026-10-21T08:00:00Z",
        \\ "assets":[{"name":"opds-connector-nightly-20261021-a071a2b-allwinner.zip"}]}
    ;
    const night = try Build.parseCodeberg(a, nightly, "opds-connector", "allwinner");
    try std.testing.expectEqualStrings("nightly", night.kind);
    try std.testing.expectEqualStrings("a071a2b", night.commit);
    try std.testing.expectError(error.IncompleteVersionFile, Build.parseCodeberg(a, nightly, "opds-connector", "rk3566"));
    try std.testing.expectError(error.IncompleteVersionFile, Build.parseCodeberg(a, "<html>", "opds-connector", "rk3566"));

    const app: App = .{ .id = "x", .repo = "codeberg:codedge/pb-opds-connector", .asset = "opds-connector", .file = "x", .names = .{ "", "" }, .descriptions = .{ "", "" } };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/codedge/pb-opds-connector/releases/latest", try versionUrl(&buf, app, .stable));
    try std.testing.expectEqualStrings(
        "https://codeberg.org/codedge/pb-opds-connector/releases/download/v0.5.0/opds-connector-v0.5.0-rk3566.zip",
        try binaryUrl(&buf, app, build, "rk3566"),
    );
}

test "the built-in catalog lists the apps" {
    const apps = try parse(std.testing.allocator, built_in);
    defer std.testing.allocator.free(apps);
    try std.testing.expectEqual(4, apps.len);
    // The original before the fork, the one to choose when in doubt
    try std.testing.expectEqual(Source.codeberg, apps[1].source());
    try std.testing.expect(apps[1].recommended);
    try std.testing.expectEqualStrings("opds-connector", apps[1].group);
    try std.testing.expectEqualStrings(apps[1].group, apps[2].group);
    try std.testing.expect(!apps[2].recommended);
    try std.testing.expectEqualStrings("", apps[3].group);
    try std.testing.expectEqualStrings("app-manager", apps[0].id);
    try std.testing.expectEqualStrings("opds-connector", apps[2].file);
    try std.testing.expectEqualStrings("OPDS Connector", apps[2].old_files);
    i18n.lang = .fr;
    defer i18n.lang = .en;
    try std.testing.expectEqualStrings("Statistiques de lecture", apps[3].name());
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
        try versionUrl(&buf, apps[3], .stable),
    );
    try std.testing.expectEqualStrings(
        "https://github.com/Aluriak/pb-opds-connector/releases/download/nightly/opds-connector-allwinner.bin",
        try binaryUrl(&buf, apps[2], .{ .version = "0.3.1", .commit = "a", .tag = "nightly" }, "allwinner"),
    );
    try std.testing.expectError(error.IncompleteVersionFile, binaryUrl(&buf, apps[2], .{ .tag = "../x y" }, "allwinner"));
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
