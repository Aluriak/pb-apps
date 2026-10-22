//! App Manager: installs and updates PocketBook apps from their GitHub releases.

const std = @import("std");
const pb = @import("c");
const build_options = @import("build_options");

const catalog = @import("catalog.zig");
const i18n = @import("i18n.zig");
const install = @import("install.zig");
const net = @import("net.zig");
const state = @import("state.zig");
const pocketbook = @import("pocketbook.zig");
const t = i18n.t;
const trace = pocketbook.trace;

/// An app of the catalog, with what is known about it on the reader and online
const Entry = struct {
    app: catalog.App,
    channel: catalog.Channel,
    /// The app file is in the applications folder
    present: bool,
    /// The build the manager installed, null when unknown (installed by hand) or not installed
    installed: ?catalog.Build,
    available: Availability,
};

const Availability = union(enum) {
    /// Not looked for, the reader is offline
    unknown,
    /// Looking for it failed
    failed,
    /// Nothing is published on the channel
    none,
    build: catalog.Build,
};

/// InkView callbacks carry no user pointer, so the app state lives here
var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var entries: []Entry = &.{};
var language: i18n.Choice = .auto;
var online = false;

/// The text of every row, rebuilt when something changed
var rows_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var rows: []Row = &.{};
var list_pos: c_int = 0;

const Row = struct {
    title: [:0]const u8,
    detail: [:0]const u8,
    entry: ?usize,
};

var item_height: c_int = 0;
var padding: c_int = 0;
var title_font: ?*pb.ifont = null;
var detail_font: ?*pb.ifont = null;

extern "c" fn currentLang() ?[*:0]const u8;

fn readerLanguage() []const u8 {
    return std.mem.span(currentLang() orelse return "en");
}

/// This app, as it was built
fn self() catalog.Build {
    return .{ .kind = build_options.channel, .version = build_options.version, .commit = build_options.commit };
}

const self_id = "app-manager";

fn mainHandler(event_type: c_int, par1: c_int, _: c_int) callconv(.c) c_int {
    switch (event_type) {
        pb.EVT_INIT => {
            language = state.language();
            i18n.lang = language.resolve(readerLanguage());
            _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, t(.app_title), null);

            item_height = @divTrunc(pb.ScreenHeight(), 9);
            padding = @divTrunc(item_height, 8);
            title_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_BOLD), @divTrunc(item_height, 4), 1);
            detail_font = pb.OpenFont(pb.iv_get_default_font(pb.FONT_STD), @divTrunc(item_height, 5), 1);

            pb.ShowHourglassForce();
            load() catch |err| {
                pb.HideHourglass();
                pocketbook.showError(t(.loading_error), err);
                pb.CloseApp();
                return 0;
            };
            pb.HideHourglass();
            showList();
            if (!online) pb.Message(pb.ICON_INFORMATION, t(.app_title), t(.offline), 4000);
        },
        pb.EVT_SHOW => showList(),
        pb.EVT_KEYPRESS => if (par1 == pb.IV_KEY_BACK) pb.CloseApp(),
        pb.EVT_EXIT => {
            if (title_font) |f| pb.CloseFont(f);
            if (detail_font) |f| pb.CloseFont(f);
        },
        else => {},
    }
    return 0;
}

/// Reads the catalog, online if possible, and what is installed and available for each app
fn load() !void {
    const allocator = arena.allocator();
    online = pocketbook.ensureNetwork();

    const text = if (online) net.fetch(allocator, catalog.url) catch |err| blk: {
        trace("catalog not loaded: {s}\n", .{@errorName(err)});
        break :blk catalog.built_in;
    } else catalog.built_in;
    var apps = try catalog.parse(allocator, text);
    // A broken catalog online must not leave the reader without the manager
    if (apps.len == 0) apps = try catalog.parse(allocator, catalog.built_in);

    entries = try allocator.alloc(Entry, apps.len);
    for (apps, entries) |app, *entry| {
        entry.* = .{
            .app = app,
            .channel = state.channel(app.id),
            .present = install.isPresent(app),
            .installed = try state.installed(allocator, app.id),
            .available = .unknown,
        };
        // The running manager knows its own build
        if (std.mem.eql(u8, app.id, self_id) and entry.installed == null and !std.mem.eql(u8, self().commit, "dev")) {
            entry.installed = self();
        }
        if (online) entry.available = available(allocator, app, entry.channel);
        // The reader may have rewritten its menu file and dropped the apps, put them back
        if (entry.present) _ = install.ensureDeclared(app, app.name(), online);
    }
}

fn available(allocator: std.mem.Allocator, app: catalog.App, channel: catalog.Channel) Availability {
    var url_buf: [256]u8 = undefined;
    const url = catalog.versionUrl(&url_buf, app, channel) catch return .failed;
    const body = net.fetch(allocator, url) catch |err| {
        trace("{s}: {s}\n", .{ url, @errorName(err) });
        // A channel without any release answers 404
        var reason_buf: [64]u8 = undefined;
        return if (std.mem.indexOf(u8, net.lastFailure(&reason_buf), "404") != null) .none else .failed;
    };
    const build = catalog.Build.parse(body) catch return .failed;
    return .{ .build = build };
}

fn rebuildRows() !void {
    _ = rows_arena.reset(.retain_capacity);
    const allocator = rows_arena.allocator();
    var list: std.ArrayList(Row) = .empty;

    for (entries, 0..) |entry, i| {
        try list.append(allocator, .{
            .title = try allocator.dupeSentinel(u8, entry.app.name(), 0),
            .detail = try detail(allocator, entry),
            .entry = i,
        });
    }

    var buf: [96]u8 = undefined;
    const chosen = switch (language) {
        .auto => t(.language_auto),
        .fr => t(.language_fr),
        .en => t(.language_en),
    };
    try list.append(allocator, .{
        .title = try allocator.dupeSentinel(u8, i18n.fmt(&buf, .language, .{chosen}), 0),
        .detail = t(.language_change),
        .entry = null,
    });
    rows = try list.toOwnedSlice(allocator);
}

fn detail(allocator: std.mem.Allocator, entry: Entry) ![:0]const u8 {
    var status_buf: [160]u8 = undefined;
    var build_buf: [96]u8 = undefined;
    const status: []const u8 = if (!entry.present)
        t(.not_installed)
    else if (entry.installed) |build|
        i18n.fmt(&status_buf, .installed, .{build.describe(&build_buf)})
    else
        t(.installed_unknown);

    var out_buf: [320]u8 = undefined;
    var available_buf: [96]u8 = undefined;
    const text = switch (entry.available) {
        .unknown => i18n.fmt(&out_buf, .available, .{ status, "?" })[0..],
        .failed => i18n.fmt(&out_buf, .unreachable_build, .{status}),
        .none => i18n.fmt(&out_buf, .no_build, .{status}),
        .build => |build| if (entry.present and entry.installed != null and build.sameCommit(entry.installed.?))
            i18n.fmt(&out_buf, .up_to_date, .{status})
        else
            i18n.fmt(&out_buf, .available, .{ status, build.describe(&available_buf) }),
    };
    return allocator.dupeSentinel(u8, text, 0);
}

fn showList() void {
    rebuildRows() catch return;
    pb.OpenList(t(.app_title), null, pb.ScreenWidth(), item_height, @intCast(rows.len), list_pos, listHandler);
}

fn listHandler(action: c_int, x: c_int, y: c_int, idx: c_int, state_flag: c_int) callconv(.c) c_int {
    switch (action) {
        pb.LIST_PAINT => {
            if (idx < 0 or idx >= rows.len) return 0;
            paintRow(rows[@intCast(idx)], x, y, state_flag != 0);
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= rows.len) return 0;
            list_pos = idx;
            if (rows[@intCast(idx)].entry) |i| {
                openMenu(i);
            } else {
                changeLanguage();
            }
        },
        pb.LIST_EXIT => pb.CloseApp(),
        else => return 0,
    }
    return 1;
}

fn paintRow(row: Row, x: c_int, y: c_int, selected: bool) void {
    const width = pb.ScreenWidth();
    const text_width = width - 2 * padding;
    const line_height = @divTrunc(item_height - 2 * padding, 2);
    const flags = pb.ALIGN_LEFT | pb.VALIGN_MIDDLE | pb.DOTS;

    pb.SetFont(title_font, pb.BLACK);
    _ = pb.DrawTextRect(x + padding, y + padding, text_width, line_height, row.title.ptr, flags);
    pb.SetFont(detail_font, pb.DGRAY);
    _ = pb.DrawTextRect(x + padding, y + padding + line_height, text_width, line_height, row.detail.ptr, flags);
    pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
    if (selected) pb.DrawSelection(x, y, width, item_height, pb.BLACK);
}

/// What the menu of an app can do
const MenuItem = enum(c_int) { install = 1, switch_channel, uninstall };

// InkView keeps pointers into these while the menu is open
var menu: [5]pb.imenu = undefined;
var menu_title: [96]u8 = undefined;
var menu_entry: usize = 0;

fn openMenu(i: usize) void {
    menu_entry = i;
    const entry = entries[i];
    const title = std.fmt.bufPrintSentinel(&menu_title, "{s}", .{entry.app.name()}, 0) catch return;

    var n: usize = 0;
    menu[n] = .{ .type = pb.ITEM_HEADER, .index = 0, .text = @constCast(title.ptr), .submenu = null };
    n += 1;

    const install_text = if (!entry.present) t(.install) else if (upToDate(entry)) t(.reinstall) else t(.update);
    const can_install = entry.available == .build;
    menu[n] = .{ .type = if (can_install) pb.ITEM_ACTIVE else pb.ITEM_INACTIVE, .index = @backingInt(MenuItem.install), .text = @constCast(install_text.ptr), .submenu = null };
    n += 1;

    const switch_text = switch (entry.channel) {
        .nightly => t(.switch_to_stable),
        .stable => t(.switch_to_nightly),
    };
    menu[n] = .{ .type = pb.ITEM_ACTIVE, .index = @backingInt(MenuItem.switch_channel), .text = @constCast(switch_text.ptr), .submenu = null };
    n += 1;

    // The manager does not remove itself
    if (entry.present and !std.mem.eql(u8, entry.app.id, self_id)) {
        menu[n] = .{ .type = pb.ITEM_ACTIVE, .index = @backingInt(MenuItem.uninstall), .text = @constCast(t(.uninstall).ptr), .submenu = null };
        n += 1;
    }
    // A zeroed item ends the menu
    menu[n] = .{ .type = 0, .index = 0, .text = null, .submenu = null };

    pb.OpenMenu(&menu, 1, @divTrunc(pb.ScreenWidth(), 8), @divTrunc(pb.ScreenHeight(), 3), menuHandler);
}

fn upToDate(entry: Entry) bool {
    const installed = entry.installed orelse return false;
    return switch (entry.available) {
        .build => |build| build.sameCommit(installed),
        else => false,
    };
}

fn menuHandler(index: c_int) callconv(.c) void {
    const item = std.enums.fromInt(MenuItem, index) orelse return;
    switch (item) {
        .install => confirmInstall(),
        .switch_channel => switchChannel(),
        .uninstall => confirmUninstall(),
    }
}

var dialog_text: [640]u8 = undefined;

fn kindText(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "release")) return t(.kind_release);
    if (std.mem.eql(u8, kind, "nightly")) return t(.kind_nightly);
    return t(.kind_dev);
}

fn confirmInstall() void {
    const entry = entries[menu_entry];
    const build = switch (entry.available) {
        .build => |b| b,
        else => {
            pb.Message(pb.ICON_INFORMATION, t(.app_title), t(.nothing_to_install), 4000);
            return;
        },
    };
    var new_buf: [96]u8 = undefined;
    var old_buf: [96]u8 = undefined;
    const text = if (entry.present)
        i18n.fmt(&dialog_text, .confirm_update, .{
            entry.app.name(),
            build.describe(&new_buf),
            if (entry.installed) |old| old.describe(&old_buf) else "?",
            kindText(build.kind),
        })
    else
        i18n.fmt(&dialog_text, .confirm_install, .{ entry.app.name(), build.describe(&new_buf), kindText(build.kind) });
    const button = if (entry.present) t(.update) else t(.install);
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), text.ptr, button.ptr, t(.cancel).ptr, installAnswered);
}

fn installAnswered(button: c_int) callconv(.c) void {
    if (button != 1) return;
    const entry = &entries[menu_entry];
    const build = switch (entry.available) {
        .build => |b| b,
        else => return,
    };
    const was_present = entry.present;

    pb.ShowHourglassForce();
    const result = install.install(entry.app, build, entry.app.name());
    pb.HideHourglass();

    var buf: [256]u8 = undefined;
    result catch |err| {
        pocketbook.showError(i18n.fmt(&buf, .install_error, .{entry.app.name()}), err);
        return;
    };

    state.setInstalled(entry.app.id, build);
    entry.present = true;
    entry.installed = copyBuild(build) catch build;

    const done = if (std.mem.eql(u8, entry.app.id, self_id))
        t(.done_self_update)
    else if (was_present)
        i18n.fmt(&buf, .done_update, .{entry.app.name()})
    else
        i18n.fmt(&buf, .done_install, .{entry.app.name()});
    showList();
    pb.Message(pb.ICON_INFORMATION, t(.app_title), done.ptr, 6000);
}

/// A copy that outlives the version file it was read from
fn copyBuild(build: catalog.Build) !catalog.Build {
    const allocator = arena.allocator();
    var copy: catalog.Build = .{};
    inline for (.{ "kind", "version", "commit", "tag", "date" }) |field| {
        @field(copy, field) = try allocator.dupe(u8, @field(build, field));
    }
    return copy;
}

fn switchChannel() void {
    const entry = &entries[menu_entry];
    entry.channel = switch (entry.channel) {
        .nightly => .stable,
        .stable => .nightly,
    };
    state.setChannel(entry.app.id, entry.channel);
    if (online) {
        pb.ShowHourglassForce();
        entry.available = available(arena.allocator(), entry.app, entry.channel);
        pb.HideHourglass();
    }
    showList();
    const text = switch (entry.channel) {
        .nightly => t(.channel_nightly),
        .stable => t(.channel_stable),
    };
    pb.Message(pb.ICON_INFORMATION, t(.app_title), text.ptr, 3000);
}

fn confirmUninstall() void {
    const entry = entries[menu_entry];
    const text = i18n.fmt(&dialog_text, .confirm_uninstall, .{entry.app.name()});
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), text.ptr, t(.uninstall).ptr, t(.cancel).ptr, uninstallAnswered);
}

fn uninstallAnswered(button: c_int) callconv(.c) void {
    if (button != 1) return;
    const entry = &entries[menu_entry];
    var buf: [256]u8 = undefined;
    install.uninstall(entry.app) catch |err| {
        pocketbook.showError(i18n.fmt(&buf, .uninstall_error, .{entry.app.name()}), err);
        return;
    };
    state.setInstalled(entry.app.id, null);
    entry.present = false;
    entry.installed = null;
    showList();
    pb.Message(pb.ICON_INFORMATION, t(.app_title), i18n.fmt(&buf, .done_uninstall, .{entry.app.name()}).ptr, 4000);
}

/// Goes to the next language and names the installed apps in it in the applications menu
fn changeLanguage() void {
    language = language.next();
    state.setLanguage(language);
    i18n.lang = language.resolve(readerLanguage());
    _ = pb.SetSubtaskInfo(pb.GetCurrentTask(), 0, t(.app_title), null);
    for (entries) |entry| {
        if (entry.present) _ = install.ensureDeclared(entry.app, entry.app.name(), online);
    }
    showList();
}

pub fn main() void {
    pb.InkViewMain(mainHandler);
}
