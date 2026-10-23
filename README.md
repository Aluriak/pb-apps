# App Manager for PocketBook

Installs, updates and removes apps on PocketBook e-readers (and Vivlio, which are PocketBooks),
from their GitHub releases. In English or French.

| App | What it does |
|---|---|
| [App Manager](https://github.com/Aluriak/pb-apps) | This app: installs and updates the others, and itself |
| [OPDS Connector](https://codeberg.org/codedge/pb-opds-connector) | **Recommended.** Browse OPDS catalogs and download books. The original app by codedge, from its Codeberg releases |
| [OPDS Connector (fork)](https://github.com/Aluriak/pb-opds-connector) | A fork of the above, with sync of lists, book sheets, covers and French |
| [Reading Stats](https://github.com/Aluriak/pb-stats) | Statistics about your reading |

## Install

1. Download the archive for your reader from the
   [latest release](https://github.com/Aluriak/pb-apps/releases/latest):
   `app-manager-allwinner.zip` for most readers (Era, Verse, InkPad 4, Vivlio Light HD Color…),
   `app-manager-rk3566.zip` for Verta, InkPad One and PocketBook Q.
2. Unzip it and copy `app-manager.app` into the `applications` folder of the reader.
3. Open "@app-manager" from the applications list. From then on it updates itself, and can
   give the apps their names and icons in the menu (see below).

## Use

The app lists the apps with what is installed and what is available. Touch an app to open its
page, left with Back, and:

* **Install** or **Update** it. The app asks first, saying which version it is, whether it
  is a stable release or a nightly build, and what changed since the release before it.
* **Switch** between stable releases and nightly builds. Apps follow stable releases, versions
  the author tagged, unless you switch them to nightly builds, made from every change and less
  tested. Do that when you know why: to try a fix, or to test what comes next.
* **Uninstall** it. Its settings and your books stay.

When several apps have an update, a first row **Update all** updates them one after the other,
the app manager last.

Some apps do the same job, like the original OPDS Connector and its fork: they are never
installed together. Installing one asks to replace the other, which is then uninstalled; their
settings file is shared, so servers and logins stay. The one to choose when in doubt is marked
"recommended".

The last row opens a page to choose the language: the reader's, French or English.

### Names and icons in the menu (optional)

By default the app manager leaves the reader's menu alone: the apps show in the applications
list under their file name, with a "@" in front (`@opds-connector`).

The row **Menu** opens a page to choose between file names and names with icons. The latter turns on their declaration in the reader's menu file
(`system/config/desktop/view.json`): each app then shows with its name and an icon, in a group
"More apps" ("Autres applications"). Turning it off takes them out of the file again. The
reader's own file is kept once as `view.json.before-pb-apps`. Restart the reader if the menu
does not change.

Each app is declared the way entries known to work on readers are: the key named after the app
file (`U_opds-connector` for `opds-connector.app`), absolute paths
(`/mnt/ext1/applications/opds-connector.app`), and icons as 8-bit BMP files of 106 pixels.

The reader sometimes rewrites this file, e.g. after a firmware update, and the apps then show
up under their file name again. With the option on, opening the app manager puts them back.

Versions before 0.1.4 declared the apps without asking, in a way that did not work on every
reader. The first start of 0.1.4 takes those entries out; turn the option on to try again.

The app manager remembers its settings and what it installed in `system/config/pb-apps.cfg`.

## The catalog

The apps on offer are listed in [catalog.txt](catalog.txt), read from this repository each time
the app opens (a copy built into the app is used offline). Each app needs a GitHub repository
whose releases publish:

* `version.txt`: lines `channel=`, `version=`, `commit=`, `tag=`, `date=`
* `notes.txt`, optional: what changed, one line per change, shown before an update
* `<asset>-allwinner.bin` and `<asset>-rk3566.bin`: the app itself, unzipped
* a `nightly` pre-release for nightly builds, ordinary releases for stable ones

An app published on Codeberg is listed with its repository as `codeberg:owner/name`. Its
releases are read through Codeberg's API, and the app is taken out of the zip for the reader's
platform, `<asset>-<tag>-<platform>.zip` (or `<asset>-nightly-<date>-<commit>-<platform>.zip`
for the pre-release `nightly`). That is how the original OPDS Connector is offered, as its
author publishes it, under its own file name `opds-connector-original.app`.

Its icons go in [icons/](icons), drawn by `scripts/make-icons.py`.

## Debugging

The `-debug` archives of the nightly release hold a build that writes a log:

1. Copy `app-manager.bin` and `apps-debug.app` into the `applications` folder.
2. Open "apps-debug" instead of the app manager.
3. The log is written to `app-manager-log.txt` in the `system` folder of the reader (out of the library, which takes text files for books).

## Development

Needs [Zig](https://ziglang.org) 0.17.0.

```sh
make test        # unit tests, on the build machine
make build-all   # the app for both platforms, into zig-out/<platform>/bin
```

`PB_APPS_TEST_VIEW=/path/to/view.json make test` also checks the menu changes on a real
reader's view.json.

### Releases

Every push to `main` replaces the nightly release. To publish a stable release, set the new
version in `build.zig.zon` and push it to `main`: the build workflow sees that this version has
no release yet and publishes one, tagged `v<version>`.

## Licence

GPL-3.0, see [LICENSE](LICENSE).
