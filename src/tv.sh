#!/bin/bash
# ============================================================
#  Library Cleaner - TV  (Unraid UserScripts)
# ============================================================
#  TV layout assumed:
#    <ROOT>/<Show (Year) [tvdbid-XXX]>/Season NN/<episode files>
#
#  Unlike the movie script, each season folder contains MANY
#  video files (one per episode). Subtitles and trickplay folders
#  are paired with their specific episode by the SxxExx token in
#  the filename, NOT by "largest video".
#
#  For each season folder:
#    1. Build a map  SxxExx -> episode video file
#    2. For every subtitle (.srt/.sub/.ass/.ssa/.vtt/.idx/.sup):
#         - Extract its SxxExx token
#         - Peel its language/flag suffix (.en, .ar.hi, etc.)
#         - Rename to <episode_video_base><suffix>.<ext>
#    3. For every <name>.trickplay folder:
#         - Extract its SxxExx token
#         - Rename to
#           <episode_video_basename_without_extension>.trickplay
#    4. Optionally clear out leftovers: orphaned subtitles,
#       malformed subtitles, duplicate subtitles, stale .nfo
#       files, stale artwork, junk files and empty folders.
#       Every deletion is opt-in and honours DRY_RUN.
#
#  Multi-episode files (Show - S01E01-E02 - Title.mkv) are keyed
#  by their FIRST SxxExx token; their subtitles/trickplay are
#  expected to share that token.
#
#  Trickplay example:
#    Video:     Show - S01E01 - Title.mkv
#    Trickplay: Show - S01E01 - Old Title.trickplay
#    -->        Show - S01E01 - Title.trickplay
# ============================================================

# --------------------- CONFIGURATION ------------------------

# One or more library roots to scan. Each is walked
# independently; a path that does not exist is reported and
# skipped. Add as many lines as you like.
ROOT_DIRS=(
    "/mnt/user/Media-Large/Shows/[1080p, OF]"
    "/mnt/user/Media-Large/Shows/[1080p, MN]"
    "/mnt/user/Media-Large/Shows/[2160p, MN]"
    "/mnt/user/Media-Large/Shows/[2160p, OF]"
    "/mnt/user/Media-Huge/Shows/[2160p, RX]"
    "/mnt/user/Media-Huge/Shows/[2160p, BD]"
    "/mnt/user/Media-Huge/Shows/[1080p, RX]"
    "/mnt/user/Media-Huge/Shows/[1080p, BD]"
)

# Leave DRY_RUN="true" for the first run. Inspect log, then flip.
DRY_RUN="true"

# Set to "false" to disable ALL logging (file + console). The
# script still runs and performs renames silently.
ENABLE_LOG="true"

# Log file - ignored when ENABLE_LOG="false".
LOG_FILE="/mnt/user/appdata/subtitle_renamer/rename_tv.log"

VIDEO_EXTS=(mkv mp4 avi m4v mov mpg mpeg wmv flv webm ts m2ts)
SUB_EXTS=(srt sub ass ssa vtt idx sup)
ART_EXTS=(jpg jpeg png webp tbn bmp)
KNOWN_FLAGS=(hi sdh cc forced default foreign cc1 cc2)
MAX_SUFFIX_PARTS=3

# Strip a trailing ".hi" (hearing-impaired) ONLY when another
# language/flag component precedes it. A lone ".hi" is preserved
# because it might be the Hindi language code.
STRIP_HI="false"

# DESTRUCTIVE. When "true", subtitle files in a season folder
# whose SxxExx token has no matching episode video are DELETED.
# Subs without any SxxExx token are also deleted, since they
# can't be paired. Honors DRY_RUN — nothing is removed in
# dry-run mode. Leave "false" unless you've reviewed at least one
# dry-run log and trust the result.
DELETE_ORPHANS="false"

# DESTRUCTIVE. When "true", a subtitle whose rename target ALREADY
# EXISTS (currently logged as [SUB SKIP exists]) is DELETED instead
# of being left in place. The pre-existing file at the target path
# is kept untouched. Honors DRY_RUN.
DELETE_DUPLICATES="false"

# DESTRUCTIVE. When "true", subtitle files whose name is malformed
# in one of the patterns below are DELETED instead of being
# renamed. Honors DRY_RUN. Detects:
#   1. A numeric component just before the lang/flag suffix:
#        ...S01E01.3.hi.srt   ...S01E01.7.hi.srt
#      (typically junk left over from audio-track-ID parsing)
#   2. Duplicate components in the peeled suffix:
#        ...S01E01.hi.hi.srt   ...S01E01.en.en.srt
DELETE_OUTLIERS="false"

# DESTRUCTIVE. When "true", any .nfo file in a season folder whose
# basename does NOT match any episode video's basename (and isn't
# the alternate "season.nfo" convention) is DELETED. Honors
# DRY_RUN. Useful for clearing out stale .nfo files left behind
# from prior episode renames. (tvshow.nfo lives in the show root,
# not a season folder, so it's untouched by this script.)
DELETE_OUTLIER_NFO="false"

# DESTRUCTIVE. When "true", image files in a season folder that
# don't correspond to any episode there are DELETED. Honors
# DRY_RUN. An image is KEPT when it is:
#   - a generic artwork name        (poster.jpg, fanart2.jpg, ...)
#   - a season artwork name         (season01-poster.jpg, ...)
#   - "<episode basename>.<ext>"    (Kodi thumb convention)
#   - "<episode basename>-<arttype>"
# Anything else is treated as a leftover from a prior rename.
DELETE_OUTLIER_ART="false"

# DESTRUCTIVE. When "true", files matching JUNK_GLOBS anywhere
# under the roots are DELETED. Honors DRY_RUN. This runs as its
# own sweep, so it also reaches show roots and non-season folders.
DELETE_JUNK="false"

# DESTRUCTIVE. When "true", empty folders under the roots are
# removed after all other passes (so folders emptied by this run
# are caught too). Nested empties collapse: the pass repeats
# until nothing more can be removed. The roots themselves are
# never removed. Honors DRY_RUN.
PRUNE_EMPTY_DIRS="false"

# Only descend into folders matching this regex. Sonarr always
# uses "Season NN" (and "Specials" for Season 00). Set to an
# empty string to scan every subfolder of every show.
SEASON_DIR_REGEX='^(Season[ _.-]?[0-9]+|Specials)$'

# Generic artwork basenames, used by DELETE_OUTLIER_ART. A
# trailing number is allowed automatically (fanart2, backdrop3).
GENERIC_ART_NAMES=(
    poster folder cover fanart backdrop background banner thumb
    landscape logo clearart clearlogo disc discart cdart keyart
    characterart art extrafanart
)

# Artwork type suffixes that may follow an episode basename, used
# by DELETE_OUTLIER_ART. A trailing number is allowed
# automatically.
ART_SUFFIXES=(
    poster fanart backdrop banner thumb landscape logo clearart
    clearlogo disc discart cdart keyart
)

# Season-level artwork names kept by DELETE_OUTLIER_ART, e.g.
# season01-poster.jpg, season-specials-banner.jpg,
# season-all-poster.jpg.
SEASON_ART_RE='^season([0-9]+|-all|-specials)?-(poster|banner|fanart|backdrop|landscape|thumb|logo|clearart|clearlogo|keyart)[0-9]*$'

# Junk filename patterns, used by DELETE_JUNK. Matched
# case-insensitively against the filename only.
JUNK_GLOBS=(
    '.DS_Store' '._*' 'Thumbs.db' 'ehthumbs.db' 'desktop.ini'
    '*.url' '*.sfv' '*.nzb' '*.torrent' '*.md5' 'RARBG*.txt'
)

# Extra language codes to recognise, beyond the built-in ISO 639-1
# and ISO 639-2 sets. Regional forms like "pt-br" and "zh-cn" are
# already accepted for any known code.
EXTRA_LANG_CODES=()

# When a subtitle's rename target already exists and
# DELETE_DUPLICATES is "true", decide which file survives:
#   "largest"  keep whichever file is bigger  (default)
#   "existing" keep the file already at the target
# Without this the winner was whichever file the shell happened to
# reach first, which has nothing to do with subtitle quality.
# A rename keeps the subtitle's extension, so a collision is always
# between two files of the same format.
DUPLICATE_KEEP="largest"

# SAFETY NET. When set to a path, every file the destructive
# passes would remove is MOVED there instead of being deleted, so
# a bad run is recoverable. The original directory structure is
# recreated under a timestamped folder, e.g.
#   <TRASH_DIR>/2026-09-10_02-14-33/mnt/user/Media-Large/Films/...
# Set to "" to delete outright. Honors DRY_RUN either way.
#
# Must NOT sit inside any of ROOT_DIRS: the junk and empty-folder
# passes would walk back into it and undo the safety net. The
# script refuses to run if it does.
TRASH_DIR="/mnt/user/appdata/library_cleaner/trash"

# When "true", find follows symbolic links, so a symlinked root
# or subfolder is walked instead of silently yielding nothing.
# Off by default: following links can reach the same file by
# several paths, and a symlink loop makes find error out. A root
# that is a symlink is reported when this is "false".
FOLLOW_SYMLINKS="false"

# Guards against two copies running at once, which matters if you
# schedule this and a run overruns its interval - two passes
# renaming the same folder will fight. Set to "" to disable.
LOCK_FILE="/var/lock/library-cleaner-tv.lock"

# How long to keep quarantined files. Run folders under TRASH_DIR
# older than this many days are removed at the end of a run, so the
# safety net doesn't grow without bound. Set to 0 to keep
# everything and empty it yourself. Ignored when TRASH_DIR is "".
# Only folders named like a run timestamp are ever considered, so
# anything else you put under TRASH_DIR is left alone.
TRASH_KEEP_DAYS="30"

# --------------------- END CONFIGURATION --------------------

SCRIPT_TITLE="Library Cleaner - TV"
UNIT_LABEL="Season folders"

#@include common.sh

# TV-only counters.
sub_skip_noep=0
tp_skip_noep=0
ep_ambig=0

# Collect every SxxExx token a name spans, into EP_TOKENS.
# A multi-episode file covers more than one episode, and naming it
# by only its first token left the others unclaimed - their
# subtitles looked orphaned and were deleted.
#
#   Show - S01E01 - Title      -> S01E01
#   Show - S01E01-E02 - Double -> S01E01 S01E02
#   Show - S01E01E02 - Double  -> S01E01 S01E02
#   Show - S01E01-03 - Triple  -> S01E01 S01E02 S01E03
extract_ep_tokens() {
    local name="$1" season first width tail matched n i tok
    EP_TOKENS=()
    [[ "$name" =~ [Ss]([0-9]{1,3})[Ee]([0-9]{1,4}) ]] || return
    season=$((10#${BASH_REMATCH[1]}))
    first=$((10#${BASH_REMATCH[2]}))
    width=${#BASH_REMATCH[2]}
    printf -v tok 'S%02dE%02d' "$season" "$first"
    EP_TOKENS+=("$tok")

    # Walk any continuation immediately after the first token. A
    # leading space ends the scan, so " - 1080p" is never read as
    # episode 1080.
    tail="${name#*"${BASH_REMATCH[0]}"}"
    while [[ "$tail" =~ ^(-?[Ee]|-)([0-9]{1,4}) ]]; do
        matched="${BASH_REMATCH[0]}"
        n=$((10#${BASH_REMATCH[2]}))
        # A bare "-NN" is only a range when it is written like one,
        # so "S01E01-720p" is not read as episodes 1 to 720.
        if [ "${BASH_REMATCH[1]}" = "-" ] \
           && [ "${#BASH_REMATCH[2]}" -ne "$width" ]; then
            break
        fi
        [ "$n" -gt "$first" ] || break
        [ $((n - first)) -le 50 ] || break
        for ((i = first + 1; i <= n; i++)); do
            printf -v tok 'S%02dE%02d' "$season" "$i"
            EP_TOKENS+=("$tok")
        done
        first="$n"
        tail="${tail#"$matched"}"
    done
}

# The first token only - what a subtitle or trickplay folder names.
extract_ep_token() {
    extract_ep_tokens "$1"
    [ "${#EP_TOKENS[@]}" -gt 0 ] && printf '%s' "${EP_TOKENS[0]}"
}

# ---------- Discover season folders -------------------------
# A season folder is any directory whose name matches the regex
# AND whose parent is a show folder (i.e. directly under a show).
# We use find with -mindepth/-maxdepth to keep this fast, and
# NUL-delimited output so odd folder names survive intact.
season_folders=()
while IFS= read -r -d '' d; do
    dname="${d##*/}"
    if [ -z "$SEASON_DIR_REGEX" ] || [[ "$dname" =~ $SEASON_DIR_REGEX ]]; then
        season_folders+=("$d")
    fi
done < <(find "${FIND_OPTS[@]}" "${ROOTS[@]}" -mindepth 2 -maxdepth 2 -type d -print0)

log " Season folders found: ${#season_folders[@]}"

for season in "${season_folders[@]}"; do
    # Map: SxxExx -> path of episode video. Also flag duplicates.
    declare -A EP_VIDEO=()
    declare -A EP_DUP=()
    declare -A vid_bases=()

    collect_video_bases "$season"

    shopt -s nullglob nocaseglob
    for ext in "${VIDEO_EXTS[@]}"; do
        for v in "$season"/*."$ext"; do
            [ -f "$v" ] || continue
            extract_ep_tokens "${v##*/}"
            [ "${#EP_TOKENS[@]}" -eq 0 ] && continue
            for tok in "${EP_TOKENS[@]}"; do
                if [ -n "${EP_VIDEO[$tok]:-}" ]; then
                    EP_DUP["$tok"]=1
                    log "[EP DUPLICATE] $tok in $season"
                else
                    EP_VIDEO["$tok"]="$v"
                fi
            done
        done
    done
    shopt -u nullglob nocaseglob

    # ---------- SUBTITLES in this season folder -------------
    collect_subs "$season"
    for sub in "${COLLECTED_SUBS[@]}"; do
        sub_basename="${sub##*/}"

        tok="$(extract_ep_token "$sub_basename")"
        if [ -z "$tok" ]; then
            if [ "$DELETE_ORPHANS" = "true" ]; then
                delete_file "$sub" "ORPHAN" "no SxxExx" orphan_delete
            else
                log "[SUB SKIP no SxxExx] $sub"
                sub_skip_noep=$((sub_skip_noep + 1))
            fi
            continue
        fi
        if [ -n "${EP_DUP[$tok]:-}" ]; then
            log "[SUB SKIP duplicate ep $tok] $sub"
            ep_ambig=$((ep_ambig + 1))
            continue
        fi
        ep_video="${EP_VIDEO[$tok]:-}"
        if [ -z "$ep_video" ]; then
            if [ "$DELETE_ORPHANS" = "true" ]; then
                delete_file "$sub" "ORPHAN" "no video for $tok" orphan_delete
            else
                log "[SUB SKIP no video for $tok] $sub"
                sub_skip_noep=$((sub_skip_noep + 1))
            fi
            continue
        fi

        ep_basename="${ep_video##*/}"
        peel_suffix "${sub_basename%.*}"
        finish_subtitle "$sub" "${ep_basename%.*}" "$season"
    done

    # ---------- TRICKPLAY folders in this season folder -----
    shopt -s nullglob
    trickplays=("$season"/*.trickplay)
    shopt -u nullglob

    for tp in "${trickplays[@]}"; do
        [ -d "$tp" ] || continue
        tp_basename="${tp##*/}"

        tok="$(extract_ep_token "$tp_basename")"
        if [ -z "$tok" ]; then
            log "[TP SKIP no SxxExx] $tp"
            tp_skip_noep=$((tp_skip_noep + 1))
            continue
        fi
        if [ -n "${EP_DUP[$tok]:-}" ]; then
            log "[TP SKIP duplicate ep $tok] $tp"
            ep_ambig=$((ep_ambig + 1))
            continue
        fi
        ep_video="${EP_VIDEO[$tok]:-}"
        if [ -z "$ep_video" ]; then
            log "[TP SKIP no video for $tok] $tp"
            tp_skip_noep=$((tp_skip_noep + 1))
            continue
        fi

        ep_basename="${ep_video##*/}"
        expected_tp="${ep_basename%.*}.trickplay"

        if [ "$tp_basename" = "$expected_tp" ]; then
            tp_skip_noop=$((tp_skip_noop + 1))
            continue
        fi
        if trickplay_is_paired "$tp" "$season"; then
            tp_skip_noop=$((tp_skip_noop + 1))
            continue
        fi

        rename_trickplay "$tp" "$season/$expected_tp"
    done

    # ------------------ OUTLIER .NFO / ARTWORK --------------
    # tvshow.nfo lives in the show root, not a season folder, so
    # it is never touched by this pass.
    [ "$DELETE_OUTLIER_NFO" = "true" ] && nfo_pass "$season" "season.nfo"
    [ "$DELETE_OUTLIER_ART" = "true" ] && art_pass "$season"

    unset EP_VIDEO EP_DUP vid_bases
done

[ "$DELETE_JUNK" = "true" ] && junk_pass
[ "$PRUNE_EMPTY_DIRS" = "true" ] && empty_prune_pass

# Last, so anything quarantined by this run is already in place.
trash_prune_pass

UNIT_COUNT="${#season_folders[@]}"
SUMMARY_EXTRA+=("Subtitles skipped (no episode):|$sub_skip_noep")
SUMMARY_EXTRA+=("Trickplay already correct:|$tp_skip_noop")
SUMMARY_EXTRA+=("Trickplay skipped (exists):|$tp_skip_exists")
SUMMARY_EXTRA+=("Trickplay skipped (no episode):|$tp_skip_noep")
SUMMARY_EXTRA+=("Skipped (ambiguous duplicate):|$ep_ambig")
print_summary
