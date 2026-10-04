# CleanUpMusic

macOS SwiftUI tool for tidying a MinimServer music library (FLAC, MP3, ALAC, WAV, AIFF, APE).

## Features

- **Covers** — lists album folders MinimServer would show without artwork. An album counts as covered when its folder has `folder|cover.jpg|png|webp` or the first track has embedded art.
  - `cover.jpeg` / `folder.jpeg` are renamed to `.jpg` automatically during the scan (MinimServer ignores `.jpeg`).
  - Folders with an image MinimServer can't see (e.g. `front.jpg`) get a one-click rename to `cover.*`.
  - Missing or replaced covers: pick from iTunes / Deezer search results, or set one manually (file, URL, drag & drop). Saved as `cover.<jpg|png|webp>` in the album folder, removing any other `folder.*` / `cover.*` image (MinimServer would show `folder.*` first), and/or embedded in every track. A folder holding several albums (e.g. singles) can only embed, since a folder image would show on all of them.
- **Simplified → Traditional** — finds Simplified Chinese in tags (TITLE, ARTIST, ALBUM, ALBUMARTIST), file names and folder names, converted with OpenCC `s2tw`. Nothing changes until you tick rows and press apply.
  - Changes are grouped per album so one tick converts its folder names, file names and tags together. Tracks sharing ALBUM + album artist (compared after conversion) form one album, so CD1/CD2 folders merge; without an ALBUM or artist tag the folder is the album.
  - A parent folder joins the album when everything beneath it belongs to that album; otherwise (e.g. an artist folder) it is its own group.
- **Album splits** — lists folders whose tracks carry different ALBUM tags, which MinimServer shows as separate albums. Detection only: each ALBUM value is listed with its tracks and nothing is written; folders where the values differ only by case, spacing, punctuation or Simplified/Traditional are flagged and sorted first.
- **CD numbers** — when sibling folders are named like `CD1` / `Disc 2` / `碟3`, proposes `DISCNUMBER` from the folder name and `DISCTOTAL` (number of disc folders) for tracks that lack them, and rewrites ALBUM as `Album [Disc n]` (replacing any trailing CD/Disc marker), the form MinimServer turns into Disc 1 / Disc 2 headings (tracks may sit in a subfolder like `CD1/FLAC`; discs of one set share the ALBUM name found on the most discs, or the parent folder name when no name is on two discs, and the most common ALBUMARTIST, since MinimServer splits an album when either differs); DISCNUMBER alone only makes it number the tracks continuously. Tick rows and apply; tag writes are the only change.

Applying skips any tag that changed since its scan (e.g. after applying another tab) and says so; rescan to pick it up.

Scans keep each file's tags for the session and re-read only files whose size or modification date changed, so switching tabs or rescanning after applying is quick; restart the app after editing tags with a tool that preserves modification dates.

Every rename, tag write, saved cover and removed cover file is appended to `~/Library/Logs/CleanUpMusic/changes.log` (`time  action  old  new`, plus the file for tag writes).

## Requirements

```sh
brew install taglib opencc pkgconf
```

## Run

```sh
swift run
swift test
```

Point it at a copy of an album or two first before running it on the NAS library.
