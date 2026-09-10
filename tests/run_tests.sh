#!/bin/bash
# Test harness for the Library Cleaner scripts.
# Run under GNU bash 4.1+ with GNU findutils/coreutils.
#   ./run_tests.sh /path/to/repo
set -uo pipefail

REPO="${1:?usage: run_tests.sh /path/to/repo}"
WORK="$(mktemp -d)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# Inject config overrides just before the END CONFIGURATION marker,
# so they win over the defaults without editing them.
gen() {
    local src="$1" dst="$2" ovfile="$3"
    awk -v f="$ovfile" '
        /^# --------------------- END CONFIGURATION/ {
            while ((getline line < f) > 0) print line
            close(f)
        }
        { print }
    ' "$src" > "$dst"
    chmod +x "$dst"
}

# List every path under a root, relative and sorted. Directories
# get a trailing slash so we can assert on them too.
snapshot() {
    ( cd "$1" && find . -mindepth 1 \
        \( -type d -printf '%p/\n' \) -o -printf '%p\n' | LC_ALL=C sort )
}

expect_snapshot() {
    local label="$1" root="$2" expected="$3" actual
    actual="$(snapshot "$root")"
    if [ "$actual" = "$expected" ]; then
        ok "$label"
    else
        bad "$label"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
            | sed 's/^/       /'
    fi
}

# =====================================================================
#  FILM FIXTURE
# =====================================================================
build_film() {
    rm -rf "$WORK/films" "$WORK/films2"

    # -- Film A: subtitle + trickplay rename, art & nfo outliers, junk
    local a="$WORK/films/Film A (2020)"
    mkdir -p "$a"
    # Main feature must be the LARGEST video in the folder.
    head -c 4096 /dev/zero > "$a/Film A (2020)-Radarr.mkv"
    : > "$a/Film A (2020) [Bluray]{imdb-tt1}-Radarr.ar.hi.srt"
    : > "$a/Film A (2020) [Bluray]-Radarr.en.srt"
    mkdir -p "$a/Film A (2020) [old].trickplay"
    : > "$a/Film A (2020) [old].trickplay/thumb.jpg"
    : > "$a/poster.jpg"                          # generic art, keep
    : > "$a/fanart2.jpg"                         # numbered generic, keep
    : > "$a/Film A (2020)-Radarr-poster.jpg"     # per-video art, keep
    : > "$a/Film A (2020)-Radarr.jpg"            # kodi thumb, keep
    : > "$a/Film A (2020) [old name]-poster.jpg" # stale art, DELETE
    : > "$a/Film A (2020)-Radarr.nfo"            # keep
    : > "$a/Film A (2020) [old].nfo"             # stale nfo, DELETE
    : > "$a/.DS_Store"                           # junk, DELETE
    : > "$a/RARBG_info.txt"                      # junk, DELETE

    # -- Film B: an extra with its own subtitle must not be hijacked
    local b="$WORK/films/Film B (2021)"
    mkdir -p "$b"
    head -c 4096 /dev/zero > "$b/Film B (2021)-Radarr.mkv"
    head -c 512  /dev/zero > "$b/Film B (2021)-behindthescenes.mkv"
    : > "$b/Film B (2021)-behindthescenes.en.srt"   # must STAY
    : > "$b/Film B (2021) [junk]-Radarr.en.srt"     # -> renamed

    # -- Film C: malformed subtitles
    local c="$WORK/films/Film C (2022)"
    mkdir -p "$c"
    head -c 4096 /dev/zero > "$c/Film C (2022)-Radarr.mkv"
    : > "$c/Film C (2022)-Radarr.3.hi.srt"      # trailing numeric, DELETE
    : > "$c/Film C (2022)-Radarr.hi.hi.srt"     # duplicate suffix, DELETE

    # -- Film D: duplicate target
    local d="$WORK/films/Film D (2023)"
    mkdir -p "$d"
    head -c 4096 /dev/zero > "$d/Film D (2023)-Radarr.mkv"
    : > "$d/Film D (2023)-Radarr.en.srt"          # already correct
    : > "$d/Film D (2023) [other]-Radarr.en.srt"  # dup, DELETE

    # -- Film E: orphan subtitle (no video at all in the folder)
    mkdir -p "$WORK/films/Film E (2024)"
    : > "$WORK/films/Film E (2024)/Film E (2024).en.srt"

    # -- empty folders, including a nested chain
    mkdir -p "$WORK/films/Empty Folder"
    mkdir -p "$WORK/films/Nested/Deep/Deeper"

    # -- second root, to prove multi-root works
    local f="$WORK/films2/Film F (2025)"
    mkdir -p "$f"
    head -c 4096 /dev/zero > "$f/Film F (2025)-Radarr.mkv"
    : > "$f/Film F (2025) [x]-Radarr.en.srt"
}

echo "=== FILM ==========================================================="
build_film
BEFORE_FILM="$(snapshot "$WORK/films")"

cat > "$WORK/ov_film" <<OV
ROOT_DIRS=("$WORK/films" "$WORK/films2" "$WORK/does-not-exist")
DRY_RUN="true"
ENABLE_LOG="true"
TRASH_DIR=""
LOG_FILE="$WORK/film.log"
DELETE_ORPHANS="true"
DELETE_OUTLIERS="true"
DELETE_OUTLIER_NFO="true"
DELETE_DUPLICATES="true"
DELETE_OUTLIER_ART="true"
DELETE_JUNK="true"
PRUNE_EMPTY_DIRS="true"
OV

gen "$REPO/Library Cleaner Film" "$WORK/film.sh" "$WORK/ov_film"

# ---- dry run must change nothing ----
"$WORK/film.sh" > "$WORK/film.dry.out" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "film dry-run exits 0" || bad "film dry-run exit $rc"
if [ "$(snapshot "$WORK/films")" = "$BEFORE_FILM" ]; then
    ok "film dry-run left the library untouched"
else
    bad "film dry-run MODIFIED the library"
    diff <(printf '%s\n' "$BEFORE_FILM") <(snapshot "$WORK/films") | sed 's/^/       /'
fi
grep -q "root does not exist, skipping" "$WORK/film.dry.out" \
    && ok "film reports the missing root" || bad "film missing-root warning absent"
grep -q "Root:.*/films2" "$WORK/film.dry.out" \
    && ok "film picked up the second root" || bad "film second root missing"

# ---- live run ----
sed -i 's|^DRY_RUN="true"$|DRY_RUN="false"|' "$WORK/ov_film"
gen "$REPO/Library Cleaner Film" "$WORK/film.sh" "$WORK/ov_film"
"$WORK/film.sh" > "$WORK/film.live.out" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "film live run exits 0" || bad "film live run exit $rc"

read -r -d '' EXPECT_FILM <<'EXP'
./Film A (2020)/
./Film A (2020)/Film A (2020)-Radarr.ar.hi.srt
./Film A (2020)/Film A (2020)-Radarr.en.srt
./Film A (2020)/Film A (2020)-Radarr.jpg
./Film A (2020)/Film A (2020)-Radarr.mkv
./Film A (2020)/Film A (2020)-Radarr.nfo
./Film A (2020)/Film A (2020)-Radarr-poster.jpg
./Film A (2020)/Film A (2020)-Radarr.trickplay/
./Film A (2020)/Film A (2020)-Radarr.trickplay/thumb.jpg
./Film A (2020)/fanart2.jpg
./Film A (2020)/poster.jpg
./Film B (2021)/
./Film B (2021)/Film B (2021)-behindthescenes.en.srt
./Film B (2021)/Film B (2021)-behindthescenes.mkv
./Film B (2021)/Film B (2021)-Radarr.en.srt
./Film B (2021)/Film B (2021)-Radarr.mkv
./Film C (2022)/
./Film C (2022)/Film C (2022)-Radarr.mkv
./Film D (2023)/
./Film D (2023)/Film D (2023)-Radarr.en.srt
./Film D (2023)/Film D (2023)-Radarr.mkv
EXP
EXPECT_FILM="$(printf '%s\n' "$EXPECT_FILM" | LC_ALL=C sort)"
expect_snapshot "film library ends in the expected state" "$WORK/films" "$EXPECT_FILM"

read -r -d '' EXPECT_FILM2 <<'EXP'
./Film F (2025)/
./Film F (2025)/Film F (2025)-Radarr.en.srt
./Film F (2025)/Film F (2025)-Radarr.mkv
EXP
EXPECT_FILM2="$(printf '%s\n' "$EXPECT_FILM2" | LC_ALL=C sort)"
expect_snapshot "second film root cleaned too" "$WORK/films2" "$EXPECT_FILM2"

grep -q "SUB SKIP belongs to extra" "$WORK/film.live.out" \
    && ok "extra's subtitle was protected by name" \
    || bad "extra-subtitle guard did not fire"
[ -s "$WORK/film.log" ] && ok "film log file written" || bad "film log file empty"

# =====================================================================
#  TV FIXTURE
# =====================================================================
build_tv() {
    rm -rf "$WORK/tv"
    local s1="$WORK/tv/Show One (2019) [tvdbid-1]/Season 01"
    mkdir -p "$s1"
    head -c 4096 /dev/zero > "$s1/Show One - S01E01 - Pilot.mkv"
    head -c 4096 /dev/zero > "$s1/Show One - S01E02 - Second.mkv"
    : > "$s1/Show One - S01E01 - Old Pilot.en.srt"       # -> renamed
    mkdir -p "$s1/Show One - S01E01 - Old Pilot.trickplay"
    : > "$s1/Show One - S01E01 - Old Pilot.trickplay/t.jpg"
    : > "$s1/Show One - S01E02 - Second.ar.hi.srt"       # already correct
    : > "$s1/Show One - S01E99 - Ghost.en.srt"           # no video, DELETE
    : > "$s1/NoToken.en.srt"                             # no token, DELETE
    : > "$s1/season01-poster.jpg"                        # season art, keep
    : > "$s1/poster.jpg"                                 # generic art, keep
    : > "$s1/Show One - S01E01 - Pilot-thumb.jpg"        # keep
    : > "$s1/Show One - S01E01 - Old Pilot-thumb.jpg"    # stale art, DELETE
    : > "$s1/Show One - S01E01 - Pilot.nfo"              # keep
    : > "$s1/Show One - S01E01 - Old Pilot.nfo"          # stale nfo, DELETE
    : > "$s1/Thumbs.db"                                  # junk, DELETE

    local sp="$WORK/tv/Show One (2019) [tvdbid-1]/Specials"
    mkdir -p "$sp"
    head -c 4096 /dev/zero > "$sp/Show One - S00E01 - Special.mkv"
    : > "$sp/Show One - S00E01 - Old.en.srt"             # -> renamed

    # Not a season folder: must be left completely alone.
    mkdir -p "$WORK/tv/Show One (2019) [tvdbid-1]/Extras"
    : > "$WORK/tv/Show One (2019) [tvdbid-1]/Extras/stray.en.srt"
    : > "$WORK/tv/Show One (2019) [tvdbid-1]/tvshow.nfo"

    # Two videos claiming S02E01 -> ambiguous, nothing touched.
    local s2="$WORK/tv/Show Two/Season 02"
    mkdir -p "$s2"
    head -c 4096 /dev/zero > "$s2/Show Two - S02E01 - A.mkv"
    head -c 2048 /dev/zero > "$s2/Show Two - S02E01 - B.mkv"
    : > "$s2/Show Two - S02E01 - C.en.srt"
}

echo
echo "=== TV ============================================================="
build_tv
BEFORE_TV="$(snapshot "$WORK/tv")"

cat > "$WORK/ov_tv" <<OV
ROOT_DIRS=("$WORK/tv")
DRY_RUN="true"
ENABLE_LOG="true"
TRASH_DIR=""
LOG_FILE="$WORK/tv.log"
DELETE_ORPHANS="true"
DELETE_OUTLIERS="true"
DELETE_OUTLIER_NFO="true"
DELETE_DUPLICATES="true"
DELETE_OUTLIER_ART="true"
DELETE_JUNK="true"
PRUNE_EMPTY_DIRS="true"
OV

gen "$REPO/Library Cleaner TV" "$WORK/tv.sh" "$WORK/ov_tv"
"$WORK/tv.sh" > "$WORK/tv.dry.out" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "tv dry-run exits 0" || bad "tv dry-run exit $rc"
if [ "$(snapshot "$WORK/tv")" = "$BEFORE_TV" ]; then
    ok "tv dry-run left the library untouched"
else
    bad "tv dry-run MODIFIED the library"
    diff <(printf '%s\n' "$BEFORE_TV") <(snapshot "$WORK/tv") | sed 's/^/       /'
fi
grep -q "Season folders found: 3" "$WORK/tv.dry.out" \
    && ok "tv found 3 season folders (Season 01, Specials, Season 02)" \
    || bad "tv season discovery wrong: $(grep 'Season folders found' "$WORK/tv.dry.out")"

sed -i 's|^DRY_RUN="true"$|DRY_RUN="false"|' "$WORK/ov_tv"
gen "$REPO/Library Cleaner TV" "$WORK/tv.sh" "$WORK/ov_tv"
"$WORK/tv.sh" > "$WORK/tv.live.out" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "tv live run exits 0" || bad "tv live run exit $rc"

read -r -d '' EXPECT_TV <<'EXP'
./Show One (2019) [tvdbid-1]/
./Show One (2019) [tvdbid-1]/Extras/
./Show One (2019) [tvdbid-1]/Extras/stray.en.srt
./Show One (2019) [tvdbid-1]/Season 01/
./Show One (2019) [tvdbid-1]/Season 01/poster.jpg
./Show One (2019) [tvdbid-1]/Season 01/season01-poster.jpg
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.en.srt
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.mkv
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.nfo
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot-thumb.jpg
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.trickplay/
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.trickplay/t.jpg
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E02 - Second.ar.hi.srt
./Show One (2019) [tvdbid-1]/Season 01/Show One - S01E02 - Second.mkv
./Show One (2019) [tvdbid-1]/Specials/
./Show One (2019) [tvdbid-1]/Specials/Show One - S00E01 - Special.en.srt
./Show One (2019) [tvdbid-1]/Specials/Show One - S00E01 - Special.mkv
./Show One (2019) [tvdbid-1]/tvshow.nfo
./Show Two/
./Show Two/Season 02/
./Show Two/Season 02/Show Two - S02E01 - A.mkv
./Show Two/Season 02/Show Two - S02E01 - B.mkv
./Show Two/Season 02/Show Two - S02E01 - C.en.srt
EXP
EXPECT_TV="$(printf '%s\n' "$EXPECT_TV" | LC_ALL=C sort)"
expect_snapshot "tv library ends in the expected state" "$WORK/tv" "$EXPECT_TV"

grep -q "SUB SKIP duplicate ep S02E01" "$WORK/tv.live.out" \
    && ok "ambiguous duplicate episode was skipped" \
    || bad "ambiguous duplicate episode not skipped"

# =====================================================================
#  NFO CLEANER
# =====================================================================
echo
echo "=== NFO CLEANER ===================================================="
rm -rf "$WORK/nfo1" "$WORK/nfo2"
mkdir -p "$WORK/nfo1/a" "$WORK/nfo2/b"
: > "$WORK/nfo1/a/one.nfo"
: > "$WORK/nfo1/a/two.NFO"
: > "$WORK/nfo1/a/three.nfo-orig"
: > "$WORK/nfo1/a/keep.mkv"
: > "$WORK/nfo2/b/four.nfo"
: > "$WORK/nfo2/b/keep.mkv"

cat > "$WORK/ov_nfo" <<OV
ROOT_DIRS=("$WORK/nfo1" "$WORK/nfo2" "$WORK/does-not-exist")
DRY_RUN="true"
ENABLE_LOG="true"
TRASH_DIR=""
OV
gen "$REPO/NFO Cleaner" "$WORK/nfo.sh" "$WORK/ov_nfo"
"$WORK/nfo.sh" > "$WORK/nfo.dry.out" 2>&1
grep -q "WOULD be deleted: 4" "$WORK/nfo.dry.out" \
    && ok "nfo dry-run counts 4 across both roots" \
    || bad "nfo dry-run count wrong: $(grep 'WOULD be deleted' "$WORK/nfo.dry.out")"
[ -f "$WORK/nfo1/a/one.nfo" ] && ok "nfo dry-run deleted nothing" \
    || bad "nfo dry-run deleted files"

sed -i 's|^DRY_RUN="true"$|DRY_RUN="false"|' "$WORK/ov_nfo"
gen "$REPO/NFO Cleaner" "$WORK/nfo.sh" "$WORK/ov_nfo"
"$WORK/nfo.sh" > "$WORK/nfo.live.out" 2>&1
remaining="$(find "$WORK/nfo1" "$WORK/nfo2" -type f | LC_ALL=C sort | sed "s|$WORK/||")"
if [ "$remaining" = "nfo1/a/keep.mkv
nfo2/b/keep.mkv" ]; then
    ok "nfo live run removed exactly the .nfo files"
else
    bad "nfo live run left: $remaining"
fi


# =====================================================================
#  GLOB-METACHARACTER PATHS
#  Real roots look like "/mnt/user/Media-Large/Films/[1080p, OF]".
#  "[...]" is a bracket expression, so prove quoting holds throughout.
# =====================================================================
echo
echo "=== BRACKETED ROOTS ================================================"
rm -rf "$WORK/br"
FR="$WORK/br/Media-Large/Films/[1080p, OF]"
FR2="$WORK/br/Media-Huge/Films/[2160p, RX]"
mkdir -p "$FR/Film A (2020)" "$FR2/Film B (2021)"
head -c 4096 /dev/zero > "$FR/Film A (2020)/Film A (2020)-Radarr.mkv"
: > "$FR/Film A (2020)/Film A (2020) [Bluray]-Radarr.en.srt"
mkdir -p "$FR/Film A (2020)/Film A (2020) [old].trickplay"
: > "$FR/Film A (2020)/Film A (2020) [old].trickplay/t.jpg"
: > "$FR/Film A (2020)/Film A (2020) [stale]-poster.jpg"
: > "$FR/Film A (2020)/poster.jpg"
head -c 4096 /dev/zero > "$FR2/Film B (2021)/Film B (2021)-Radarr.mkv"
: > "$FR2/Film B (2021)/Film B (2021) [x]-Radarr.en.srt"

cat > "$WORK/ov_br" <<OV
ROOT_DIRS=("$FR" "$FR2")
DRY_RUN="false"
ENABLE_LOG="true"
TRASH_DIR=""
LOG_FILE="$WORK/br.log"
DELETE_OUTLIER_ART="true"
DELETE_JUNK="true"
PRUNE_EMPTY_DIRS="true"
OV
gen "$REPO/Library Cleaner Film" "$WORK/br.sh" "$WORK/ov_br"
"$WORK/br.sh" > "$WORK/br.out" 2>&1

[ -f "$FR/Film A (2020)/Film A (2020)-Radarr.en.srt" ] \
    && ok "subtitle renamed inside a [bracketed] root" \
    || bad "subtitle NOT renamed inside a [bracketed] root"
[ -d "$FR/Film A (2020)/Film A (2020)-Radarr.trickplay" ] \
    && ok "trickplay renamed inside a [bracketed] root" \
    || bad "trickplay NOT renamed inside a [bracketed] root"
[ ! -e "$FR/Film A (2020)/Film A (2020) [stale]-poster.jpg" ] \
    && ok "stale art removed inside a [bracketed] root" \
    || bad "stale art NOT removed inside a [bracketed] root"
[ -f "$FR/Film A (2020)/poster.jpg" ] \
    && ok "generic art kept inside a [bracketed] root" \
    || bad "generic art wrongly removed"
[ -f "$FR2/Film B (2021)/Film B (2021)-Radarr.en.srt" ] \
    && ok "second [bracketed] root processed" \
    || bad "second [bracketed] root NOT processed"

TR="$WORK/br/Media-Large/Shows/[2160p, MN]"
mkdir -p "$TR/Show One [tvdbid-1]/Season 01"
head -c 4096 /dev/zero > "$TR/Show One [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.mkv"
: > "$TR/Show One [tvdbid-1]/Season 01/Show One - S01E01 - Old.en.srt"
cat > "$WORK/ov_brtv" <<OV
ROOT_DIRS=("$TR")
DRY_RUN="false"
ENABLE_LOG="true"
TRASH_DIR=""
LOG_FILE="$WORK/brtv.log"
OV
gen "$REPO/Library Cleaner TV" "$WORK/brtv.sh" "$WORK/ov_brtv"
"$WORK/brtv.sh" > "$WORK/brtv.out" 2>&1
grep -q "Season folders found: 1" "$WORK/brtv.out" \
    && ok "tv season discovery works under a [bracketed] root" \
    || bad "tv season discovery broken under a [bracketed] root"
[ -f "$TR/Show One [tvdbid-1]/Season 01/Show One - S01E01 - Pilot.en.srt" ] \
    && ok "tv subtitle renamed inside a [bracketed] root" \
    || bad "tv subtitle NOT renamed inside a [bracketed] root"

: > "$FR/Film A (2020)/stale.nfo"
cat > "$WORK/ov_brnfo" <<OV
ROOT_DIRS=("$WORK/br/Media-Large" "$WORK/br/Media-Huge")
DRY_RUN="false"
ENABLE_LOG="true"
TRASH_DIR=""
OV
gen "$REPO/NFO Cleaner" "$WORK/brnfo.sh" "$WORK/ov_brnfo"
"$WORK/brnfo.sh" > "$WORK/brnfo.out" 2>&1
[ ! -e "$FR/Film A (2020)/stale.nfo" ] \
    && ok "nfo cleaner reaches into [bracketed] subfolders" \
    || bad "nfo cleaner missed a [bracketed] path"


# =====================================================================
#  LANGUAGE CODES AND DUPLICATE RESOLUTION
# =====================================================================
echo
echo "=== LANGUAGES ======================================================"
lang_fixture() {
    rm -rf "$WORK/lang"
    local d="$WORK/lang/Film (2020)"
    mkdir -p "$d"
    head -c 4096 /dev/zero > "$d/Film (2020)-Radarr.mkv"
    # Release tags that are NOT languages.
    : > "$d/Film.2020.1080p.WEB.DDP.srt"
    : > "$d/Film.2020.HDR.ass"
    # Genuine language codes, which must survive.
    : > "$d/Film.2020.BluRay.x264-GRP.eng.srt"
    : > "$d/Film (2020) [x]-Radarr.pt-br.srt"
    : > "$d/Film (2020) [y]-Radarr.ar.hi.srt"
}
lang_fixture
cat > "$WORK/ov_lang" <<OV
ROOT_DIRS=("$WORK/lang")
DRY_RUN="false"
ENABLE_LOG="false"
TRASH_DIR=""
OV
gen "$REPO/Library Cleaner Film" "$WORK/lang.sh" "$WORK/ov_lang"
"$WORK/lang.sh" > "$WORK/lang.out" 2>&1
got="$(cd "$WORK/lang/Film (2020)" && ls | LC_ALL=C sort | tr '\n' ' ')"

for fake in web ddp hdr aac; do
    if printf '%s' "$got" | grep -q "\.$fake\."; then
        bad "release tag '$fake' was treated as a language"
    else
        ok "release tag '$fake' not treated as a language"
    fi
done
[ -f "$WORK/lang/Film (2020)/Film (2020)-Radarr.eng.srt" ] \
    && ok "ISO 639-2 code 'eng' preserved" || bad "'eng' lost: $got"
[ -f "$WORK/lang/Film (2020)/Film (2020)-Radarr.pt-br.srt" ] \
    && ok "regional code 'pt-br' preserved" || bad "'pt-br' lost: $got"
[ -f "$WORK/lang/Film (2020)/Film (2020)-Radarr.ar.hi.srt" ] \
    && ok "language+flag 'ar.hi' preserved" || bad "'ar.hi' lost: $got"

echo
echo "=== DUPLICATE RESOLUTION ==========================================="
# Two subs that both resolve to the same target. The bigger one is
# the better subtitle and must be the survivor, whichever order the
# shell happens to reach them in.
dup_fixture() {
    rm -rf "$WORK/dup"
    local d="$WORK/dup/Film (2020)"
    mkdir -p "$d"
    head -c 4096 /dev/zero > "$d/Film (2020)-Radarr.mkv"
    head -c 100  /dev/zero > "$d/Film.2020.WEB.DDP.srt"     # small
    head -c 5000 /dev/zero > "$d/Film.2020.HDR.srt"         # large
}

dup_fixture
cat > "$WORK/ov_dup" <<OV
ROOT_DIRS=("$WORK/dup")
DRY_RUN="false"
ENABLE_LOG="false"
TRASH_DIR=""
DELETE_DUPLICATES="true"
DUPLICATE_KEEP="largest"
OV
gen "$REPO/Library Cleaner Film" "$WORK/dup.sh" "$WORK/ov_dup"
"$WORK/dup.sh" > "$WORK/dup.out" 2>&1
target="$WORK/dup/Film (2020)/Film (2020)-Radarr.srt"
if [ -f "$target" ] && [ "$(stat -c%s "$target")" -eq 5000 ]; then
    ok "DUPLICATE_KEEP=largest kept the bigger subtitle"
else
    bad "DUPLICATE_KEEP=largest kept the wrong file (size $(stat -c%s "$target" 2>/dev/null))"
fi
n="$(find "$WORK/dup/Film (2020)" -name '*.srt' | wc -l)"
[ "$n" -eq 1 ] && ok "collision left exactly one subtitle" \
                || bad "collision left $n subtitles"

dup_fixture
sed 's|^DUPLICATE_KEEP=.*|DUPLICATE_KEEP="existing"|' "$WORK/ov_dup" > "$WORK/ov_dup2"
gen "$REPO/Library Cleaner Film" "$WORK/dup2.sh" "$WORK/ov_dup2"
"$WORK/dup2.sh" > "$WORK/dup2.out" 2>&1
# "existing" keeps whichever landed first, so only assert that it
# resolved to a single file rather than which one won.
n="$(find "$WORK/dup/Film (2020)" -name '*.srt' | wc -l)"
[ "$n" -eq 1 ] && ok "DUPLICATE_KEEP=existing also resolves to one file" \
                || bad "DUPLICATE_KEEP=existing left $n subtitles"

# With DELETE_DUPLICATES off, nothing is removed.
dup_fixture
cat > "$WORK/ov_dup3" <<OV
ROOT_DIRS=("$WORK/dup")
DRY_RUN="false"
ENABLE_LOG="false"
TRASH_DIR=""
DELETE_DUPLICATES="false"
OV
gen "$REPO/Library Cleaner Film" "$WORK/dup3.sh" "$WORK/ov_dup3"
"$WORK/dup3.sh" > "$WORK/dup3.out" 2>&1
n="$(find "$WORK/dup/Film (2020)" -name '*.srt' | wc -l)"
[ "$n" -eq 2 ] && ok "DELETE_DUPLICATES=false deletes nothing on collision" \
                || bad "DELETE_DUPLICATES=false left $n subtitles, expected 2"


# =====================================================================
#  QUARANTINE
# =====================================================================
echo
echo "=== QUARANTINE ====================================================="
rm -rf "$WORK/q" "$WORK/qtrash"
qd="$WORK/q/films/Film E (2024)"
mkdir -p "$qd"
: > "$qd/Film E (2024).en.srt"          # orphan: no video in the folder
mkdir -p "$WORK/q/films/Film F (2025)"
head -c 4096 /dev/zero > "$WORK/q/films/Film F (2025)/Film F (2025)-Radarr.mkv"
: > "$WORK/q/films/Film F (2025)/.DS_Store"

cat > "$WORK/ov_q" <<OV
ROOT_DIRS=("$WORK/q/films")
DRY_RUN="false"
ENABLE_LOG="true"
LOG_FILE="$WORK/q.log"
TRASH_DIR="$WORK/qtrash"
DELETE_ORPHANS="true"
DELETE_JUNK="true"
OV
gen "$REPO/Library Cleaner Film" "$WORK/q.sh" "$WORK/ov_q"
"$WORK/q.sh" > "$WORK/q.out" 2>&1

[ ! -e "$qd/Film E (2024).en.srt" ] \
    && ok "quarantined orphan left the library" \
    || bad "quarantined orphan still in the library"
found="$(find "$WORK/qtrash" -name 'Film E (2024).en.srt' | head -1)"
[ -n "$found" ] && ok "orphan recoverable from the trash" \
                || bad "orphan NOT found under the trash dir"
case "$found" in
    */Film\ E\ \(2024\)/Film\ E\ \(2024\).en.srt)
        ok "trash preserves the original folder structure" ;;
    *)  bad "trash path lost its structure: $found" ;;
esac
[ -n "$(find "$WORK/qtrash" -name '.DS_Store' | head -1)" ] \
    && ok "quarantined junk recoverable too" \
    || bad "junk was not quarantined"
grep -q "TRASHED" "$WORK/q.out" \
    && ok "log says TRASHED rather than DELETED" \
    || bad "log did not report quarantining"
grep -q "Quarantined files are under:" "$WORK/q.out" \
    && ok "summary points at the trash folder" \
    || bad "summary omits the trash location"

# A trash dir inside a library root defeats the safety net, because
# the junk and empty-folder passes would walk straight back into it.
cat > "$WORK/ov_qbad" <<OV
ROOT_DIRS=("$WORK/q/films")
DRY_RUN="true"
ENABLE_LOG="true"
LOG_FILE="$WORK/qbad.log"
TRASH_DIR="$WORK/q/films/.trash"
OV
gen "$REPO/Library Cleaner Film" "$WORK/qbad.sh" "$WORK/ov_qbad"
"$WORK/qbad.sh" > "$WORK/qbad.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "refuses to run with TRASH_DIR inside a root" \
                || bad "accepted a TRASH_DIR inside a library root"
grep -q "TRASH_DIR is inside a library root" "$WORK/qbad.out" \
    && ok "explains why it refused" || bad "refusal message missing"

# Dry run must not move anything.
rm -rf "$WORK/q2" "$WORK/q2trash"
mkdir -p "$WORK/q2/films/Film G (2026)"
: > "$WORK/q2/films/Film G (2026)/Film G (2026).en.srt"
cat > "$WORK/ov_q2" <<OV
ROOT_DIRS=("$WORK/q2/films")
DRY_RUN="true"
ENABLE_LOG="false"
TRASH_DIR="$WORK/q2trash"
DELETE_ORPHANS="true"
OV
gen "$REPO/Library Cleaner Film" "$WORK/q2.sh" "$WORK/ov_q2"
"$WORK/q2.sh" > /dev/null 2>&1
[ -f "$WORK/q2/films/Film G (2026)/Film G (2026).en.srt" ] && [ ! -d "$WORK/q2trash" ] \
    && ok "dry run quarantines nothing and creates no trash folder" \
    || bad "dry run touched files or created a trash folder"


# NFO Cleaner honours the same safety net.
rm -rf "$WORK/nfoq" "$WORK/nfoqtrash"
mkdir -p "$WORK/nfoq/a"
: > "$WORK/nfoq/a/stale.nfo"
: > "$WORK/nfoq/a/keep.mkv"
cat > "$WORK/ov_nfoq" <<OV
ROOT_DIRS=("$WORK/nfoq")
DRY_RUN="false"
ENABLE_LOG="true"
TRASH_DIR="$WORK/nfoqtrash"
OV
gen "$REPO/NFO Cleaner" "$WORK/nfoq.sh" "$WORK/ov_nfoq"
"$WORK/nfoq.sh" > "$WORK/nfoq.out" 2>&1
[ ! -e "$WORK/nfoq/a/stale.nfo" ] && [ -n "$(find "$WORK/nfoqtrash" -name 'stale.nfo' | head -1)" ] \
    && ok "nfo cleaner quarantines instead of deleting" \
    || bad "nfo cleaner did not quarantine"
[ -f "$WORK/nfoq/a/keep.mkv" ] && ok "nfo cleaner left the video alone" \
                               || bad "nfo cleaner touched the video"


# =====================================================================
#  BUILD FRESHNESS
#  The scripts at the repo root are generated from src/ by build.sh.
#  Catch the case where src/ was edited but build.sh was not re-run.
# =====================================================================
echo
echo "=== BUILD =========================================================="
check_generated() {
    local src="$1" out="$2"
    awk -v dir="$REPO/src" '
        /^#@include / {
            f = dir "/" $2
            while ((getline line < f) > 0) print line
            close(f)
            next
        }
        { print }
    ' "$REPO/$src" > "$WORK/generated"
    if diff -q "$WORK/generated" "$REPO/$out" >/dev/null 2>&1; then
        ok "$out is up to date with $src"
    else
        bad "$out is STALE - run ./build.sh and commit the result"
        diff "$REPO/$out" "$WORK/generated" | head -20 | sed 's/^/       /'
    fi
}
check_generated "src/film.sh" "Library Cleaner Film"
check_generated "src/tv.sh"   "Library Cleaner TV"

echo
echo "===================================================================="
echo " passed: $PASS   failed: $FAIL"
echo " workdir: $WORK"
[ "$FAIL" -eq 0 ]
