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
    opens: union(enum) { app: usize, update_all, menu, language },
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
            install.manage_menu = state.menu();
            // Versions before the setting declared the apps without asking, in a way that
            // did not work: their entries go, the user turns the menu on if they want it
            if (state.menuSet() == null) {
                state.setMenu(false);
                clean_menu = true;
            }
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
    defer clean_menu = false;
    for (apps, entries) |app, *entry| {
        entry.* = .{
            .app = app,
            .channel = state.channel(app.id),
            .present = blk: {
                install.migrate(app);
                break :blk install.isPresent(app);
            },
            .installed = try state.installed(allocator, app.id),
            .available = .unknown,
        };
        // The running manager knows its own build
        // The running manager knows its own build, better than what was noted when it was
        // installed: it may have been replaced by hand since
        if (std.mem.eql(u8, app.id, self_id) and !std.mem.eql(u8, self().commit, "dev")) {
            const running = self();
            if (entry.installed == null or !entry.installed.?.sameCommit(running)) state.setInstalled(app.id, running);
            entry.installed = running;
        }
        if (online) entry.available = available(allocator, app, entry.channel);
        if (clean_menu) install.undeclare(app) catch |err| trace("{s} not taken out: {s}\n", .{ app.id, @errorName(err) });
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
    const build = switch (app.source()) {
        .github => catalog.Build.parse(body),
        .codeberg => catalog.Build.parseCodeberg(allocator, body, app.asset, build_options.platform),
    } catch return .failed;
    return .{ .build = build };
}

fn rebuildRows() !void {
    _ = rows_arena.reset(.retain_capacity);
    const allocator = rows_arena.allocator();
    var list: std.ArrayList(Row) = .empty;

    var pending_buf: [16]usize = undefined;
    const pending = pendingUpdates(&pending_buf);
    if (pending.len > 1) {
        var title_buf: [64]u8 = undefined;
        var names: std.ArrayList(u8) = .empty;
        for (pending, 0..) |i, n| {
            if (n > 0) try names.appendSlice(allocator, ", ");
            try names.appendSlice(allocator, entries[i].app.name());
        }
        try list.append(allocator, .{
            .title = try allocator.dupeSentinel(u8, i18n.fmt(&title_buf, .update_all, .{pending.len}), 0),
            .detail = try allocator.dupeSentinel(u8, names.items, 0),
            .opens = .update_all,
        });
    }

    for (entries, 0..) |entry, i| {
        try list.append(allocator, .{
            .title = try allocator.dupeSentinel(u8, entry.app.name(), 0),
            .detail = try detail(allocator, entry),
            .opens = .{ .app = i },
        });
    }

    var menu_buf: [96]u8 = undefined;
    try list.append(allocator, .{
        .title = try allocator.dupeSentinel(u8, i18n.fmt(&menu_buf, .menu, .{if (install.manage_menu) t(.menu_on) else t(.menu_off)}), 0),
        .detail = t(.menu_change),
        .opens = .menu,
    });

    var buf: [96]u8 = undefined;
    const chosen = switch (language) {
        .auto => t(.language_auto),
        .fr => t(.language_fr),
        .en => t(.language_en),
    };
    try list.append(allocator, .{
        .title = try allocator.dupeSentinel(u8, i18n.fmt(&buf, .language, .{chosen}), 0),
        .detail = t(.language_change),
        .opens = .language,
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

    // Said first: the app is in conflict, or the one to choose
    var note_buf: [256]u8 = undefined;
    const status_text: []const u8 = if (entry.present and rivalOf(entry) != null)
        i18n.fmt(&note_buf, .conflict, .{ status, entries[rivalOf(entry).?].app.name() })
    else if (!entry.present and entry.app.recommended)
        i18n.fmt(&note_buf, .recommended, .{status})
    else
        status;

    var out_buf: [320]u8 = undefined;
    var available_buf: [96]u8 = undefined;
    // The channel followed is always said, it is what an update brings
    const channel = channelName(entry.channel);
    const text = switch (entry.available) {
        .unknown => i18n.fmt(&out_buf, .available, .{ status_text, channel, "?" })[0..],
        .failed => i18n.fmt(&out_buf, .unreachable_build, .{status_text}),
        .none => i18n.fmt(&out_buf, .no_build, .{ status_text, channel }),
        .build => |build| if (entry.present and entry.installed != null and build.sameCommit(entry.installed.?))
            i18n.fmt(&out_buf, .up_to_date, .{ status_text, channel })
        else
            i18n.fmt(&out_buf, .available, .{ status_text, channel, build.describe(&available_buf) }),
    };
    return allocator.dupeSentinel(u8, text, 0);
}

fn channelName(channel: catalog.Channel) [:0]const u8 {
    return switch (channel) {
        .stable => t(.channel_name_stable),
        .nightly => t(.channel_name_nightly),
    };
}

fn showList() void {
    if (page) |p| {
        pb.OpenList(p.title.ptr, null, pb.ScreenWidth(), item_height, @intCast(p.choices.len), 0, pageHandler);
        return;
    }
    rebuildRows() catch return;
    pb.OpenList(t(.app_title), null, pb.ScreenWidth(), item_height, @intCast(rows.len), list_pos, listHandler);
}

/// A page of choices opened from a row: what to do with an app, or the value of a setting.
/// A list like the main one, left with Back: the reader's floating menus close only with a
/// small cross, often hidden under their title.
const Page = struct {
    title: [:0]const u8,
    choices: []const Choice,
};

const Choice = struct {
    title: [:0]const u8,
    detail: [:0]const u8 = "",
    does: Does,
    /// Greyed, does nothing
    inactive: bool = false,
};

const Does = union(enum) { install, switch_channel, uninstall, menu: bool, language: i18n.Choice };

var page: ?Page = null;
var page_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);

fn openPage(build: *const fn (std.mem.Allocator) anyerror!Page) void {
    _ = page_arena.reset(.retain_capacity);
    page = build(page_arena.allocator()) catch return;
    showList();
}

fn pageHandler(action: c_int, x: c_int, y: c_int, idx: c_int, state_flag: c_int) callconv(.c) c_int {
    const p = page orelse return 0;
    switch (action) {
        pb.LIST_PAINT => {
            if (idx < 0 or idx >= p.choices.len) return 0;
            const choice = p.choices[@intCast(idx)];
            paintLines(choice.title, choice.detail, x, y, state_flag != 0, choice.inactive);
        },
        pb.LIST_OPEN => {
            if (idx < 0 or idx >= p.choices.len) return 0;
            const choice = p.choices[@intCast(idx)];
            if (choice.inactive) return 1;
            // Back on the main list, the choice may show a dialog over it
            page = null;
            showList();
            switch (choice.does) {
                .install => confirmInstall(),
                .switch_channel => switchChannel(),
                .uninstall => confirmUninstall(),
                .menu => |on| if (on != install.manage_menu) switchMenu(),
                .language => |chosen| if (chosen != language) setLanguage(chosen),
            }
        },
        pb.LIST_EXIT => {
            page = null;
            showList();
        },
        else => return 0,
    }
    return 1;
}

/// "<detail> · current choice" for the choice in effect
fn marked(allocator: std.mem.Allocator, text: []const u8, current: bool) ![:0]const u8 {
    if (!current) return allocator.dupeSentinel(u8, text, 0);
    return i18n.alloc(allocator, .current, .{text});
}

fn appPage(allocator: std.mem.Allocator) !Page {
    const entry = entries[menu_entry];
    var choices: std.ArrayList(Choice) = .empty;

    var build_buf: [96]u8 = undefined;
    const install_title = if (!entry.present) t(.install) else if (upToDate(entry)) t(.reinstall) else t(.update);
    try choices.append(allocator, switch (entry.available) {
        .build => |build| .{
            .title = install_title,
            .detail = try std.fmt.allocPrintSentinel(allocator, "{s} · {s}", .{ build.describe(&build_buf), kindText(build.kind) }, 0),
            .does = .install,
        },
        else => .{ .title = install_title, .detail = t(.nothing_to_install), .does = .install, .inactive = true },
    });

    try choices.append(allocator, .{
        .title = switch (entry.channel) {
            .nightly => t(.switch_to_stable),
            .stable => t(.switch_to_nightly),
        },
        .detail = try i18n.alloc(allocator, .follows, .{channelName(entry.channel)}),
        .does = .switch_channel,
    });

    // The manager does not remove itself
    if (entry.present and !std.mem.eql(u8, entry.app.id, self_id)) {
        try choices.append(allocator, .{ .title = t(.uninstall), .detail = t(.uninstall_detail), .does = .uninstall });
    }
    return .{ .title = try allocator.dupeSentinel(u8, entry.app.name(), 0), .choices = try choices.toOwnedSlice(allocator) };
}

fn menuPage(allocator: std.mem.Allocator) !Page {
    const choices = try allocator.alloc(Choice, 2);
    choices[0] = .{ .title = t(.menu_off), .detail = try marked(allocator, t(.menu_off_detail), !install.manage_menu), .does = .{ .menu = false } };
    choices[1] = .{ .title = t(.menu_on), .detail = try marked(allocator, t(.menu_on_detail), install.manage_menu), .does = .{ .menu = true } };
    return .{ .title = t(.menu_title), .choices = choices };
}

fn languagePage(allocator: std.mem.Allocator) !Page {
    const options = [_]struct { i18n.Choice, [:0]const u8 }{
        .{ .auto, t(.language_auto) },
        .{ .fr, t(.language_fr) },
        .{ .en, t(.language_en) },
    };
    const choices = try allocator.alloc(Choice, options.len);
    for (options, choices) |option, *choice| {
        choice.* = .{ .title = option[1], .detail = try marked(allocator, "", option[0] == language), .does = .{ .language = option[0] } };
    }
    return .{ .title = t(.language_title), .choices = choices };
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
            switch (rows[@intCast(idx)].opens) {
                .app => |i| {
                    menu_entry = i;
                    openPage(appPage);
                },
                .update_all => confirmUpdateAll(),
                .menu => openPage(menuPage),
                .language => openPage(languagePage),
            }
        },
        pb.LIST_EXIT => pb.CloseApp(),
        else => return 0,
    }
    return 1;
}

fn paintRow(row: Row, x: c_int, y: c_int, selected: bool) void {
    paintLines(row.title, row.detail, x, y, selected, false);
}

fn paintLines(title: [:0]const u8, second: [:0]const u8, x: c_int, y: c_int, selected: bool, inactive: bool) void {
    const width = pb.ScreenWidth();
    const text_width = width - 2 * padding;
    const line_height = @divTrunc(item_height - 2 * padding, 2);
    const flags = pb.ALIGN_LEFT | pb.VALIGN_MIDDLE | pb.DOTS;

    pb.SetFont(title_font, if (inactive) pb.LGRAY else pb.BLACK);
    _ = pb.DrawTextRect(x + padding, y + padding, text_width, line_height, title.ptr, flags);
    pb.SetFont(detail_font, pb.DGRAY);
    _ = pb.DrawTextRect(x + padding, y + padding + line_height, text_width, line_height, second.ptr, flags);
    pb.DrawLine(x, y + item_height - 1, x + width, y + item_height - 1, pb.LGRAY);
    if (selected and !inactive) pb.DrawSelection(x, y, width, item_height, pb.BLACK);
}

/// The app whose page is open, or that an install or uninstall is going on for
var menu_entry: usize = 0;

/// An installed app of the same group as `entry`: it does the same job
fn rivalOf(entry: Entry) ?usize {
    if (entry.app.group.len == 0) return null;
    for (entries, 0..) |other, i| {
        if (!other.present or std.mem.eql(u8, other.app.id, entry.app.id)) continue;
        if (std.mem.eql(u8, other.app.group, entry.app.group)) return i;
    }
    return null;
}

fn upToDate(entry: Entry) bool {
    const installed = entry.installed orelse return false;
    return switch (entry.available) {
        .build => |build| build.sameCommit(installed),
        else => false,
    };
}

var dialog_text: [1536]u8 = undefined;

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
    const rival = if (entry.present) null else rivalOf(entry);
    const text = if (rival) |other|
        i18n.fmt(&dialog_text, .confirm_replace, .{
            entry.app.name(),
            entries[other].app.name(),
            entries[other].app.name(),
            build.describe(&new_buf),
            kindText(build.kind),
        })
    else if (entry.present)
        i18n.fmt(&dialog_text, .confirm_update, .{
            entry.app.name(),
            build.describe(&new_buf),
            if (entry.installed) |old| old.describe(&old_buf) else "?",
            kindText(build.kind),
        })
    else
        i18n.fmt(&dialog_text, .confirm_install, .{ entry.app.name(), build.describe(&new_buf), kindText(build.kind) });
    const with_notes = appendNotes(text.len, entry.app, build);
    const button = if (rival != null) t(.replace) else if (entry.present) t(.update) else t(.install);
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), with_notes.ptr, button.ptr, t(.cancel).ptr, installAnswered);
}

/// Adds what changed in `build` to the text of `dialog_text`, which is `len` bytes long.
/// Without network, or for releases published without notes, the text stays as it is.
fn appendNotes(len: usize, app: catalog.App, build: catalog.Build) [:0]const u8 {
    const text = dialog_text[0..len :0];
    if (!pocketbook.ensureNetwork()) return text;
    var url_buf: [256]u8 = undefined;
    const url = catalog.notesUrl(&url_buf, app, build) catch return text;

    var notes_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer notes_arena.deinit();
    pb.ShowHourglassForce();
    const notes = net.fetch(notes_arena.allocator(), url);
    pb.HideHourglass();
    const body = notes catch |err| {
        trace("no notes at {s}: {s}\n", .{ url, @errorName(err) });
        return text;
    };

    var short_buf: [700]u8 = undefined;
    const short = catalog.shortNotes(&short_buf, body, 8, 60);
    if (short.len == 0) return text;
    return std.fmt.bufPrintSentinel(dialog_text[len..], "\n\n{s}\n{s}", .{ t(.changes), short }, 0) catch return text;
}

fn installAnswered(button: c_int) callconv(.c) void {
    if (button != 1) return;
    const entry = &entries[menu_entry];
    const build = switch (entry.available) {
        .build => |b| b,
        else => return,
    };
    const was_present = entry.present;

    // The reader turns Wi-Fi off after a while, it may be off since the list was loaded
    if (!pocketbook.ensureNetwork()) {
        var buf: [256]u8 = undefined;
        pocketbook.showError(i18n.fmt(&buf, .install_error, .{entry.app.name()}), error.NoNetwork);
        return;
    }
    progress_step = 0;
    pb.OpenProgressbar(pb.ICON_INFORMATION, t(.downloading).ptr, entry.app.name().ptr, 0, null);
    const result = install.install(entry.app, build, entry.app.name(), onProgress);
    pb.CloseProgressbar();

    var buf: [256]u8 = undefined;
    result catch |err| {
        pocketbook.showError(i18n.fmt(&buf, .install_error, .{entry.app.name()}), err);
        return;
    };

    state.setInstalled(entry.app.id, build);
    entry.present = true;
    entry.installed = copyBuild(build) catch build;

    // The apps doing the same job go, so the two are never installed together
    var replaced: ?usize = null;
    while (rivalOf(entry.*)) |other| {
        const rival = &entries[other];
        install.uninstall(rival.app) catch |err| {
            pocketbook.showError(i18n.fmt(&buf, .uninstall_error, .{rival.app.name()}), err);
            break;
        };
        state.setInstalled(rival.app.id, null);
        rival.present = false;
        rival.installed = null;
        replaced = other;
    }

    const done = if (replaced) |other|
        i18n.fmt(&buf, .done_replace, .{ entry.app.name(), entries[other].app.name() })
    else if (std.mem.eql(u8, entry.app.id, self_id))
        t(.done_self_update)
    else if (was_present)
        i18n.fmt(&buf, .done_update, .{entry.app.name()})
    else
        i18n.fmt(&buf, .done_install, .{entry.app.name()});
    showList();
    pb.Message(pb.ICON_INFORMATION, t(.app_title), done.ptr, 6000);
}

/// A copy that outlives the version file it was read from
/// Tenths of the download (or megabytes, when the size is unknown) already shown: e-ink
/// screens are slow, the bar is redrawn about ten times per download only
var progress_step: u64 = 0;

fn onProgress(downloaded: u64, total: u64) void {
    const step = if (total > 0) downloaded * 10 / total else downloaded / (1024 * 1024);
    if (step == progress_step) return;
    progress_step = step;

    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{d} KB", .{downloaded / 1024}, 0) catch return;
    const percent: c_int = if (total > 0) @intCast(@min(100, downloaded * 100 / total)) else 0;
    _ = pb.UpdateProgressbar(text.ptr, percent);
}

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
    online = pocketbook.ensureNetwork();
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
    if (entry.available == .none) {
        const full = i18n.fmt(&dialog_text, .channel_none_yet, .{ text, channelName(entry.channel) });
        pb.Message(pb.ICON_INFORMATION, t(.app_title), full.ptr, 6000);
    } else {
        pb.Message(pb.ICON_INFORMATION, t(.app_title), text.ptr, 3000);
    }
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

/// The installed apps that have something newer on their channel, the manager last as it
/// is replaced while it runs
fn pendingUpdates(buf: []usize) []usize {
    var n: usize = 0;
    var manager: ?usize = null;
    for (entries, 0..) |entry, i| {
        if (!entry.present or entry.available != .build or upToDate(entry)) continue;
        if (std.mem.eql(u8, entry.app.id, self_id)) {
            manager = i;
        } else if (n < buf.len) {
            buf[n] = i;
            n += 1;
        }
    }
    if (manager) |i| if (n < buf.len) {
        buf[n] = i;
        n += 1;
    };
    return buf[0..n];
}

fn confirmUpdateAll() void {
    var pending_buf: [16]usize = undefined;
    const pending = pendingUpdates(&pending_buf);
    if (pending.len == 0) return;

    var lines_buf: [1024]u8 = undefined;
    var len: usize = 0;
    for (pending) |i| {
        const entry = entries[i];
        var build_buf: [96]u8 = undefined;
        const line = i18n.fmt(lines_buf[len..], .update_all_line, .{ entry.app.name(), entry.available.build.describe(&build_buf) });
        len += line.len;
    }
    const text = i18n.fmt(&dialog_text, .confirm_update_all, .{lines_buf[0..len]});
    pb.Dialog(pb.ICON_QUESTION, t(.app_title), text.ptr, t(.update).ptr, t(.cancel).ptr, updateAllAnswered);
}

fn updateAllAnswered(button: c_int) callconv(.c) void {
    if (button != 1) return;
    var pending_buf: [16]usize = undefined;
    const pending = pendingUpdates(&pending_buf);

    if (!pocketbook.ensureNetwork()) {
        pocketbook.showError(t(.loading_error), error.NoNetwork);
        return;
    }

    var updated: usize = 0;
    var self_updated = false;
    var failed_buf: [256]u8 = undefined;
    var failed_len: usize = 0;
    for (pending) |i| {
        const entry = &entries[i];
        const build = entry.available.build;
        progress_step = 0;
        pb.OpenProgressbar(pb.ICON_INFORMATION, t(.downloading).ptr, entry.app.name().ptr, 0, null);
        const result = install.install(entry.app, build, entry.app.name(), onProgress);
        pb.CloseProgressbar();
        result catch |err| {
            trace("update of {s} failed: {s}\n", .{ entry.app.id, @errorName(err) });
            const sep = if (failed_len == 0) "" else ", ";
            const name = std.fmt.bufPrint(failed_buf[failed_len..], "{s}{s}", .{ sep, entry.app.name() }) catch "";
            failed_len += name.len;
            continue;
        };
        state.setInstalled(entry.app.id, build);
        entry.installed = copyBuild(build) catch build;
        updated += 1;
        if (std.mem.eql(u8, entry.app.id, self_id)) self_updated = true;
    }

    var buf: [640]u8 = undefined;
    var len = i18n.fmt(&buf, .done_update_all, .{ updated, pending.len }).len;
    if (failed_len > 0) len += i18n.fmt(buf[len..], .update_all_failed, .{failed_buf[0..failed_len]}).len;
    if (self_updated) {
        if (std.fmt.bufPrintSentinel(buf[len..], "\n\n{s}", .{t(.done_self_update)}, 0)) |more| len += more.len else |_| {}
    }
    const text = buf[0..len :0];

    list_pos = 0;
    showList();
    pb.Message(if (failed_len > 0) pb.ICON_WARNING else pb.ICON_INFORMATION, t(.app_title), text.ptr, 8000);
}

/// Set when the menu file is to be cleaned of the entries of earlier versions
var clean_menu = false;

/// Turns the declaration of the apps in the reader's menu file to the other state
fn switchMenu() void {
    const on = !install.manage_menu;
    // Declared while on, taken out before turning off
    if (on) install.manage_menu = true;
    if (on) online = pocketbook.ensureNetwork();
    pb.ShowHourglassForce();
    for (entries) |entry| {
        if (on) {
            if (entry.present) _ = install.ensureDeclared(entry.app, entry.app.name(), online);
        } else {
            install.undeclare(entry.app) catch |err| trace("{s} not taken out: {s}\n", .{ entry.app.id, @errorName(err) });
        }
    }
    pb.HideHourglass();
    install.manage_menu = on;
    state.setMenu(on);
    showList();
    pb.Message(pb.ICON_INFORMATION, t(.app_title), if (on) t(.menu_now_on) else t(.menu_now_off), 8000);
}

/// Sets the language and names the installed apps in it in the applications menu
fn setLanguage(chosen: i18n.Choice) void {
    language = chosen;
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
