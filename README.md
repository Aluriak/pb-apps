# App Manager for PocketBook

Installs, updates and removes apps on PocketBook e-readers (and Vivlio, which are PocketBooks),
from their GitHub releases. In English or French.

| App | What it does |
|---|---|
| [App Manager](https://github.com/Aluriak/pb-apps) | This app: installs and updates the others, and itself |
| [OPDS Connector](https://github.com/Aluriak/pb-opds-connector) | Browse OPDS catalogs and download books. A fork of [codedge/pb-opds-connector](https://codeberg.org/codedge/pb-opds-connector) |
| [Reading Stats](https://github.com/Aluriak/pb-stats) | Statistics about your reading |

## Install

1. Download the archive for your reader from the
   [nightly release](https://github.com/Aluriak/pb-apps/releases/tag/nightly):
   `app-manager-allwinner.zip` for most readers (Era, Verse, InkPad 4, Vivlio Light HD Color…),
   `app-manager-rk3566.zip` for Verta, InkPad One and PocketBook Q.
2. Unzip it and copy `app-manager.app` into the `applications` folder of the reader.
3. Open "app-manager" from the applications list. It then puts itself and the other apps in
   the menu under their names, in a group of their own. From then on it updates itself.

## Use

The app lists the apps with what is installed and what is available. Touch an app to:

* **Install** or **Update** it. The app asks first, saying which version it is, whether it
  is a stable release or a nightly build, and what changed since the release before it.
* **Switch** between stable releases and nightly builds. Apps follow stable releases, versions
  the author tagged, unless you switch them to nightly builds, made from every change and less
  tested. Do that when you know why: to try a fix, or to test what comes next.
* **Uninstall** it. Its settings and your books stay.

When several apps have an update, a first row **Update all** updates them one after the other,
the app manager last.

The last row sets the language: the reader's, French or English.

Installed apps are declared in the reader's applications menu
(`system/config/desktop/view.json`), with their name and an icon, in a group "More apps"
("Autres applications"), instead of showing up under their file name with a "@" in front.
App files have no spaces in their names (`opds-connector.app`): the reader does not start an app
of its menu whose path has one. Files of earlier names (`OPDS Connector.app`) are renamed. Apps installed by hand are declared too. The reader's own
file is kept once as `view.json.before-pb-apps`.

The reader sometimes rewrites this file, e.g. after a firmware update, and the apps then show
up under their file name again. Opening the app manager puts them back in the menu.

The app manager remembers its settings and what it installed in `system/config/pb-apps.cfg`.

## The catalog

The apps on offer are listed in [catalog.txt](catalog.txt), read from this repository each time
the app opens (a copy built into the app is used offline). Each app needs a GitHub repository
whose releases publish:

* `version.txt`: lines `channel=`, `version=`, `commit=`, `tag=`, `date=`
* `notes.txt`, optional: what changed, one line per change, shown before an update
* `<asset>-allwinner.bin` and `<asset>-rk3566.bin`: the app itself, unzipped
* a `nightly` pre-release for nightly builds, ordinary releases for stable ones

Its icons go in [icons/](icons), drawn by `scripts/make-icons.py`.

## Debugging

The `-debug` archives of the nightly release hold a build that writes a log:

1. Copy `app-manager.bin` and `apps-debug.app` into the `applications` folder.
2. Open "apps-debug" instead of the app manager.
3. The log is written to `app-manager-log.txt` at the top of the reader's storage.

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
