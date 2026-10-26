# Deckswab

A macOS menu bar app that keeps your disk from filling up. It shows free space in the menu bar, warns you when it drops below a limit, and opens a window that shows what is taking up space and what can safely go.

## Features

- **Smart Scan** checks 16 areas in parallel and ticks only what is safe to remove.
- **Space Lens** maps any folder as a treemap you can click into, like DaisyDisk.
- **Review before cleaning.** Nothing is removed until you confirm, and the review sheet says what is deleted and what goes to the Trash.
- **Undo.** Anything moved to the Trash can be put back with one click.
- **Always Ignore** hides an item from future scans. Manage the list in Settings.
- **Quick Look, search and sort** in every list.
- **Purgeable space** is shown separately, so the numbers match Finder.
- **Automatic cleaning** when space runs low is off by default. It only removes data that rebuilds itself.

## What it cleans

**System junk** is deleted outright, because whatever made it rebuilds it.

- **App caches** in `~/Library/Caches`. Caches of running apps are left unticked.
- **Logs** in `~/Library/Logs`.
- **Leftover app updates.** The `*.ShipIt` installers that apps like VS Code, Slack and Figma leave behind.
- **iOS firmware files** that Finder downloaded.
- **Uninstalled app leftovers.** Preferences and support files of apps that are gone. These are never ticked and go to the Trash. An identifier counts only when no installed app comes from the same vendor.
- **Trash.** Needs Full Disk Access.

**Developer** data is deleted outright, or removed by its own tool.

- **Package caches.** npm, pnpm, Yarn, Bun, Homebrew, pip, Poetry, uv, CocoaPods, Go, Deno, Gradle, Maven, Cargo, Composer, WP-CLI, TypeScript, node-gyp, Playwright and Puppeteer.
- **Xcode.** DerivedData, device support, previews, caches and unavailable simulators. Archives are listed but never ticked.
- **Docker.** Build cache, unused images and stopped containers, through `docker … prune`. Volumes are never touched.
- **Homebrew old versions**, through `brew cleanup`.
- **Old project dependencies** in the folders you choose: `node_modules`, Python virtualenvs, Rust `target` and Next.js, Nuxt, Turborepo, Parcel and Angular caches. Each is recognised only next to the file that proves what made it, such as `Cargo.toml`.
- **Local site MySQL binlogs.** For [Local](https://localwp.com) sites, running sites are purged through MySQL and stopped sites have their log files deleted.

**Your files** go to the Trash. Apart from installers, none of them are ticked until you tick them.

- **Installers.** Disk images and packages in Downloads and on the Desktop.
- **Old downloads** added more than N days ago.
- **Large files** in your home folder.
- **iPhone and iPad backups.** Needs Full Disk Access.

## Build

Requires macOS 15+ and the Swift toolchain. The Xcode Command Line Tools are enough.

```sh
./build.sh            # builds build/Deckswab.app
./build.sh --install  # also copies it to ~/Applications and launches it
```

Turn on **Open at login** in Settings so it keeps watching. To see the Trash and device backups, give Deckswab Full Disk Access in System Settings › Privacy & Security.

The app icon is drawn by `swift scripts/make-icon.swift`.

## Contributing

Issues and pull requests are welcome. To add a new kind of data:

1. Add a `Category` case in `Sources/Deckswab/Models.swift` with its group, title, symbol and summary.
2. Add its `scan` branch in `Sources/Deckswab/Scanner.swift`. Developer and file scanners live in `Scanner+Developer.swift` and `Scanner+Files.swift`.
3. Give it a colour in `Components.swift`.

## License

[MIT](LICENSE)
