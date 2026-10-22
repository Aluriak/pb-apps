//! What the app manager remembers: the language, and for each app the channel it follows
//! and the build it installed. Kept in InkView's settings file system/config/pb-apps.cfg.

const std = @import("std");
const pb = @import("c");
const catalog = @import("catalog.zig");
const i18n = @import("i18n.zig");

pub const path = "/mnt/ext1/system/config/pb-apps.cfg";

pub fn language() i18n.Choice {
    const config = pb.OpenConfig(path, null) orelse return .auto;
    defer pb.CloseConfigNoSave(config);
    return i18n.Choice.parse(std.mem.span(pb.ReadString(config, "language", "auto")));
}

pub fn setLanguage(choice: i18n.Choice) void {
    const config = pb.OpenConfig(path, null) orelse return;
    defer pb.CloseConfig(config);
    pb.WriteString(config, "language", @tagName(choice));
    _ = pb.SaveConfig(config);
}

/// Stable releases unless the user chose nightly builds for the app
pub fn channel(id: []const u8) catalog.Channel {
    const config = pb.OpenConfig(path, null) orelse return .stable;
    defer pb.CloseConfigNoSave(config);
    var key_buf: [96]u8 = undefined;
    return catalog.Channel.parse(std.mem.span(pb.ReadString(config, key(&key_buf, id, "channel"), "stable")));
}

pub fn setChannel(id: []const u8, value: catalog.Channel) void {
    const config = pb.OpenConfig(path, null) orelse return;
    defer pb.CloseConfig(config);
    var key_buf: [96]u8 = undefined;
    pb.WriteString(config, key(&key_buf, id, "channel"), @tagName(value));
    _ = pb.SaveConfig(config);
}

const build_fields = [_][]const u8{ "kind", "version", "commit", "tag", "date" };

/// The build the manager installed, null if it installed none. Strings are copied to `allocator`.
pub fn installed(allocator: std.mem.Allocator, id: []const u8) !?catalog.Build {
    const config = pb.OpenConfig(path, null) orelse return null;
    defer pb.CloseConfigNoSave(config);

    var build: catalog.Build = .{};
    inline for (build_fields) |field| {
        var key_buf: [96]u8 = undefined;
        const value = std.mem.span(pb.ReadString(config, key(&key_buf, id, field), ""));
        @field(build, field) = try allocator.dupe(u8, value);
    }
    if (build.commit.len == 0) return null;
    return build;
}

/// Remembers the build installed for an app, or forgets it with null
pub fn setInstalled(id: []const u8, build: ?catalog.Build) void {
    const config = pb.OpenConfig(path, null) orelse return;
    defer pb.CloseConfig(config);
    inline for (build_fields) |field| {
        var key_buf: [96]u8 = undefined;
        var value_buf: [128]u8 = undefined;
        const k = key(&key_buf, id, field);
        if (build) |b| {
            const value = std.fmt.bufPrintSentinel(&value_buf, "{s}", .{@field(b, field)}, 0) catch "";
            pb.WriteString(config, k, value.ptr);
        } else {
            pb.DeleteString(config, k);
        }
    }
    _ = pb.SaveConfig(config);
}

/// Settings are stored as "app.<id>.<field>"
fn key(buf: []u8, id: []const u8, field: []const u8) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, "app.{s}.{s}", .{ id, field }, 0) catch unreachable).ptr;
}
