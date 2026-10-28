# DiskBro

A native macOS 26 app for managing disk space on small drives: full overview, full control, and smart recommendations. Built with SwiftUI and Liquid Glass.

## Features

- **Overview**: free space, a capacity bar broken down by category, a health warning when space is low, and top recommendations.
- **Explore**: an interactive sunburst you can drill into, plus a sortable list with multi-select, Reveal, and Move to Trash.
- **Cleanup**: recommendations rated Safe, Review or Careful. Covers app and sandbox caches, logs, installers, DerivedData, device support, simulator runtimes and orphaned simulators, package manager caches, Homebrew, `node_modules`/venv/build output, Docker, old downloads, stale large files, hidden dot-folders, unused apps, `/Users/Shared`, and iOS backups.
- **Large Files**: a filterable, sortable table by kind, size and last used.
- **Duplicates**: identical files matched by content (size, then partial hash, then SHA-256).
- **History**: free space over time, the projected runway until the disk is full, and which folders grew or shrank since the last scan.
- **Hidden Space**: reconciles APFS volumes (System, Data, VM/swap, Preboot) with what the scan sees, purgeable space, Time Machine local snapshots, and protected folders.

Every deletion goes through a review sheet and moves items to the Trash. Emptying the Trash is a separate, explicit step. Command-based cleanups show the exact command before running it.

## Build

```sh
./scripts/build.sh            # builds build/DiskBro.app
./scripts/build.sh --install  # also copies it to /Applications
```

Requires Xcode with the macOS 26 SDK (Swift 6.2+).

For complete numbers, grant DiskBro **Full Disk Access** in System Settings ▸ Privacy & Security. The app is ad-hoc signed, so after a rebuild you may need to toggle that permission off and on again.

`DiskBro --selftest` runs a headless scan and prints the breakdown and recommendations.

## How scanning works

A parallel POSIX walker (`readdir` + `fstatat`) measures allocated blocks, counts hard links once, stays on the boot volumes, skips firmlink duplicates under `/System/Volumes`, and never triggers iCloud downloads of evicted folders. Files under 1 MB are folded into one entry per folder to keep memory low on multi-million-file disks.
