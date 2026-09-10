#!/bin/bash
# ============================================================
#  Library Cleaner - Film  (Unraid UserScripts)
# ============================================================
#  Walks one or more film libraries. For each movie folder it
#  determines the "main" video (largest video file in that
#  folder) and then:
#
#    1. Renames sibling subtitles  (srt/sub/ass/ssa/vtt/idx/sup)
#       to match the video's base name, PRESERVING the subtitle's
#       language code and any trailing flags like .hi .sdh .cc
#       .forced .default .foreign.
#
#    2. Renames sibling ".trickplay" folders so they are named
#       "<video_basename_without_extension>.trickplay".
#
#    3. Optionally clears out leftovers: orphaned subtitles,
#       malformed subtitles, duplicate subtitles, stale .nfo
#       files, stale artwork, junk files and empty folders.
#       Every deletion is opt-in and honours DRY_RUN.
#
#  Subtitle example:
#    Video: Film (2020)-Radarr.mkv
#    Sub:   Film (2020) [Bluray]{imdb-tt123}{tmdb-456}-Radarr.ar.hi.srt
#    -->    Film (2020)-Radarr.ar.hi.srt
#
#  Trickplay example:
#    Video:     Film (2020)-Radarr.mkv
#    Trickplay: Film (2020) [old name].trickplay
#    -->        Film (2020)-Radarr.trickplay
# ============================================================

# --------------------- CONFIGURATION ------------------------

# One or more library roots to scan. Each is walked
# independently; a path that does not exist is reported and
# skipped. Add as many lines as you like.
ROOT_DIRS=(
    "/mnt/user/Media-Large/Films/[1080p, OF]"
    "/mnt/user/Media-Large/Films/[1080p, MN]"
    "/mnt/user/Media-Large/Films/[2160p, MN]"
    "/mnt/user/Media-Large/Films/[2160p, OF]"
    "/mnt/user/Media-Huge/Films/[1080p, BD]"
    "/mnt/user/Media-Huge/Films/[1080p, RX]"
    "/mnt/user/Media-Huge/Films/[2160p, BD]"
    "/mnt/user/Media-Huge/Films/[2160p, RX]"
)

# IMPORTANT: Leave DRY_RUN="true" for the first run. Inspect the
# log, then flip to "false" to perform the actual renames.
DRY_RUN="true"

# Set to "false" to disable ALL logging (file + console output).
# The script will still run and perform renames silently.
ENABLE_LOG="true"

# Log file - pick any writable path. Appended to each run.
# Ignored when ENABLE_LOG="false".
LOG_FILE="/mnt/user/appdata/subtitle_renamer/rename.log"

# File extensions we treat as video (main movie) files.
VIDEO_EXTS=(mkv mp4 avi m4v mov mpg mpeg wmv flv webm ts m2ts)

# File extensions we treat as subtitle files.
SUB_EXTS=(srt sub ass ssa vtt idx sup)

# File extensions we treat as artwork images.
ART_EXTS=(jpg jpeg png webp tbn bmp)

# Subtitle "flag" suffixes that come after a language code.
KNOWN_FLAGS=(hi sdh cc forced default foreign cc1 cc2)

# Maximum number of trailing dot-components we'll peel off a
# subtitle filename to build the language/flag suffix.
MAX_SUFFIX_PARTS=3

# When "true", strip a trailing ".hi" (hearing-impaired flag) from
# subtitle names — but ONLY when another language/flag component
# precedes it. A lone ".hi" is preserved because it may be the
# Hindi language code.
#   ...en.hi.srt  -> ...en.srt     (stripped)
#   ...ar.hi.srt  -> ...ar.srt     (stripped)
#   ...hi.srt     -> ...hi.srt     (kept - possibly Hindi)
STRIP_HI="false"

# SAFETY. When "true", a subtitle whose name (minus its language
# /flag suffix) matches a DIFFERENT video in the same folder is
# left alone instead of being renamed onto the main feature.
# This protects flat-stored extras:
#   Film (2020)-Radarr.mkv            <- main feature
#   Film (2020)-behindthescenes.mkv   <- extra
#   Film (2020)-behindthescenes.en.srt  stays put
# Set to "false" to restore the old behaviour of pairing every
# subtitle in the folder with the largest video.
RESPECT_EXTRA_SUBS="true"

# DESTRUCTIVE. When "true", subtitle files whose containing folder
# has no video file at all are DELETED. Honors DRY_RUN — nothing is
# removed in dry-run mode. Leave "false" unless you've reviewed at
# least one dry-run log and trust the result.
DELETE_ORPHANS="false"

# DESTRUCTIVE. When "true", subtitle files whose name is malformed
# in one of the patterns below are DELETED instead of being
# renamed. Honors DRY_RUN. Detects:
#   1. A numeric component just before the lang/flag suffix:
#        ...Radarr.3.hi.srt   ...Radarr.7.hi.srt
#      (typically junk left over from audio-track-ID parsing)
#   2. Duplicate components in the peeled suffix:
#        ...Radarr.hi.hi.srt   ...Radarr.en.en.srt
DELETE_OUTLIERS="false"

# DESTRUCTIVE. When "true", any .nfo file in a movie folder whose
# basename does NOT match any video's basename in the same folder
# (and isn't the alternate "movie.nfo" convention) is DELETED.
# Honors DRY_RUN. Useful for clearing out stale .nfo files left
# behind from prior video renames.
DELETE_OUTLIER_NFO="false"

# DESTRUCTIVE. When "true", a subtitle whose rename target ALREADY
# EXISTS (currently logged as [SUB SKIP exists]) is DELETED instead
# of being left in place. The pre-existing file at the target path
# is kept untouched. Honors DRY_RUN.
#   Example: two subs both want to become ...Radarr.hi.srt - the
#   first wins the rename, the second (which would have been
#   skipped) is deleted as a duplicate.
DELETE_DUPLICATES="false"

# DESTRUCTIVE. When "true", image files in a movie folder that
# don't correspond to any video there are DELETED. Honors DRY_RUN.
# An image is KEPT when it is:
#   - a generic artwork name       (poster.jpg, fanart2.jpg, ...)
#   - "<video basename>.<ext>"     (Kodi thumb convention)
#   - "<video basename>-<arttype>" (Film-Radarr-poster.jpg, ...)
# Anything else is treated as a leftover from a prior rename.
DELETE_OUTLIER_ART="false"

# DESTRUCTIVE. When "true", files matching JUNK_GLOBS anywhere
# under the roots are DELETED. Honors DRY_RUN. This runs as its
# own sweep, so it also reaches folders that contain no video.
DELETE_JUNK="false"

# DESTRUCTIVE. When "true", empty folders under the roots are
# removed after all other passes (so folders emptied by this run
# are caught too). Nested empties collapse: the pass repeats
# until nothing more can be removed. The roots themselves are
# never removed. Honors DRY_RUN.
PRUNE_EMPTY_DIRS="false"

# Generic artwork basenames, used by DELETE_OUTLIER_ART. A
# trailing number is allowed automatically (fanart2, backdrop3).
GENERIC_ART_NAMES=(
    poster folder cover fanart backdrop background banner thumb
    landscape logo clearart clearlogo disc discart cdart keyart
    characterart art extrafanart
)

# Artwork type suffixes that may follow a video basename, used by
# DELETE_OUTLIER_ART. A trailing number is allowed automatically.
ART_SUFFIXES=(
    poster fanart backdrop banner thumb landscape logo clearart
    clearlogo disc discart cdart keyart
)

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

# --------------------- END CONFIGURATION --------------------

SCRIPT_TITLE="Library Cleaner - Film"
UNIT_LABEL="Folders"

#@include common.sh

# Film-only counters.
sub_skip_extra=0
tp_skip_ambig=0

# ---------- PASS 1: collect main video per folder -----------
# For each folder that contains any video file, remember the
# largest one (this is almost always the feature film, not a
# trailer/featurette).
declare -A MAIN_VIDEO
declare -A MAIN_SIZE
declare -A VIDEO_COUNT

video_globs=()
for ext in "${VIDEO_EXTS[@]}"; do video_globs+=("*.$ext"); done
build_find_expr "${video_globs[@]}"

while IFS= read -r -d '' video; do
    folder="$(dirname "$video")"
    VIDEO_COUNT["$folder"]=$(( ${VIDEO_COUNT["$folder"]:-0} + 1 ))
    size="$(file_size "$video")"
    current="${MAIN_SIZE[$folder]:-0}"
    if [ "$size" -gt "$current" ]; then
        MAIN_SIZE["$folder"]="$size"
        MAIN_VIDEO["$folder"]="$video"
    fi
done < <(find "${ROOTS[@]}" "${FIND_EXPR[@]}")

# ---------- PASS 2: process each folder exactly once --------
folder_count=0

for folder in "${!MAIN_VIDEO[@]}"; do
    folder_count=$((folder_count + 1))
    main_video="${MAIN_VIDEO[$folder]}"
    main_basename="$(basename "$main_video")"    # e.g. movie.mkv
    main_name="${main_basename%.*}"              # e.g. movie
    vcount="${VIDEO_COUNT[$folder]}"

    declare -A vid_bases=()
    collect_video_bases "$folder"

    # ------------------ SUBTITLES ---------------------------
    collect_subs "$folder"
    for sub in "${COLLECTED_SUBS[@]}"; do
        sub_basename="$(basename "$sub")"
        peel_suffix "${sub_basename%.*}"

        # Extra / featurette guard. This subtitle already names a
        # DIFFERENT video in the same folder, so it belongs to
        # that one - renaming it would clobber the feature's subs.
        if [ "$RESPECT_EXTRA_SUBS" = "true" ] \
           && [ "${SUFFIX_REMAINDER,,}" != "${main_name,,}" ] \
           && [ -n "${vid_bases[${SUFFIX_REMAINDER,,}]:-}" ]; then
            log "[SUB SKIP belongs to extra] $sub"
            sub_skip_extra=$((sub_skip_extra + 1))
            continue
        fi

        finish_subtitle "$sub" "$main_name" "$folder"
    done

    # ------------------ TRICKPLAY FOLDERS -------------------
    shopt -s nullglob
    trickplays=("$folder"/*.trickplay)
    shopt -u nullglob

    for tp in "${trickplays[@]}"; do
        [ -d "$tp" ] || continue
        tp_basename="$(basename "$tp")"
        expected_tp="${main_name}.trickplay"

        if [ "$tp_basename" = "$expected_tp" ]; then
            tp_skip_noop=$((tp_skip_noop + 1))
            continue
        fi

        # Still paired with some OTHER video here, e.g.
        # "Featurette.trickplay" beside "Featurette.mkv".
        if trickplay_is_paired "$tp" "$folder"; then
            tp_skip_noop=$((tp_skip_noop + 1))
            continue
        fi

        # Ambiguous: several videos here and this orphan
        # trickplay could belong to any of them.
        if [ "$vcount" -gt 1 ]; then
            log "[TP SKIP ambiguous - folder has $vcount videos] $tp"
            tp_skip_ambig=$((tp_skip_ambig + 1))
            continue
        fi

        rename_trickplay "$tp" "$folder/$expected_tp"
    done

    # ------------------ OUTLIER .NFO / ARTWORK --------------
    [ "$DELETE_OUTLIER_NFO" = "true" ] && nfo_pass "$folder" "movie.nfo"
    [ "$DELETE_OUTLIER_ART" = "true" ] && art_pass "$folder"

    unset vid_bases
done

# ---------- PASS 3: delete orphaned subtitles ---------------
# A subtitle is orphaned when its folder holds no video at all,
# i.e. the folder never made it into MAIN_VIDEO.
if [ "$DELETE_ORPHANS" = "true" ]; then
    log " ---- Orphan subtitle deletion pass ----"
    sub_globs=()
    for ext in "${SUB_EXTS[@]}"; do sub_globs+=("*.$ext"); done
    build_find_expr "${sub_globs[@]}"

    while IFS= read -r -d '' sub; do
        folder="$(dirname "$sub")"
        [ -n "${MAIN_VIDEO[$folder]:-}" ] && continue
        delete_file "$sub" "ORPHAN" "" orphan_delete
    done < <(find "${ROOTS[@]}" "${FIND_EXPR[@]}")
fi

[ "$DELETE_JUNK" = "true" ] && junk_pass
[ "$PRUNE_EMPTY_DIRS" = "true" ] && empty_prune_pass

UNIT_COUNT="$folder_count"
if [ "$RESPECT_EXTRA_SUBS" = "true" ]; then
    SUMMARY_EXTRA+=("Subtitles skipped (extra):|$sub_skip_extra")
fi
SUMMARY_EXTRA+=("Trickplay already correct:|$tp_skip_noop")
SUMMARY_EXTRA+=("Trickplay skipped (exists):|$tp_skip_exists")
SUMMARY_EXTRA+=("Trickplay skipped (ambiguous):|$tp_skip_ambig")
print_summary
