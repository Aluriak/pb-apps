//! Installing, updating and removing apps in the reader's applications folder, and declaring
//! them in its applications menu.

const std = @import("std");
const build_options = @import("build_options");

const catalog = @import("catalog.zig");
const net = @import("net.zig");
const view = @import("view.zig");
const pocketbook = @import("pocketbook.zig");
const trace = pocketbook.trace;

const storage = "/mnt/ext1";
const apps_dir = storage ++ "/applications";
const icons_dir = apps_dir ++ "/icons";
/// The icons of the apps are kept in this repository
const icons_url = "https://raw.githubusercontent.com/Aluriak/pb-apps/main/icons";

/// Whether the app file is in the applications folder
pub fn isPresent(app: catalog.App) bool {
    var buf: [256]u8 = undefined;
    const path = appPath(&buf, app) catch return false;
    return std.c.access(path.ptr, 0) == 0;
}

fn appPath(buf: []u8, app: catalog.App) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}.app", .{ apps_dir, app.file }, 0);
}

/// Downloads the app next to where it goes, checks it is an ARM program and puts it in
/// place. A running app goes on with its old file and uses the new one from its next start.
/// Then gets its icons and declares it in the applications menu, as `title`.
pub fn install(app: catalog.App, build: catalog.Build, title: []const u8) !void {
    var url_buf: [512]u8 = undefined;
    const url = try catalog.binaryUrl(&url_buf, app, build, build_options.platform);

    var part_name_buf: [160]u8 = undefined;
    const part_name = try std.fmt.bufPrint(&part_name_buf, "{s}.app.part", .{app.file});
    var part_buf: [256]u8 = undefined;
    const part = try std.fmt.bufPrintSentinel(&part_buf, "{s}/{s}", .{ apps_dir, part_name }, 0);
    errdefer _ = std.c.unlink(part.ptr);

    trace("install: {s} -> {s}\n", .{ url, part });
    try net.download(url, apps_dir, part_name);
    if (!startsLikeApp(part)) return error.NotAnApp;

    var path_buf: [256]u8 = undefined;
    const path = try appPath(&path_buf, app);
    if (std.c.rename(part.ptr, path.ptr) != 0) return error.CannotReplaceApp;

    // Without icons or a menu entry the app still works, under its file name
    const icons = fetchIcons(app);
    declare(app, title, icons) catch |err| trace("view.json not changed: {s}\n", .{@errorName(err)});
}

/// Removes the app, its icons and its menu entry. Its settings and data stay.
pub fn uninstall(app: catalog.App) !void {
    var path_buf: [256]u8 = undefined;
    const path = try appPath(&path_buf, app);
    if (std.c.unlink(path.ptr) != 0 and isPresent(app)) return error.CannotRemoveApp;

    for ([_][]const u8{ "", "_f" }) |suffix| {
        var icon_buf: [256]u8 = undefined;
        const icon = std.fmt.bufPrintSentinel(&icon_buf, "{s}/{s}{s}.bmp", .{ icons_dir, app.id, suffix }, 0) catch continue;
        _ = std.c.unlink(icon.ptr);
    }
    undeclare(app) catch |err| trace("view.json not changed: {s}\n", .{@errorName(err)});
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

/// Downloads the two icons of the app. Returns whether both are there.
fn fetchIcons(app: catalog.App) bool {
    _ = mkdir(icons_dir, 0o755);
    for ([_][]const u8{ "", "_f" }) |suffix| {
        var url_buf: [256]u8 = undefined;
        var name_buf: [96]u8 = undefined;
        const url = std.fmt.bufPrintSentinel(&url_buf, "{s}/{s}{s}.bmp", .{ icons_url, app.id, suffix }, 0) catch return false;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}.bmp", .{ app.id, suffix }) catch return false;
        net.download(url, icons_dir, name) catch |err| {
            trace("icon {s}: {s}\n", .{ name, @errorName(err) });
            return false;
        };
    }
    return true;
}

/// Declares the app in the applications menu, under `title` and with its icons if there are
pub fn declare(app: catalog.App, title: []const u8, icons: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A reader without this file keeps listing apps by file name
    const text = view.readFile(allocator, view.default_path) catch return;
    backup(text);

    var key_buf: [96]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    var icon_buf: [256]u8 = undefined;
    var focused_buf: [256]u8 = undefined;
    const declaration: view.Declaration = .{
        .key = try std.fmt.bufPrint(&key_buf, "U_{s}", .{app.id}),
        .path = try std.fmt.bufPrint(&path_buf, "applications/{s}.app", .{app.file}),
        .title = title,
        .icon = if (icons) try std.fmt.bufPrint(&icon_buf, "applications/icons/{s}.bmp", .{app.id}) else null,
        .focused_icon = if (icons) try std.fmt.bufPrint(&focused_buf, "applications/icons/{s}_f.bmp", .{app.id}) else null,
    };
    try view.writeFile(view.default_path, try view.declare(allocator, text, declaration));
}

/// Whether the icons of the app are on the reader
pub fn hasIcons(app: catalog.App) bool {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}_f.bmp", .{ icons_dir, app.id }, 0) catch return false;
    return std.c.access(path.ptr, 0) == 0;
}

fn undeclare(app: catalog.App) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = view.readFile(allocator, view.default_path) catch return;
    var key_buf: [96]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "U_{s}", .{app.id});
    try view.writeFile(view.default_path, try view.remove(allocator, text, key));
}

/// Keeps the reader's own view.json once, before the app first changes it
fn backup(text: []const u8) void {
    const path = view.default_path ++ ".before-pb-apps";
    if (std.c.access(path, 0) == 0) return;
    view.writeFile(path, text) catch |err| trace("no backup of view.json: {s}\n", .{@errorName(err)});
}

/// Whether the downloaded file is an ARM program, and not an error page
fn startsLikeApp(path: [:0]const u8) bool {
    const file = std.c.fopen(path.ptr, "rb") orelse return false;
    defer _ = std.c.fclose(file);
    var head: [20]u8 = undefined;
    if (std.c.fread(&head, 1, head.len, file) != head.len) return false;
    return catalog.isArmExecutable(&head);
}
