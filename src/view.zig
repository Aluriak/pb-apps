//! Declaring apps in the reader's applications menu, system/config/desktop/view.json.
//!
//! Its own comments describe the format: user apps are entries "U_<id>" of "applications",
//! with "path", "title" and optionally "icon" and "focused_icon" ({ "path": ... }). An app
//! appears in the menu when its key is in the "apps" of one of the "view" "groups".
//! Apps of the applications folder that are not declared show up under their file name,
//! with a "@" in front.

const std = @import("std");

pub const default_path = "/mnt/ext1/system/config/desktop/view.json";

/// The group our apps are put in, the reader's main one
const group_title = "@General";

pub const Declaration = struct {
    /// "U_<id>"
    key: []const u8,
    /// Relative to the reader's storage, e.g. "applications/OPDS Connector.app"
    path: []const u8,
    title: []const u8,
    /// Relative to the reader's storage, or null to keep the reader's default icon
    icon: ?[]const u8 = null,
    focused_icon: ?[]const u8 = null,
};

/// The view.json text with `declaration` added, or replaced if the app is declared already
pub fn declare(allocator: std.mem.Allocator, text: []const u8, declaration: Declaration) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = try object(&parsed.value);

    const applications = try objectField(arena, root, "applications");
    var entry: std.json.ObjectMap = .empty;
    try entry.put(arena, "path", .{ .string = declaration.path });
    try entry.put(arena, "title", .{ .string = declaration.title });
    if (declaration.icon) |icon| try entry.put(arena, "icon", try pathObject(arena, icon));
    if (declaration.focused_icon) |icon| try entry.put(arena, "focused_icon", try pathObject(arena, icon));
    try applications.put(arena, declaration.key, .{ .object = entry });

    const apps = try groupApps(arena, root);
    for (apps.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, declaration.key)) break;
    } else try apps.append(.{ .string = declaration.key });

    return write(allocator, parsed.value);
}

/// The view.json text without the app `key`
pub fn remove(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = try object(&parsed.value);

    if (root.getPtr("applications")) |applications| {
        if (applications.* == .object) _ = applications.object.orderedRemove(key);
    }
    if (root.getPtr("view")) |view| {
        if (view.* == .object) if (view.object.getPtr("groups")) |groups| {
            if (groups.* == .array) for (groups.array.items) |*group| {
                if (group.* != .object) continue;
                const apps = group.object.getPtr("apps") orelse continue;
                if (apps.* != .array) continue;
                var i: usize = 0;
                while (i < apps.array.items.len) {
                    const item = apps.array.items[i];
                    if (item == .string and std.mem.eql(u8, item.string, key)) {
                        _ = apps.array.orderedRemove(i);
                    } else i += 1;
                }
            };
        };
    }
    return write(allocator, parsed.value);
}

fn object(value: *std.json.Value) !*std.json.ObjectMap {
    if (value.* != .object) return error.UnknownViewFormat;
    return &value.object;
}

/// The object `name` of `parent`, created if missing
fn objectField(arena: std.mem.Allocator, parent: *std.json.ObjectMap, name: []const u8) !*std.json.ObjectMap {
    const entry = try parent.getOrPut(arena, name);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    return object(entry.value_ptr);
}

fn pathObject(arena: std.mem.Allocator, path: []const u8) !std.json.Value {
    var value: std.json.ObjectMap = .empty;
    try value.put(arena, "path", .{ .string = path });
    return .{ .object = value };
}

/// The "apps" of the group our apps go in: the reader's main group, or the first one
fn groupApps(arena: std.mem.Allocator, root: *std.json.ObjectMap) !*std.json.Array {
    const view = try objectField(arena, root, "view");
    const groups_entry = try view.getOrPut(arena, "groups");
    if (!groups_entry.found_existing) groups_entry.value_ptr.* = .{ .array = .init(arena) };
    if (groups_entry.value_ptr.* != .array) return error.UnknownViewFormat;
    const groups = &groups_entry.value_ptr.array;

    var chosen: ?*std.json.ObjectMap = null;
    for (groups.items) |*group| {
        if (group.* != .object) continue;
        if (chosen == null) chosen = &group.object;
        const title = group.object.get("title") orelse continue;
        if (title == .string and std.mem.eql(u8, title.string, group_title)) {
            chosen = &group.object;
            break;
        }
    }
    const group = chosen orelse blk: {
        var created: std.json.ObjectMap = .empty;
        try created.put(arena, "title", .{ .string = group_title });
        try groups.append(.{ .object = created });
        break :blk &groups.items[groups.items.len - 1].object;
    };

    const apps_entry = try group.getOrPut(arena, "apps");
    if (!apps_entry.found_existing) apps_entry.value_ptr.* = .{ .array = .init(arena) };
    if (apps_entry.value_ptr.* != .array) return error.UnknownViewFormat;
    return &apps_entry.value_ptr.array;
}

fn write(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_4 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Reads a whole file through libc. Zig's own file layer makes system calls the reader's
/// 3.10 kernel lacks.
pub fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const read = std.c.fread(&buf, 1, buf.len, file);
        if (read == 0) break;
        try text.appendSlice(allocator, buf[0..read]);
    }
    return text.toOwnedSlice(allocator);
}

/// Replaces a file in one step: the content goes to "<path>.new", which is then renamed.
/// A file cut short by a power loss is never left in place.
pub fn writeFile(path: [:0]const u8, content: []const u8) !void {
    var tmp_buf: [512]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}.new", .{path}, 0);
    const file = std.c.fopen(tmp.ptr, "wb") orelse return error.CannotWriteFile;
    const written = std.c.fwrite(content.ptr, 1, content.len, file);
    if (std.c.fclose(file) != 0 or written != content.len) {
        _ = std.c.unlink(tmp.ptr);
        return error.CannotWriteFile;
    }
    if (std.c.rename(tmp.ptr, path.ptr) != 0) {
        _ = std.c.unlink(tmp.ptr);
        return error.CannotWriteFile;
    }
}

/// The view.json of a Vivlio Light HD Color, shortened
const reader_view =
    \\{
    \\    "version": "8",
    \\    "applications": {
    \\        "_comment": [ "Fields - application key id, must start from \"U_\" for user application\n" ]
    \\    },
    \\    "view": {
    \\        "groups": [
    \\            { "title": "@General", "sort": "title", "apps": [ "PB_Browser", "PB_Settings" ] },
    \\            { "title": "@Games", "sort": "title", "apps": [ "PB_Chess" ] }
    \\        ]
    \\    }
    \\}
;

const opds: Declaration = .{
    .key = "U_opds-connector",
    .path = "applications/OPDS Connector.app",
    .title = "Connecteur OPDS",
    .icon = "applications/icons/opds-connector.bmp",
    .focused_icon = "applications/icons/opds-connector_f.bmp",
};

test "declare adds the app and puts it in the main group, keeping everything else" {
    const text = try declare(std.testing.allocator, reader_view, opds);
    defer std.testing.allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("8", root.get("version").?.string);

    const entry = root.get("applications").?.object.get("U_opds-connector").?.object;
    try std.testing.expectEqualStrings("Connecteur OPDS", entry.get("title").?.string);
    try std.testing.expectEqualStrings("applications/icons/opds-connector.bmp", entry.get("icon").?.object.get("path").?.string);
    try std.testing.expect(root.get("applications").?.object.contains("_comment"));

    const groups = root.get("view").?.object.get("groups").?.array.items;
    const general = groups[0].object.get("apps").?.array.items;
    try std.testing.expectEqual(3, general.len);
    try std.testing.expectEqualStrings("U_opds-connector", general[2].string);
    try std.testing.expectEqual(1, groups[1].object.get("apps").?.array.items.len);
}

test "declaring twice changes the entry without adding it twice" {
    const once = try declare(std.testing.allocator, reader_view, opds);
    defer std.testing.allocator.free(once);
    var renamed = opds;
    renamed.title = "OPDS Connector";
    const twice = try declare(std.testing.allocator, once, renamed);
    defer std.testing.allocator.free(twice);

    // Once as the entry, once in the group
    try std.testing.expectEqual(2, std.mem.count(u8, twice, "\"U_opds-connector\""));
    try std.testing.expect(std.mem.indexOf(u8, twice, "\"title\": \"OPDS Connector\"") != null);
}

test "remove takes the app out of the applications and the groups" {
    const declared = try declare(std.testing.allocator, reader_view, opds);
    defer std.testing.allocator.free(declared);
    const removed = try remove(std.testing.allocator, declared, opds.key);
    defer std.testing.allocator.free(removed);

    try std.testing.expect(std.mem.indexOf(u8, removed, "U_opds-connector") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "PB_Settings") != null);
}

test "declare refuses what is not a view file" {
    try std.testing.expectError(error.UnknownViewFormat, declare(std.testing.allocator, "[1, 2]", opds));
    try std.testing.expectError(error.SyntaxError, declare(std.testing.allocator, "{ broken", opds));
}

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

test "writeFile replaces a file and readFile reads it back" {
    var template = "/tmp/pb-apps-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&template) orelse return error.SkipZigTest);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/view.json", .{dir}, 0);

    try writeFile(path, "first");
    try writeFile(path, "second");
    const text = try readFile(std.testing.allocator, path);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("second", text);
}

test "declare works on the view.json of a real reader, if one is given" {
    // PB_APPS_TEST_VIEW=/path/to/view.json zig build test
    const path = std.c.getenv("PB_APPS_TEST_VIEW") orelse return error.SkipZigTest;
    const text = try readFile(std.testing.allocator, std.mem.span(path));
    defer std.testing.allocator.free(text);
    const declared = try declare(std.testing.allocator, text, opds);
    defer std.testing.allocator.free(declared);
    const removed = try remove(std.testing.allocator, declared, opds.key);
    defer std.testing.allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "U_opds-connector") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "PB_Bookstore2empikgo") != null);
}
