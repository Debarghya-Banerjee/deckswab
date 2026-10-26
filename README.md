# Deckswab

A macOS menu bar app that keeps your disk from filling up. It shows free space in the menu bar, warns you when it drops below a limit, and cleans out data that tools regenerate on their own.

## What it cleans

- **Local site MySQL binlogs.** For [Local](https://localwp.com) sites, running sites are purged through MySQL and stopped sites have their log files deleted.
- **Leftover app update downloads.** The `*.ShipIt` installers that apps like VS Code, Slack and Figma leave in `~/Library/Caches`.
- **Developer caches.** npm, Homebrew, TypeScript, Yarn, pip and Composer.
- **Old node_modules.** These are found in the project folders you choose. Anything on your keep-list or installed within the last N days is skipped.

Nothing is deleted until you confirm. Automatic cleaning when space runs low is off by default and can be turned on in Settings.

## Build

Requires macOS 14+ and the Swift toolchain. The Xcode Command Line Tools are enough.

```sh
./build.sh            # builds build/Deckswab.app
./build.sh --install  # also copies it to ~/Applications and launches it
```

Turn on **Open at login** in Settings so it keeps watching.

## Contributing

Issues and pull requests are welcome. Each cleaner lives in `Sources/Deckswab/Cleaner.swift`. Add a new kind of regenerable data by adding a `Category` case and its `scan` branch.

## License

[MIT](LICENSE)
