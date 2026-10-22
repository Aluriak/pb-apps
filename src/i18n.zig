//! The texts of the app, in English and French.

const std = @import("std");

pub const Lang = enum {
    en,
    fr,

    /// The language for a reader language code ("fr", "fr_FR", "en", ...)
    pub fn fromCode(code: []const u8) Lang {
        return if (std.ascii.startsWithIgnoreCase(code, "fr")) .fr else .en;
    }
};

/// What the user picked: follow the reader, or one of the languages
pub const Choice = enum {
    auto,
    en,
    fr,

    pub fn parse(text: []const u8) Choice {
        return std.meta.stringToEnum(Choice, std.mem.trim(u8, text, " \t\r\n")) orelse .auto;
    }

    pub fn next(choice: Choice) Choice {
        return switch (choice) {
            .auto => .fr,
            .fr => .en,
            .en => .auto,
        };
    }

    pub fn resolve(choice: Choice, reader_code: []const u8) Lang {
        return switch (choice) {
            .auto => Lang.fromCode(reader_code),
            .en => .en,
            .fr => .fr,
        };
    }
};

/// The language texts are given in
pub var lang: Lang = .en;

/// Every text, first in English, then in French. Texts with {} take arguments, see `fmt`.
const texts = .{
    .app_title = .{ "App Manager", "Gestionnaire d'apps" },
    .loading_error = .{ "Could not load the list of apps", "Impossible de charger la liste des apps" },
    .offline = .{ "No network: versions are not shown", "Pas de réseau : les versions ne sont pas affichées" },
    .not_installed = .{ "Not installed", "Non installée" },
    .installed = .{ "Installed: {s}", "Installée : {s}" },
    .installed_unknown = .{ "Installed, version unknown", "Installée, version inconnue" },
    .available = .{ "{s} · {s} available: {s}", "{s} · {s} disponible : {s}" },
    .up_to_date = .{ "{s} · up to date ({s})", "{s} · à jour ({s})" },
    .no_build = .{ "{s} · no {s} yet", "{s} · pas encore de {s}" },
    .channel_name_stable = .{ "stable release", "version stable" },
    .channel_name_nightly = .{ "nightly build", "version nightly" },
    .unreachable_build = .{ "{s} · could not check", "{s} · vérification impossible" },
    .install = .{ "Install", "Installer" },
    .downloading = .{ "Downloading", "Téléchargement" },
    .update = .{ "Update", "Mettre à jour" },
    .reinstall = .{ "Reinstall", "Réinstaller" },
    .uninstall = .{ "Uninstall", "Désinstaller" },
    .cancel = .{ "Cancel", "Annuler" },
    .channel_stable = .{ "Now following stable releases.", "Suit maintenant les versions stables." },
    .channel_nightly = .{ "Now following nightly builds.", "Suit maintenant les versions nightly." },
    .channel_none_yet = .{ "{s}\n\nThere is no {s} yet: the installed version stays until there is one.", "{s}\n\nIl n'y a pas encore de {s} : la version installée reste en place en attendant." },
    .switch_to_stable = .{ "Switch to stable releases", "Passer aux versions stables" },
    .switch_to_nightly = .{ "Switch to nightly builds", "Passer aux versions nightly" },
    .kind_release = .{ "a stable release", "une version stable" },
    .kind_nightly = .{ "a nightly build, made from the latest changes and less tested", "une version nightly, faite à partir des derniers changements et moins testée" },
    .kind_dev = .{ "a development build", "une version de développement" },
    .confirm_install = .{ "Install {s}?\n\nVersion {s}\nThis is {s}.", "Installer {s} ?\n\nVersion {s}\nC'est {s}." },
    .confirm_update = .{ "Update {s}?\n\nNew: {s}\nInstalled: {s}\nThis is {s}.", "Mettre à jour {s} ?\n\nNouvelle : {s}\nInstallée : {s}\nC'est {s}." },
    .confirm_uninstall = .{ "Uninstall {s}?\n\nYour books and the app's settings stay.", "Désinstaller {s} ?\n\nVos livres et les réglages de l'app restent." },
    .done_install = .{ "{s} is installed. It is in the applications list.", "{s} est installée. Elle est dans la liste des applications." },
    .done_update = .{ "{s} is updated. Close it and open it again if it is open.", "{s} est à jour. Fermez-la et rouvrez-la si elle est ouverte." },
    .done_self_update = .{ "The app manager is updated. Close it and open it again to use the new version.", "Le gestionnaire est à jour. Fermez-le et rouvrez-le pour utiliser la nouvelle version." },
    .done_uninstall = .{ "{s} is uninstalled.", "{s} est désinstallée." },
    .install_error = .{ "Could not install {s}", "Impossible d'installer {s}" },
    .uninstall_error = .{ "Could not uninstall {s}", "Impossible de désinstaller {s}" },
    .nothing_to_install = .{ "Nothing is published on this channel yet.", "Rien n'est encore publié sur ce canal." },
    .language = .{ "Language: {s}", "Langue : {s}" },
    .language_auto = .{ "same as the reader", "celle de la liseuse" },
    .language_change = .{ "Tap to change", "Touchez pour changer" },
    .language_en = .{ "English", "English" },
    .language_fr = .{ "Français", "Français" },
};

pub const Key = std.meta.FieldEnum(@TypeOf(texts));

/// A text without arguments
pub fn t(comptime key: Key) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    return switch (lang) {
        .en => pair[0],
        .fr => pair[1],
    };
}

/// A text with arguments, written into `buf`
pub fn fmt(buf: []u8, comptime key: Key, args: anytype) [:0]const u8 {
    const pair = @field(texts, @tagName(key));
    const text = switch (lang) {
        .en => std.fmt.bufPrintSentinel(buf, pair[0], args, 0),
        .fr => std.fmt.bufPrintSentinel(buf, pair[1], args, 0),
    };
    return text catch "…";
}

test "every text exists in both languages with the same arguments" {
    inline for (@typeInfo(@TypeOf(texts)).@"struct".field_names) |name| {
        const pair = @field(texts, name);
        try std.testing.expectEqual(2, pair.len);
        try std.testing.expectEqual(std.mem.count(u8, pair[0], "{s}"), std.mem.count(u8, pair[1], "{s}"));
    }
}

test "texts follow the chosen language" {
    lang = .fr;
    defer lang = .en;
    try std.testing.expectEqualStrings("Installer", t(.install));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Installée : 0.3.1", fmt(&buf, .installed, .{"0.3.1"}));
}

test "the reader's language decides when the choice is auto" {
    try std.testing.expectEqual(Lang.fr, Choice.auto.resolve("fr_FR"));
    try std.testing.expectEqual(Lang.en, Choice.auto.resolve("de"));
    try std.testing.expectEqual(Lang.en, Choice.en.resolve("fr"));
    try std.testing.expectEqual(Choice.fr, Choice.parse("fr\n"));
    try std.testing.expectEqual(Choice.auto, Choice.parse("klingon"));
}
