# CleanUpMusic

macOS (SwiftUI) and Windows (WinUI 3) tool for tidying a MinimServer music library (FLAC, MP3, ALAC, WAV, AIFF, APE).

## Features

- **Covers** — lists album folders MinimServer would show without artwork. An album counts as covered when its folder has `folder|cover.jpg|png|webp` or the first track has embedded art; in a folder holding several albums only embedded art counts, and a folder image there, which would show on all of them, can be deleted.
  - `cover.jpeg` / `folder.jpeg` are renamed to `.jpg` automatically during the scan (MinimServer ignores `.jpeg`).
  - Folders with an image MinimServer can't see (e.g. `front.jpg`) get a one-click rename to `cover.*`.
  - Missing or replaced covers: pick from iTunes (Taiwan and Japan stores) / Deezer / MusicBrainz (Cover Art Archive, shown last as it is slower) search results, or set one manually (file, URL, drag & drop). Saved as `cover.<jpg|png|webp>` in the album folder, removing any other `folder.*` / `cover.*` image (MinimServer would show `folder.*` first), and/or embedded in every track. A folder holding several albums (e.g. singles, where each track without an ALBUM tag counts as its own) can only embed, since a folder image would show on all of them.
- **Simplified → Traditional** — finds Simplified Chinese in tags (TITLE, ARTIST, ALBUM, ALBUMARTIST), file names and folder names, converted with OpenCC `s2tw`. Japanese is left alone: any text containing kana, and whole albums with kana in a tag, file or folder name (a lone の, which Chinese titles borrow, doesn't count). Nothing changes until you tick rows and press apply.
  - Changes are grouped per album so one tick converts its folder names, file names and tags together. Tracks sharing ALBUM + album artist (compared after conversion) form one album, so CD1/CD2 folders merge; without an ALBUM or artist tag the folder is the album.
  - A parent folder joins the album when everything beneath it belongs to that album; otherwise (e.g. an artist folder) it is its own group.
- **Album splits** — lists folders whose tracks carry different ALBUM tags, which MinimServer shows as separate albums. Detection only: each ALBUM value is listed with its tracks and nothing is written; folders where the values differ only by case, spacing, punctuation or Simplified/Traditional are flagged and sorted first.
- **CD numbers** — when sibling folders are named like `CD1` / `Disc 2` / `碟3`, proposes `DISCNUMBER` from the folder name and `DISCTOTAL` (number of disc folders) for tracks that lack them, and rewrites ALBUM as `Album [Disc n]` (replacing any trailing CD/Disc marker), the form MinimServer turns into Disc 1 / Disc 2 headings (tracks may sit in a subfolder like `CD1/FLAC`; discs of one set share the ALBUM name found on the most discs, or the parent folder name when no name is on two discs, and the most common ALBUMARTIST, since MinimServer splits an album when either differs); DISCNUMBER alone only makes it number the tracks continuously. Tick rows and apply; tag writes are the only change.
- **Garbled names (亂碼檔名)** — finds file and folder names (every file, not just audio) whose bytes were read in the wrong code page and renames them to the right text: Shift-JIS, GBK, Big5, Korean (CP949) or UTF-8 shown as Western (cp1252) or DOS (cp437, how ZIP tools read names without the UTF-8 flag), or GBK/Big5/Korean shown as Shift-JIS. Names with a few accented letters, curly quotes or « » are real European names and left alone. A track's TITLE settles which reading is meant; a name garbled past reading (`・` where bytes were lost) is rebuilt from its TITLE, keeping the track number and extension, when the TITLE itself reads fine or can be repaired. Tick rows and apply.

Each scan ends with a message saying what it found, and an apply with what it applied and what the rescan found.

Applying skips any tag that changed since its scan (e.g. after applying another tab) and says so; rescan to pick it up.

Scans keep each file's tags, also across restarts (`~/Library/Caches/CleanUpMusic/tags.json`, Windows: `%LOCALAPPDATA%\CleanUpMusic\tags.json`), and re-read only files whose size or modification date changed, so only the very first scan of a library reads every file; delete that file after editing tags with a tool that preserves modification dates.

Every rename, tag write, saved cover and removed cover file is appended to `~/Library/Logs/CleanUpMusic/changes.log` (Windows: `%LOCALAPPDATA%\CleanUpMusic\changes.log`) (`time  action  old  new`, plus the file for tag writes).

## Layout

- `Sources/CleanUpMusicCore` — shared by both platforms. Models and scanning (`Library`, `Tags`, `Chinese`, `CoverSearch`) and the controllers (`AppController`, `CoverPickerController`) that hold the window's state and actions: filters, grouping, ticks, scans, applying, the cover picker.
- `Sources/CleanUpMusic` — macOS views (SwiftUI), built on macOS only.
- `Sources/CleanUpMusicBridge` — Windows only: the core as `CleanUpMusicBridge.dll` with a small C API; each window section is a JSON document it pushes on change, and the UI sends commands back.
- `windows/CleanUpMusic` — Windows views (WinUI 3, C#), laid out like the macOS ones.

## macOS

```sh
brew install taglib opencc pkgconf dylibbundler
swift run
swift test
./build-dmg.sh
```

`./build-dmg.sh` produces `dist/CleanUpMusic.dmg`, an app with TagLib, OpenCC and its dictionaries inside, so other Macs need no Homebrew. It needs the same macOS version as the build machine or newer (Homebrew's libraries are built for it). It is ad-hoc signed, not notarized: on another Mac, right-click → Open the first time, or run `xattr -cr /Applications/CleanUpMusic.app`.

## Windows

Needs the Swift toolchain, Visual Studio 2026 with the C++ and WinUI (Windows App SDK, .NET) workloads; TagLib and OpenCC come from Visual Studio's vcpkg.

```powershell
windows\build.cmd            # or double-click it; add -Test to also run the core tests
.\windows\build.ps1          # the same, from PowerShell (needs a script policy that allows it)
```

It produces `windows\dist\CleanUpMusic-win-x64.zip`. On another PC, unzip it, run `install-prerequisites.cmd` once (it installs the .NET 10 Desktop Runtime and Windows App Runtime 1.8 from the bundled installers, skipping what is already there), then run `CleanUpMusic.exe`. A folder passed on the command line (or dropped on the exe) opens as if picked.

Point it at a copy of an album or two first before running it on the NAS library.
