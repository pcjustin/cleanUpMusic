# CleanUpMusic

macOS SwiftUI tool for tidying a MinimServer music library (FLAC, MP3, ALAC, WAV, AIFF, APE).

## Features

- **Covers** — lists album folders MinimServer would show without artwork. An album counts as covered when its folder has `folder|cover.jpg|png|webp` or the first track has embedded art.
  - `cover.jpeg` / `folder.jpeg` are renamed to `.jpg` automatically during the scan (MinimServer ignores `.jpeg`).
  - Folders with an image MinimServer can't see (e.g. `front.jpg`) get a one-click rename to `cover.*`.
  - Missing covers: pick from iTunes / Deezer search results, or set one manually (file, URL, drag & drop). Saved as `cover.<jpg|png|webp>` in the album folder; audio files are not touched.
- **Simplified → Traditional** — finds Simplified Chinese in tags (TITLE, ARTIST, ALBUM, ALBUMARTIST), file names and folder names, converted with OpenCC `s2tw`. Nothing changes until you tick rows and press apply.
  - Changes are grouped per album so one tick converts its folder names, file names and tags together. Tracks sharing ALBUM + album artist (compared after conversion) form one album, so CD1/CD2 folders merge; without an ALBUM or artist tag the folder is the album.
  - A parent folder joins the album when everything beneath it belongs to that album; otherwise (e.g. an artist folder) it is its own group.

Every rename, tag write and saved cover is appended to `~/Library/Logs/CleanUpMusic/changes.log` (`time  action  old  new`).

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
