
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

# ---------- Single instance ---------------------------------
if [ -n "${LOCK_FILE:-}" ]; then
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
        if exec {LOCK_FD}>"$LOCK_FILE" 2>/dev/null; then
            if ! flock -n "$LOCK_FD"; then
                log "ERROR: another run is already in progress."
                log "       Lock held on: $LOCK_FILE"
                exit 1
            fi
        else
            log " WARNING: cannot open $LOCK_FILE - running unlocked"
        fi
    else
        log " WARNING: flock not available - running unlocked"
    fi
fi

# ---------- Validate roots ----------------------------------
# find only follows symlinks when given -L, so without it a
# symlinked root passes the -d test and then yields nothing.
FIND_OPTS=()
[ "${FOLLOW_SYMLINKS:-false}" = "true" ] && FIND_OPTS=(-L)

ROOTS=()
if [ "${#ROOT_DIRS[@]}" -gt 0 ]; then
    for r in "${ROOT_DIRS[@]}"; do
        if [ -d "$r" ]; then
            ROOTS+=("$r")
            log " Root:    $r"
            if [ -L "$r" ] && [ "${FOLLOW_SYMLINKS:-false}" != "true" ]; then
                log " WARNING: that root is a symlink and FOLLOW_SYMLINKS"
                log "          is \"false\", so it will yield nothing."
                log "          Set FOLLOW_SYMLINKS=\"true\" or point"
                log "          ROOT_DIRS at the real path."
            fi
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

# ---------- Quarantine --------------------------------------
# Resolved lazily on first use so a clean run leaves no folders.
TRASH_RUN_DIR=""

if [ -n "$TRASH_DIR" ]; then
    for r in "${ROOTS[@]}"; do
        case "$TRASH_DIR/" in
            "$r"/*)
                log "ERROR: TRASH_DIR is inside a library root:"
                log "         TRASH_DIR: $TRASH_DIR"
                log "         root:      $r"
                log "       The junk and empty-folder passes would walk"
                log "       back into it. Move it outside your libraries."
                exit 1
                ;;
        esac
    done
    log " Trash:   $TRASH_DIR"
else
    log " Trash:   (disabled - files are deleted outright)"
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

# ISO 639-1 (all two-letter codes) and the common ISO 639-2/B and
# 639-2/T three-letter codes, plus the special-purpose codes.
# This is a whitelist on purpose: matching any 2-3 letter token
# treated release tags as languages, turning
# "Film.2020.1080p.WEB.DDP.srt" into "Film-Radarr.web.ddp.srt".
LANG_CODES=(
    aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br
    bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es et eu
    fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy
    hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn
    ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml
    mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os
    pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn
    so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw
    ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu
    afr alb amh ara arm aze baq bel ben bod bos bul bur cat ces
    chi cym cze dan deu dut dzo ell eng epo est eus fao fas fij
    fin fra fre geo ger gla gle glg gre grn guj hat hau heb hin
    hrv hun hye ice ina ind isl ita jav jpn kal kan kat kaz khm
    kir kor kur lao lat lav lit ltz mac mal mao mar may mkd mlt
    mon mri msa mya nld nno nob nor nya ori pan per pol por pus
    ron rum run rus sin slk slo slv sme smo sna som spa sqi srp
    swa swe tam tel tgk tha tib tir tuk tur ukr urd uzb vie wel
    wol xho yid yor zho zul
    und mul zxx mis
)

LANG_RE=""
for lc in "${LANG_CODES[@]}" ${EXTRA_LANG_CODES+"${EXTRA_LANG_CODES[@]}"}; do
    LANG_RE+="|${lc,,}"
done
LANG_RE="${LANG_RE:1}"

# Returns 0 if $1 is a known language code or a known flag.
# A language may carry a regional suffix (pt-br, zh-cn).
is_suffix_component() {
    local c="${1,,}"
    [[ "$c" =~ ^($LANG_RE)(-[a-z0-9]{2,4})?$ ]] && return 0
    [[ "$c" =~ ^($FLAG_RE)$ ]] && return 0
    return 1
}

# Portable "file size in bytes". Unraid is Linux (GNU stat).
file_size() {
    stat -c%s -- "$1" 2>/dev/null || stat -f%z -- "$1" 2>/dev/null || echo 0
}

# Decide which of two colliding subtitles to keep. Echoes
# "candidate" (the file being renamed) or "existing".
choose_duplicate() {
    local candidate="$1" existing="$2"
    case "$DUPLICATE_KEEP" in
        existing)
            printf 'existing'
            ;;
        *)
            local sc se
            sc="$(file_size "$candidate")"
            se="$(file_size "$existing")"
            if [ "$sc" -gt "$se" ]; then
                printf 'candidate'
            else
                printf 'existing'
            fi
            ;;
    esac
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

# Move $1 into TRASH_DIR, preserving its original path, or delete
# it outright when no TRASH_DIR is configured. Non-zero on failure.
dispose_file() {
    local path="$1" dest
    if [ -z "$TRASH_DIR" ]; then
        rm -- "$path"
        return
    fi
    if [ -z "$TRASH_RUN_DIR" ]; then
        TRASH_RUN_DIR="$TRASH_DIR/$(date '+%Y-%m-%d_%H-%M-%S')"
    fi
    dest="$TRASH_RUN_DIR/${path#/}"
    mkdir -p -- "$(dirname "$dest")" 2>/dev/null || return 1
    mv -- "$path" "$dest"
}

# Present and past tense for whichever disposal mode is active.
if [ -n "$TRASH_DIR" ]; then
    DISPOSE_VERB="trash"
    DISPOSE_PAST="TRASHED"
else
    DISPOSE_VERB="delete"
    DISPOSE_PAST="DELETED"
fi

# Dispose of a file, honouring DRY_RUN. $2 is the log tag, $3 an
# optional reason appended to it. Bumps the counter named in $4.
delete_file() {
    local path="$1" tag="$2" reason="$3" counter="$4" suffix=""
    [ -n "$reason" ] && suffix=" - $reason"
    if [ "$DRY_RUN" = "true" ]; then
        log "[$tag DRY-RUN $DISPOSE_VERB$suffix] $path"
        printf -v "$counter" '%d' $(( ${!counter} + 1 ))
    else
        if dispose_file "$path"; then
            log "[$tag $DISPOSE_PAST$suffix] $path"
            printf -v "$counter" '%d' $(( ${!counter} + 1 ))
        else
            log "[$tag ERROR$suffix] $path"
            error_count=$((error_count + 1))
        fi
    fi
}

# A VobSub subtitle is two files: a small .idx index and a large
# .sub payload. They must share a base name AND come from the same
# release - an index from one release with the payload of another
# is a track that looks valid and renders garbage. Everything below
# moves, renames and deletes the two together.
declare -A PAIR_HANDLED=()

pair_companion_ext() {
    case "${1,,}" in
        idx) COMPANION_EXT="sub" ;;
        sub) COMPANION_EXT="idx" ;;
        *)   COMPANION_EXT="" ;;
    esac
}

# Look for $1's companion with extension $2 among the subtitles
# already collected for this folder. Sets COMPANION.
find_companion() {
    local sub="$1" want="$2" base cand cand_ext
    base="${sub%.*}"
    COMPANION=""
    for cand in "${COLLECTED_SUBS[@]}"; do
        [ "$cand" = "$sub" ] && continue
        [ "${cand%.*}" = "$base" ] || continue
        cand_ext="${cand##*.}"
        if [ "${cand_ext,,}" = "$want" ]; then
            COMPANION="$cand"
            return 0
        fi
    done
    return 1
}

# Move a VobSub pair to its targets as one unit. Both files get the
# suffix worked out from the primary, so they cannot drift apart.
finish_subtitle_pair() {
    local a="$1" b="$2" ta="$3" tb="$4" collision=0 cs es
    PAIR_HANDLED["$a"]=1
    PAIR_HANDLED["$b"]=1

    if [ "$a" = "$ta" ] && [ "$b" = "$tb" ]; then
        sub_skip_noop=$((sub_skip_noop + 2))
        return 0
    fi

    if [ "$ta" != "$a" ] && [ -e "$ta" ]; then collision=1; fi
    if [ "$tb" != "$b" ] && [ -e "$tb" ]; then collision=1; fi

    if [ "$collision" -eq 1 ]; then
        if [ "$DELETE_DUPLICATES" != "true" ]; then
            log "[SUB PAIR SKIP exists] $a"
            log "                  +    $b"
            log "             -->      $ta"
            sub_skip_exists=$((sub_skip_exists + 2))
            return 0
        fi
        # Compare the pairs as wholes. Sizing the .idx and the .sub
        # separately is what produced mismatched pairs: the index and
        # the payload rank in opposite directions.
        cs=$(( $(file_size "$a") + $(file_size "$b") ))
        es=$(( $(file_size "$ta") + $(file_size "$tb") ))
        if [ "$DUPLICATE_KEEP" = "existing" ] || [ "$cs" -le "$es" ]; then
            if [ "$DRY_RUN" = "true" ]; then
                log "[SUB PAIR DRY-RUN $DISPOSE_VERB] $a"
                log "                          +    $b"
            else
                dispose_file "$a"
                dispose_file "$b"
                log "[SUB PAIR $DISPOSE_PAST] $a"
                log "                    +    $b"
            fi
            duplicate_delete=$((duplicate_delete + 2))
            return 0
        fi
        if [ "$DRY_RUN" = "true" ]; then
            log "[SUB PAIR DRY-RUN replace] $ta"
            log "                      +    $tb"
        else
            if [ "$ta" != "$a" ] && [ -e "$ta" ]; then dispose_file "$ta"; fi
            if [ "$tb" != "$b" ] && [ -e "$tb" ]; then dispose_file "$tb"; fi
        fi
        duplicate_delete=$((duplicate_delete + 2))
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "[SUB PAIR DRY-RUN] $a"
        log "              +    $b"
        log "         -->       $ta"
        sub_rename=$((sub_rename + 2))
        return 0
    fi

    if mv -n -- "$a" "$ta" && mv -n -- "$b" "$tb"; then
        log "[SUB PAIR RENAMED] ${a##*/} + ${b##*/}"
        log "              -->  ${ta##*/} + ${tb##*/}"
        sub_rename=$((sub_rename + 2))
    else
        log "[SUB PAIR ERROR] Failed to rename: $a / $b"
        error_count=$((error_count + 1))
    fi
}

# Written-out language names, for scene subtitles that carry a name
# rather than a code ("2_English.srt", "3_Brazilian Portuguese.srt").
declare -A LANG_NAME_TO_CODE=(
    [english]=en    [french]=fr      [spanish]=es     [german]=de
    [italian]=it    [portuguese]=pt  [brazilian]=pt-br
    [dutch]=nl      [danish]=da      [swedish]=sv     [norwegian]=no
    [finnish]=fi    [icelandic]=is   [polish]=pl      [czech]=cs
    [slovak]=sk     [slovenian]=sl   [hungarian]=hu   [romanian]=ro
    [bulgarian]=bg  [croatian]=hr    [serbian]=sr     [bosnian]=bs
    [greek]=el      [turkish]=tr     [russian]=ru     [ukrainian]=uk
    [arabic]=ar     [hebrew]=he      [persian]=fa     [farsi]=fa
    [hindi]=hi      [bengali]=bn     [tamil]=ta       [telugu]=te
    [urdu]=ur       [chinese]=zh     [mandarin]=zh    [cantonese]=zh
    [japanese]=ja   [korean]=ko      [thai]=th        [vietnamese]=vi
    [indonesian]=id [malay]=ms       [filipino]=tl    [tagalog]=tl
    [estonian]=et   [latvian]=lv     [lithuanian]=lt  [albanian]=sq
    [macedonian]=mk [catalan]=ca     [basque]=eu      [galician]=gl
    [welsh]=cy      [irish]=ga       [afrikaans]=af   [swahili]=sw
)

# Work out a language suffix for a subtitle that may be named in
# the scene style rather than with a dotted code. Sets
# SUFFIX_COMPONENTS / SUFFIX_REMAINDER. Non-zero when the language
# cannot be identified, in which case the caller leaves it alone.
derive_scene_suffix() {
    local raw="$1" name tok lang="" flags=()
    peel_suffix "$raw"
    [ "${#SUFFIX_COMPONENTS[@]}" -gt 0 ] && return 0

    name="${raw,,}"
    name="${name//[^a-z]/ }"
    for tok in $name; do
        if [ -z "$lang" ] && [ -n "${LANG_NAME_TO_CODE[$tok]:-}" ]; then
            lang="${LANG_NAME_TO_CODE[$tok]}"
        elif [[ " ${KNOWN_FLAGS[*]} " == *" $tok "* ]]; then
            flags+=("$tok")
        fi
    done
    [ -z "$lang" ] && return 1

    SUFFIX_COMPONENTS=("$lang" ${flags+"${flags[@]}"})
    SUFFIX_REMAINDER="$raw"
    return 0
}

# Is $1 a folder named like a subtitles subfolder?
is_subs_subfolder() {
    local name="${1##*/}" d
    for d in "${SUBS_SUBFOLDERS[@]}"; do
        [ "${name,,}" = "${d,,}" ] && return 0
    done
    return 1
}

# Rename subtitles from a Subs/ subfolder onto the film and move
# them up beside it.
promote_subs_folder() {
    local folder="$1" target_base="$2" child sub base
    shopt -s nullglob
    for child in "$folder"/*/; do
        child="${child%/}"
        [ -d "$child" ] || continue
        is_subs_subfolder "$child" || continue
        collect_subs "$child"
        for sub in "${COLLECTED_SUBS[@]}"; do
            base="${sub##*/}"
            if derive_scene_suffix "${base%.*}"; then
                finish_subtitle "$sub" "$target_base" "$folder"
            else
                log "[SUBS FOLDER SKIP unknown language] $sub"
                subs_folder_skip=$((subs_folder_skip + 1))
            fi
        done
    done
    shopt -u nullglob
}

# Rename a subtitle onto $target_base, handling the no-op and
# already-exists cases. Expects peel_suffix to have run.
finish_subtitle() {
    local sub="$1" target_base="$2" folder="$3"
    local sub_basename sub_ext new_name new_path

    [ -n "${PAIR_HANDLED[$sub]:-}" ] && return 0

    sub_basename="${sub##*/}"
    sub_ext="${sub_basename##*.}"

    # Is this half of a VobSub pair?
    COMPANION=""
    pair_companion_ext "$sub_ext"
    [ -n "$COMPANION_EXT" ] && find_companion "$sub" "$COMPANION_EXT"

    detect_outlier
    if [ -n "$OUTLIER_REASON" ]; then
        if [ "$DELETE_OUTLIERS" = "true" ]; then
            delete_file "$sub" "OUTLIER" "$OUTLIER_REASON" outlier_delete
            PAIR_HANDLED["$sub"]=1
            if [ -n "$COMPANION" ]; then
                # Half a VobSub pair is useless, so the index goes
                # with the payload.
                delete_file "$COMPANION" "OUTLIER" \
                    "$OUTLIER_REASON (VobSub pair)" outlier_delete
                PAIR_HANDLED["$COMPANION"]=1
            fi
            return
        else
            log "[SUB OUTLIER ($OUTLIER_REASON)] $sub"
        fi
    fi

    build_suffix
    new_name="${target_base}${SUFFIX_STRING}.${sub_ext,,}"
    new_path="$folder/$new_name"

    if [ -n "$COMPANION" ]; then
        finish_subtitle_pair "$sub" "$COMPANION" "$new_path" \
            "$folder/${target_base}${SUFFIX_STRING}.${COMPANION_EXT}"
        return
    fi

    if [ "$sub_basename" = "$new_name" ]; then
        sub_skip_noop=$((sub_skip_noop + 1))
        return
    fi

    if [ -e "$new_path" ]; then
        if [ "$DELETE_DUPLICATES" = "true" ]; then
            local winner
            winner="$(choose_duplicate "$sub" "$new_path")"
            if [ "$winner" = "candidate" ]; then
                # The incoming file is the better one. mv -f swaps
                # it in atomically, so there is no window where
                # neither file exists.
                if [ "$DRY_RUN" = "true" ]; then
                    log "[SUB DUP DRY-RUN replace ($DUPLICATE_KEEP)] $sub"
                    log "                  replaces:  $new_path"
                    duplicate_delete=$((duplicate_delete + 1))
                elif dispose_file "$new_path" && mv -n -- "$sub" "$new_path"; then
                    # The loser goes to the trash first, so nothing is
                    # overwritten in place. Without a TRASH_DIR this is
                    # a plain delete-then-rename.
                    log "[SUB DUP REPLACED ($DUPLICATE_KEEP)] $new_path"
                    log "                      with:  $sub"
                    duplicate_delete=$((duplicate_delete + 1))
                else
                    log "[SUB DUP ERROR] Failed to replace: $new_path"
                    error_count=$((error_count + 1))
                fi
            elif [ "$DRY_RUN" = "true" ]; then
                log "[SUB DUP DRY-RUN delete ($DUPLICATE_KEEP)] $sub"
                log "                target:  $new_path"
                duplicate_delete=$((duplicate_delete + 1))
            else
                if dispose_file "$sub"; then
                    log "[SUB DUP $DISPOSE_PAST ($DUPLICATE_KEEP)] $sub"
                    duplicate_delete=$((duplicate_delete + 1))
                else
                    log "[SUB DUP ERROR] Failed to $DISPOSE_VERB: $sub"
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
    PAIR_HANDLED=()
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
            vb="${v##*/}"
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
    linked_base="${tp##*/}"
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
    tp_basename="${tp##*/}"
    expected_tp="${target_path##*/}"

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
        nfo_name="${nfo##*/}"
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
            img_name="${img##*/}"
            img_base="${img_name%.*}"
            art_is_valid "${img_base,,}" && continue
            delete_file "$img" "ART OUTLIER" "" art_outlier_delete
        done
    done
    shopt -u nullglob nocaseglob
}

# Build a case-insensitive find expression from a list of
# -iname patterns, into FIND_EXPR. The caller appends the action
# it wants (-print0, -printf ...), so a walk can collect metadata
# in the same pass instead of forking stat per file.
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
    FIND_EXPR+=(\))
}

# Sweep junk files across every root. Its own pass, so it also
# reaches folders that contain no video.
junk_pass() {
    local j
    log " ---- Junk file deletion pass ----"
    build_find_expr "${JUNK_GLOBS[@]}"
    while IFS= read -r -d '' j; do
        delete_file "$j" "JUNK" "" junk_delete
    done < <(find "${FIND_OPTS[@]}" "${ROOTS[@]}" "${FIND_EXPR[@]}" -print0)
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
        done < <(find "${FIND_OPTS[@]}" "${ROOTS[@]}" -mindepth 1 -type d -empty -print0)
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
            done < <(find "${FIND_OPTS[@]}" "${ROOTS[@]}" -mindepth 1 -type d -empty -print0)
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
    if [ -n "$TRASH_RUN_DIR" ]; then
        log " Quarantined files are under:"
        log "   $TRASH_RUN_DIR"
    fi
    log "=========================================================="
}
