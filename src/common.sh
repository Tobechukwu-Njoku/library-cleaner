
set -uo pipefail

# ---------- Logging -----------------------------------------
# One append-mode file descriptor opened once, rather than a
# `tee` fork per line. Falls back to console-only if the log
# path can't be written.
if [ "$ENABLE_LOG" = "true" ]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    if : >>"$LOG_FILE" 2>/dev/null; then
        exec {LOG_FD}>>"$LOG_FILE"
        log() {
            printf '%s\n' "$*"
            printf '%s\n' "$*" >&$LOG_FD
        }
    else
        echo "WARNING: cannot write $LOG_FILE - logging to console only" >&2
        log() { printf '%s\n' "$*"; }
    fi
else
    log() { :; }
fi

log "=========================================================="
log " $SCRIPT_TITLE: $(date '+%Y-%m-%d %H:%M:%S')"
log " Dry-run: $DRY_RUN"

# ---------- Validate roots ----------------------------------
ROOTS=()
if [ "${#ROOT_DIRS[@]}" -gt 0 ]; then
    for r in "${ROOT_DIRS[@]}"; do
        if [ -d "$r" ]; then
            ROOTS+=("$r")
            log " Root:    $r"
        else
            log " WARNING: root does not exist, skipping: $r"
        fi
    done
fi
log "=========================================================="

if [ "${#ROOTS[@]}" -eq 0 ]; then
    log "ERROR: none of the configured ROOT_DIRS exist. Nothing to do."
    exit 1
fi

# ---------- Regexes built from configuration ----------------
FLAG_RE=""
for f in "${KNOWN_FLAGS[@]}"; do FLAG_RE+="|$f"; done
FLAG_RE="${FLAG_RE:1}"

GENERIC_ART_RE=""
for n in "${GENERIC_ART_NAMES[@]}"; do GENERIC_ART_RE+="|$n"; done
GENERIC_ART_RE="^(${GENERIC_ART_RE:1})[0-9]*$"

ART_SUFFIX_RE=""
for n in "${ART_SUFFIXES[@]}"; do ART_SUFFIX_RE+="|$n"; done
ART_SUFFIX_RE="^(${ART_SUFFIX_RE:1})[0-9]*$"

# ---------- Counters ----------------------------------------
sub_rename=0
sub_skip_noop=0
sub_skip_exists=0
tp_rename=0
tp_skip_noop=0
tp_skip_exists=0
orphan_delete=0
outlier_delete=0
nfo_outlier_delete=0
duplicate_delete=0
art_outlier_delete=0
junk_delete=0
empty_prune=0
error_count=0

# Extra summary lines contributed by the calling script, each
# "label|value".
SUMMARY_EXTRA=()

# ---------- Helpers -----------------------------------------

# Returns 0 if $1 looks like a language code or known flag.
# Accepts 2-3 letter codes, optional -xx(xx) locale suffix
# (e.g. pt-br, zh-cn), and any flag from KNOWN_FLAGS.
is_suffix_component() {
    local c="${1,,}"
    [[ "$c" =~ ^[a-z]{2,3}(-[a-z0-9]{2,4})?$ ]] && return 0
    [[ "$c" =~ ^($FLAG_RE)$ ]] && return 0
    return 1
}

# Peel trailing language / flag components off a subtitle name.
# Sets SUFFIX_COMPONENTS (in original order) and SUFFIX_REMAINDER.
peel_suffix() {
    local remainder="$1" last i
    SUFFIX_COMPONENTS=()
    for ((i = 0; i < MAX_SUFFIX_PARTS; i++)); do
        [[ "$remainder" == *.* ]] || break
        last="${remainder##*.}"
        if is_suffix_component "$last"; then
            SUFFIX_COMPONENTS=("${last,,}" "${SUFFIX_COMPONENTS[@]}")
            remainder="${remainder%.*}"
        else
            break
        fi
    done
    SUFFIX_REMAINDER="$remainder"
}

# Inspect the peeled result for the malformed patterns we know
# about. Sets OUTLIER_REASON, empty when the name looks sane.
#   1. A numeric component just before the lang/flag suffix,
#      e.g. "...Radarr.3.hi.srt" - junk from audio-track parsing.
#   2. A duplicated component, e.g. "...hi.hi.srt".
detect_outlier() {
    local trailing c
    OUTLIER_REASON=""
    if [[ "$SUFFIX_REMAINDER" == *.* ]]; then
        trailing="${SUFFIX_REMAINDER##*.}"
        if [[ "$trailing" =~ ^[0-9]+$ ]]; then
            OUTLIER_REASON="trailing numeric '.$trailing'"
            return
        fi
    fi
    if [ "${#SUFFIX_COMPONENTS[@]}" -ge 2 ]; then
        local -A seen=()
        for c in "${SUFFIX_COMPONENTS[@]}"; do
            if [ -n "${seen[$c]:-}" ]; then
                OUTLIER_REASON="duplicate suffix '.$c'"
                return
            fi
            seen["$c"]=1
        done
    fi
}

# Join the peeled components back into a ".xx.yy" suffix,
# applying STRIP_HI. Result in SUFFIX_STRING.
build_suffix() {
    local c
    if [ "$STRIP_HI" = "true" ] \
       && [ "${#SUFFIX_COMPONENTS[@]}" -gt 1 ] \
       && [ "${SUFFIX_COMPONENTS[-1]}" = "hi" ]; then
        unset 'SUFFIX_COMPONENTS[-1]'
    fi
    SUFFIX_STRING=""
    for c in "${SUFFIX_COMPONENTS[@]}"; do SUFFIX_STRING+=".$c"; done
}

# Delete a file, honouring DRY_RUN. $2 is the log tag, $3 an
# optional reason appended to it. Bumps the counter named in $4.
delete_file() {
    local path="$1" tag="$2" reason="$3" counter="$4" suffix=""
    [ -n "$reason" ] && suffix=" - $reason"
    if [ "$DRY_RUN" = "true" ]; then
        log "[$tag DRY-RUN delete$suffix] $path"
        printf -v "$counter" '%d' $(( ${!counter} + 1 ))
    else
        if rm -- "$path"; then
            log "[$tag DELETED$suffix] $path"
            printf -v "$counter" '%d' $(( ${!counter} + 1 ))
        else
            log "[$tag ERROR$suffix] $path"
            error_count=$((error_count + 1))
        fi
    fi
}

# Rename a subtitle onto $target_base, handling the no-op and
# already-exists cases. Expects peel_suffix to have run.
finish_subtitle() {
    local sub="$1" target_base="$2" folder="$3"
    local sub_basename sub_ext new_name new_path

    sub_basename="$(basename "$sub")"
    sub_ext="${sub_basename##*.}"

    detect_outlier
    if [ -n "$OUTLIER_REASON" ]; then
        if [ "$DELETE_OUTLIERS" = "true" ]; then
            delete_file "$sub" "OUTLIER" "$OUTLIER_REASON" outlier_delete
            return
        else
            log "[SUB OUTLIER ($OUTLIER_REASON)] $sub"
        fi
    fi

    build_suffix
    new_name="${target_base}${SUFFIX_STRING}.${sub_ext,,}"
    new_path="$folder/$new_name"

    if [ "$sub_basename" = "$new_name" ]; then
        sub_skip_noop=$((sub_skip_noop + 1))
        return
    fi

    if [ -e "$new_path" ]; then
        if [ "$DELETE_DUPLICATES" = "true" ]; then
            if [ "$DRY_RUN" = "true" ]; then
                log "[SUB DUP DRY-RUN delete] $sub"
                log "                target:  $new_path"
                duplicate_delete=$((duplicate_delete + 1))
            else
                if rm -- "$sub"; then
                    log "[SUB DUP DELETED] $sub"
                    duplicate_delete=$((duplicate_delete + 1))
                else
                    log "[SUB DUP ERROR] Failed to delete: $sub"
                    error_count=$((error_count + 1))
                fi
            fi
        else
            log "[SUB SKIP exists] $sub"
            log "             -->  $new_path"
            sub_skip_exists=$((sub_skip_exists + 1))
        fi
        return
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "[SUB DRY-RUN] $sub"
        log "         -->  $new_path"
        sub_rename=$((sub_rename + 1))
    else
        if mv -n -- "$sub" "$new_path"; then
            log "[SUB RENAMED] $sub_basename"
            log "         -->  $new_name"
            sub_rename=$((sub_rename + 1))
        else
            log "[SUB ERROR] Failed to rename: $sub"
            error_count=$((error_count + 1))
        fi
    fi
}

# Collect every subtitle sitting directly in $1.
collect_subs() {
    local folder="$1" ext s
    COLLECTED_SUBS=()
    shopt -s nullglob nocaseglob
    for ext in "${SUB_EXTS[@]}"; do
        for s in "$folder"/*."$ext"; do COLLECTED_SUBS+=("$s"); done
    done
    shopt -u nullglob nocaseglob
}

# Lowercase basenames of every video directly in $1, into the
# caller's `vid_bases` associative array.
collect_video_bases() {
    local folder="$1" ext v vb
    shopt -s nullglob nocaseglob
    for ext in "${VIDEO_EXTS[@]}"; do
        for v in "$folder"/*."$ext"; do
            [ -f "$v" ] || continue
            vb="$(basename "$v")"
            vb="${vb%.*}"
            vid_bases["${vb,,}"]=1
        done
    done
    shopt -u nullglob nocaseglob
}

# Returns 0 when the trickplay folder $1 still matches a video
# that actually exists in $2 (an extra with its own trickplay).
trickplay_is_paired() {
    local tp="$1" folder="$2" linked_base vext
    linked_base="$(basename "$tp")"
    linked_base="${linked_base%.trickplay}"
    for vext in "${VIDEO_EXTS[@]}"; do
        [ -e "$folder/${linked_base}.$vext" ] && return 0
    done
    return 1
}

# Rename trickplay folder $1 to $2, handling the exists case.
rename_trickplay() {
    local tp="$1" target_path="$2"
    local tp_basename expected_tp
    tp_basename="$(basename "$tp")"
    expected_tp="$(basename "$target_path")"

    if [ -e "$target_path" ]; then
        log "[TP SKIP exists] $tp"
        log "            -->  $target_path"
        tp_skip_exists=$((tp_skip_exists + 1))
        return
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "[TP DRY-RUN] $tp"
        log "        -->  $target_path"
        tp_rename=$((tp_rename + 1))
    else
        if mv -n -- "$tp" "$target_path"; then
            log "[TP RENAMED] $tp_basename"
            log "        -->  $expected_tp"
            tp_rename=$((tp_rename + 1))
        else
            log "[TP ERROR] Failed to rename: $tp"
            error_count=$((error_count + 1))
        fi
    fi
}

# Returns 0 if the lowercase image basename $1 belongs to this
# folder's media. Reads the caller's `vid_bases` map, and the
# optional SEASON_ART_RE when the calling script defines one.
art_is_valid() {
    local base="$1" candidate suffix
    [[ "$base" =~ $GENERIC_ART_RE ]] && return 0
    if [ -n "${SEASON_ART_RE:-}" ] && [[ "$base" =~ $SEASON_ART_RE ]]; then
        return 0
    fi
    [ -n "${vid_bases[$base]:-}" ] && return 0
    candidate="$base"
    while [[ "$candidate" == *-* ]]; do
        suffix="${candidate##*-}"
        candidate="${candidate%-*}"
        if [ -n "${vid_bases[$candidate]:-}" ] \
           && [[ "$suffix" =~ $ART_SUFFIX_RE ]]; then
            return 0
        fi
    done
    return 1
}

# Delete .nfo files in $1 that match no video there. $2 is the
# alternate convention to keep ("movie.nfo" / "season.nfo").
nfo_pass() {
    local folder="$1" alt="$2" nfo nfo_name vb
    local -A valid_nfo=( ["$alt"]=1 )
    for vb in "${!vid_bases[@]}"; do
        valid_nfo["${vb}.nfo"]=1
    done

    shopt -s nullglob nocaseglob
    for nfo in "$folder"/*.nfo; do
        [ -f "$nfo" ] || continue
        nfo_name="$(basename "$nfo")"
        [ -n "${valid_nfo[${nfo_name,,}]:-}" ] && continue
        delete_file "$nfo" "NFO OUTLIER" "" nfo_outlier_delete
    done
    shopt -u nullglob nocaseglob
}

# Delete images in $1 that match no video there.
art_pass() {
    local folder="$1" ext img img_name img_base
    shopt -s nullglob nocaseglob
    for ext in "${ART_EXTS[@]}"; do
        for img in "$folder"/*."$ext"; do
            [ -f "$img" ] || continue
            img_name="$(basename "$img")"
            img_base="${img_name%.*}"
            art_is_valid "${img_base,,}" && continue
            delete_file "$img" "ART OUTLIER" "" art_outlier_delete
        done
    done
    shopt -u nullglob nocaseglob
}

# Build a case-insensitive find expression from a list of
# -iname patterns, into FIND_EXPR.
build_find_expr() {
    local first=1 pat
    FIND_EXPR=(-type f \()
    for pat in "$@"; do
        if [ $first -eq 1 ]; then
            FIND_EXPR+=(-iname "$pat"); first=0
        else
            FIND_EXPR+=(-o -iname "$pat")
        fi
    done
    FIND_EXPR+=(\) -print0)
}

# Sweep junk files across every root. Its own pass, so it also
# reaches folders that contain no video.
junk_pass() {
    local j
    log " ---- Junk file deletion pass ----"
    build_find_expr "${JUNK_GLOBS[@]}"
    while IFS= read -r -d '' j; do
        delete_file "$j" "JUNK" "" junk_delete
    done < <(find "${ROOTS[@]}" "${FIND_EXPR[@]}")
}

# Remove empty folders, repeating until nothing more can go so
# nested empties collapse. Roots themselves are never removed.
empty_prune_pass() {
    local d pass_removed
    log " ---- Empty folder prune pass ----"
    if [ "$DRY_RUN" = "true" ]; then
        while IFS= read -r -d '' d; do
            log "[EMPTY DRY-RUN rmdir] $d"
            empty_prune=$((empty_prune + 1))
        done < <(find "${ROOTS[@]}" -mindepth 1 -type d -empty -print0)
        log " NOTE: dry-run lists only folders that are empty RIGHT NOW."
        log "       Parents that become empty once their children are"
        log "       removed are not listed here, but will be removed on"
        log "       a real run."
    else
        while :; do
            pass_removed=0
            while IFS= read -r -d '' d; do
                if rmdir -- "$d" 2>/dev/null; then
                    log "[EMPTY REMOVED] $d"
                    empty_prune=$((empty_prune + 1))
                    pass_removed=$((pass_removed + 1))
                fi
            done < <(find "${ROOTS[@]}" -mindepth 1 -type d -empty -print0)
            [ "$pass_removed" -eq 0 ] && break
        done
    fi
}

# Log one "label value" summary line, phrased for dry-run or not.
summary_line() {
    local label="$1" value="$2"
    printf -v label '%-31s' "$label"
    log " ${label}$value"
}

print_summary() {
    local entry label value
    log "=========================================================="
    log " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    summary_line "$UNIT_LABEL processed:" "$UNIT_COUNT"
    if [ "$DRY_RUN" = "true" ]; then
        summary_line "Subtitles would rename:" "$sub_rename"
        summary_line "Trickplay would rename:" "$tp_rename"
    else
        summary_line "Subtitles renamed:" "$sub_rename"
        summary_line "Trickplay folders renamed:" "$tp_rename"
    fi
    summary_line "Subtitles already correct:" "$sub_skip_noop"
    summary_line "Subtitles skipped (exists):" "$sub_skip_exists"

    for entry in "${SUMMARY_EXTRA[@]}"; do
        label="${entry%%|*}"
        value="${entry##*|}"
        summary_line "$label" "$value"
    done

    if [ "$DELETE_ORPHANS" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Orphan subs would delete:" "$orphan_delete"
        else
            summary_line "Orphan subs deleted:" "$orphan_delete"
        fi
    fi
    if [ "$DELETE_OUTLIERS" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Outlier subs would delete:" "$outlier_delete"
        else
            summary_line "Outlier subs deleted:" "$outlier_delete"
        fi
    fi
    if [ "$DELETE_OUTLIER_NFO" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Outlier .nfo would delete:" "$nfo_outlier_delete"
        else
            summary_line "Outlier .nfo deleted:" "$nfo_outlier_delete"
        fi
    fi
    if [ "$DELETE_DUPLICATES" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Duplicate subs would delete:" "$duplicate_delete"
        else
            summary_line "Duplicate subs deleted:" "$duplicate_delete"
        fi
    fi
    if [ "$DELETE_OUTLIER_ART" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Outlier artwork would delete:" "$art_outlier_delete"
        else
            summary_line "Outlier artwork deleted:" "$art_outlier_delete"
        fi
    fi
    if [ "$DELETE_JUNK" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Junk files would delete:" "$junk_delete"
        else
            summary_line "Junk files deleted:" "$junk_delete"
        fi
    fi
    if [ "$PRUNE_EMPTY_DIRS" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            summary_line "Empty folders would remove:" "$empty_prune"
        else
            summary_line "Empty folders removed:" "$empty_prune"
        fi
    fi
    summary_line "Errors:" "$error_count"
    log "=========================================================="
}
