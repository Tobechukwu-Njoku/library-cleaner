# Library Cleaner

Three Bash scripts for [Unraid User Scripts](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)
that tidy up a Radarr/Sonarr media library so Jellyfin, Emby and Kodi pick
everything up correctly.

| Script | Purpose |
| --- | --- |
| `Library Cleaner Film` | Renames subtitles and `.trickplay` folders in movie folders; optional cleanup passes. |
| `Library Cleaner TV` | The same, for Sonarr season folders, pairing files by their `SxxExx` token. |
| `NFO Cleaner` | Recursively deletes every `.nfo` and `.nfo-orig` file. |

## What the renamers do

For each media folder they find the video a file belongs to, then rename its
siblings to match — preserving the subtitle's language code and any trailing
flags (`.hi`, `.sdh`, `.cc`, `.forced`, `.default`, `.foreign`).

```
Video: Film (2020)-Radarr.mkv
Sub:   Film (2020) [Bluray]{imdb-tt123}{tmdb-456}-Radarr.ar.hi.srt
  -->  Film (2020)-Radarr.ar.hi.srt

Trickplay: Film (2020) [old name].trickplay
      -->  Film (2020)-Radarr.trickplay
```

The film script picks the **largest video in the folder** as the feature. The TV
script instead pairs each file to an episode by the `SxxExx` token in its name,
because a season folder holds many videos.

## Usage

1. Copy a script into a new User Script in the Unraid web UI.
2. Edit the `CONFIGURATION` block at the top — at minimum `ROOT_DIRS`.
3. **Run it once with `DRY_RUN="true"`** (the default) and read the log.
4. Only when the log looks right, set `DRY_RUN="false"` and run it for real.

Every destructive option is off by default and honours `DRY_RUN`. Nothing is
deleted in a dry run.

## Configuration

### Common to all three

| Setting | Meaning |
| --- | --- |
| `ROOT_DIRS` | Array of library roots. Each is walked independently. A path that doesn't exist is reported and skipped; the run only aborts when none exist. |
| `DRY_RUN` | `"true"` logs what would happen and changes nothing. |
| `ENABLE_LOG` | `"false"` silences all output. The script still does the work. |
| `LOG_FILE` | Appended to each run. Renamers only — `NFO Cleaner` prints to stdout, which User Scripts captures per run. |
| `TRASH_DIR` | Safety net. When set, files the destructive passes would remove are **moved** here instead, under a timestamped folder mirroring their original path, so a bad run can be undone. Set to `""` to delete outright. The script refuses to start if this sits inside a root. |

### Renamers

| Setting | Meaning |
| --- | --- |
| `VIDEO_EXTS` / `SUB_EXTS` / `ART_EXTS` | File types treated as video, subtitle and artwork. |
| `KNOWN_FLAGS` | Subtitle flags allowed after a language code. |
| `MAX_SUFFIX_PARTS` | How many trailing dot-components may be peeled off a subtitle name. |
| `STRIP_HI` | Drop a trailing `.hi` — but only when another component precedes it, so a lone `.hi` (possibly Hindi) survives. |
| `RESPECT_EXTRA_SUBS` | **Film only, default `"true"`.** A subtitle whose name (minus its language suffix) matches a *different* video in the folder is left alone. Without it, `Film-behindthescenes.en.srt` is renamed onto the feature film and lost. |
| `SEASON_DIR_REGEX` | **TV only.** Which subfolders count as season folders. Empty string scans every subfolder. |
| `EXTRA_LANG_CODES` | Extra language codes beyond the built-in ISO 639-1 and 639-2 sets. Only whitelisted codes are treated as languages, so release tags like `WEB`, `DDP` and `HDR` are not mistaken for one. |
| `DUPLICATE_KEEP` | Which file survives when a rename target already exists and `DELETE_DUPLICATES` is on: `largest` (default) or `existing`. A rename keeps the subtitle's extension, so a collision is always between two files of the same format. |
| `FOLLOW_SYMLINKS` | Pass `-L` to `find` so symlinked roots and subfolders are walked. Off by default — see below. |
| `LOCK_FILE` | Non-blocking `flock`, so a scheduled run that overruns its interval can't have a second copy renaming the same folders. Set to `""` to disable. |

### Destructive options (all default `"false"`)

| Setting | Deletes |
| --- | --- |
| `DELETE_ORPHANS` | Subtitles with no video to belong to. |
| `DELETE_OUTLIERS` | Malformed subtitles — a stray numeric component (`...Radarr.3.hi.srt`) or a duplicated suffix (`...en.en.srt`). |
| `DELETE_DUPLICATES` | A subtitle whose rename target already exists. The existing file is kept. |
| `DELETE_OUTLIER_NFO` | `.nfo` files matching no video in the folder. Keeps `movie.nfo` / `season.nfo`; `tvshow.nfo` lives in the show root and is never touched. |
| `DELETE_OUTLIER_ART` | Images matching no video. Keeps generic names (`poster.jpg`, `fanart2.jpg`), Kodi thumbs (`<video>.jpg`), per-video art (`<video>-poster.jpg`) and, on TV, season art (`season01-poster.jpg`). |
| `DELETE_JUNK` | `.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`, `*.nzb`, `*.torrent`, `RARBG*.txt` and similar. Runs as its own sweep, so it also reaches folders with no video. |
| `PRUNE_EMPTY_DIRS` | Empty folders, last of all, repeating until nothing more can be removed so nested empties collapse. Roots are never removed. |

> `PRUNE_EMPTY_DIRS` in a dry run can only list folders that are empty *at that
> moment*. Parents that empty out once their children are removed aren't listed,
> but will be removed on a real run.

With `TRASH_DIR` set — which is the default — none of these actually delete
anything. Files are moved into the trash folder and can be moved back. Empty
the trash yourself once you're satisfied with a run.

## First live run

Sixteen roots is a lot of blast radius for a first real run, so widen into it:

1. Dry-run with everything destructive off, and read the log.
2. Point `ROOT_DIRS` at **one** root — prefer an `MN` or `OF` one over a
   release-group one, since scene-named files exercise more edge cases — and run
   it live with the destructive flags still off. Confirm Jellyfin still resolves
   subtitles and artwork for a few titles.
3. Turn on one destructive flag at a time, dry-run first, then live.
4. Only then restore the full `ROOT_DIRS` list.

Check `TRASH_DIR` after each live run. It's the record of everything that was
removed, and it's the thing you'd restore from.

## Supported layouts

**Film** — one folder per movie, at any depth under a root. `Films/Film (2020)/`
and `Films/4K/Film (2020)/` both work.

> ⚠️ Do not point the film script at a **flat** folder of loose movie files.
> Every video becomes one group, the largest wins, and every subtitle in that
> folder is renamed onto it.

**TV** — strictly `<ROOT>/<Show>/<Season NN>/`. Season folders must match
`SEASON_DIR_REGEX`, which by default accepts `Season 01`, `Season01`, `Season_1`,
`Season.1` and `Specials` — but not `Series 1`, `S01` or `Staffel 1`. Shows
grouped under a category folder (`TV/Anime/Show/Season 01`) sit one level too
deep; add each category as its own entry in `ROOT_DIRS`.

Episodes are matched on an `SxxExx` token, so **absolute-numbered anime**
(`Show - 001 - Title.mkv`) and **date-named daily shows** are skipped rather than
renamed, and logged as `no SxxExx`. Multi-episode files (`S01E01-E02`) key off
the first token.

**NFO Cleaner** — layout-agnostic.

## Symlinked paths

By default `find` is not told to follow symbolic links, so **a symlinked library
path is walked as a link rather than a directory and yields nothing**. A
symlinked root used to be especially misleading: it passes the existence check,
gets logged as a valid root, and the script then reports a successful run having
done no work at all. That case is now reported —

```
 WARNING: that root is a symlink and FOLLOW_SYMLINKS
          is "false", so it will yield nothing.
```

— but symlinked *subdirectories* inside a real root are still skipped without a
message, since finding them would mean walking the tree twice.

Two ways to handle it: point `ROOT_DIRS` at the real path,

```bash
readlink -f "/mnt/user/Media-Large/Films"
```

or set `FOLLOW_SYMLINKS="true"`. Following links means `find` can reach the same
file by several paths, and a symlink loop will make it error out, so prefer the
real path where you know it.

Hardlinks — what Radarr and Sonarr normally create — are unaffected. This is
only about symlinks.

## Development

The two renamers share most of their logic, so they are assembled from
`src/` rather than maintained separately:

```
src/common.sh   shared logic - logging, subtitle and trickplay handling,
                the .nfo, artwork, junk and empty-folder passes
src/film.sh     header, configuration, and the largest-video-per-folder pass
src/tv.sh       header, configuration, and the SxxExx episode-matching pass
```

Each `src/*.sh` pulls the shared half in with a `#@include common.sh` line, and
`./build.sh` inlines it to produce the two self-contained scripts at the repo
root — so what you paste into Unraid is still a single file with no
dependencies.

**Edit `src/`, never the generated scripts at the repo root.** Run `./build.sh`
afterwards and commit both. The test suite fails if a generated script is stale.

Run the tests with:

```bash
./tests/docker-run.sh
```

A container is needed because the scripts require bash 4.1+ with GNU findutils
and coreutils; macOS ships bash 3.2 and BSD tools.

## Requirements

- Bash 4.1 or newer (associative arrays, `${var,,}`, `exec {fd}>>`).
- GNU `find` and `stat`. Both are standard on Unraid; BusyBox builds differ.

## Licence

MIT — see [LICENSE](LICENSE).
