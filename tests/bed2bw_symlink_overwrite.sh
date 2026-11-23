#!/usr/bin/env bash
#
# Regression tests for symlink following in bed2bw.sh.
#
# These tests are expected to FAIL while the vulnerability is present and
# pass once intermediate files are created without following a symlink and
# without deleting a symlink that was already at the output path.
#
# Untested writes that share the same pattern but are performed by tools this
# environment does not have, and that this repository does not vendor:
#   - bedClip opening "${f}.clip" (bed2bw.sh line 114). The script's own rm of
#     that path is tested.
#   - bedGraphToBigWig opening "${outdir}/${filename}.bw" (bed2bw.sh line 116).
#     The shell does not open that path itself.
#
# Run from anywhere:
#   bash tests/bed2bw_symlink_overwrite.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SCRIPT="$ROOT/bin/bed2bw.sh"
SRC_SCRIPT="$ROOT/src/bash_src/postprocess/bed2bw/bed2bw.sh"
HELPER_SRC="$ROOT/tests/swap_before_open.c"

FAILS=0
PASSES=0

ok() {
    PASSES=$((PASSES + 1))
    printf 'ok %s\n' "$1"
}

fail() {
    FAILS=$((FAILS + 1))
    printf 'not ok %s\n' "$1"
    printf '  %s\n' "$2"
}

show_bytes() {
    local path="$1"
    if [ -L "$path" ]; then
        printf 'symlink -> %s' "$(readlink "$path")"
    elif [ ! -e "$path" ]; then
        printf 'absent'
    else
        printf '%s' "$(cat -A "$path" 2>/dev/null || printf '<unreadable>')"
    fi
}

run_bed2bw() {
    local script="$1"
    local bed_dir="$2"
    local out_dir="$3"
    local genome="$4"
    bash "$script" -d "$out_dir" "$bed_dir" "$genome" >/tmp/bed2bw_stdout.$$ 2>/tmp/bed2bw_stderr.$$ || true
}

assert_regular_unchanged() {
    local name="$1"
    local path="$2"
    local backup="$3"
    local inode_before="$4"
    local detail=""

    if [ ! -e "$path" ]; then
        fail "$name" "target file is gone ($(show_bytes "$path"))"
        return
    fi
    if [ -L "$path" ]; then
        fail "$name" "target was replaced by a symlink ($(show_bytes "$path"))"
        return
    fi
    local inode_after
    inode_after="$(stat -c %i "$path")"
    if [ "$inode_after" != "$inode_before" ]; then
        detail="inode changed from $inode_before to $inode_after"
    fi
    if ! cmp -s "$path" "$backup"; then
        detail="${detail:+$detail; }content is now [$(show_bytes "$path")]"
    fi
    if [ -n "$detail" ]; then
        fail "$name" "$detail"
    else
        ok "$name"
    fi
}

assert_symlink_kept() {
    local name="$1"
    local link="$2"
    local expect="$3"

    if [ ! -L "$link" ]; then
        fail "$name" "pre-existing symlink was not left in place ($(show_bytes "$link"))"
        return
    fi
    local got
    got="$(readlink "$link")"
    if [ "$got" != "$expect" ]; then
        fail "$name" "symlink target changed from $expect to $got"
        return
    fi
    ok "$name"
}

assert_absent() {
    local name="$1"
    local path="$2"
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$name" "path was created ($(show_bytes "$path"))"
    else
        ok "$name"
    fi
}

new_case() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/beds" "$root/out"
    printf '%s' "$root"
}

write_bed() {
    local path="$1"
    printf 'track name=demo\nchr1\t10\t20\t%s\n' "$2" > "$path"
}

# --- control: a regular BED directory must not modify an unrelated file ---
control_unrelated() {
    local name="control_unrelated_file_untouched"
    local root bed out victim backup inode
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    rm -rf "$root"
}

# --- .nohead shell redirect ---
nohead_existing() {
    local script="$1"
    local label="$2"
    local name="nohead_existing_target_preserved_${label}"
    local link_name="nohead_existing_symlink_kept_${label}"
    local root bed out victim backup inode link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    link="$bed/track.bed.nohead"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    ln -s "../victim" "$link"
    run_bed2bw "$script" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    assert_symlink_kept "$link_name" "$link" "../victim"
    rm -rf "$root"
}

nohead_dangling() {
    local name="nohead_dangling_target_not_created"
    local link_name="nohead_dangling_symlink_kept"
    local root bed out victim link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/created_by_redirect"
    link="$bed/track.bed.nohead"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    ln -s "../created_by_redirect" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_absent "$name" "$victim"
    assert_symlink_kept "$link_name" "$link" "../created_by_redirect"
    rm -rf "$root"
}

nohead_space_dir() {
    local name="nohead_space_directory_target_preserved"
    local link_name="nohead_space_directory_symlink_kept"
    local root bed out victim backup inode link
    root="$(new_case)"
    bed="$root/bed dir"
    out="$root/out"
    mkdir -p "$bed"
    victim="$root/victim"
    backup="$root/victim.bak"
    link="$bed/track.bed.nohead"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "SPACE_MARKER"
    ln -s "../victim" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    assert_symlink_kept "$link_name" "$link" "../victim"
    rm -rf "$root"
}

# --- .sorted shell redirect. A regular .clip supplies the bytes sort writes. ---
sorted_existing() {
    local name="sorted_existing_target_preserved"
    local link_name="sorted_existing_symlink_kept"
    local root bed out victim backup inode link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    link="$bed/track.bed.sorted"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    printf 'chr1\t10\t20\tSORTED_MARKER\n' > "$bed/track.bed.clip"
    ln -s "../victim" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    assert_symlink_kept "$link_name" "$link" "../victim"
    rm -rf "$root"
}

sorted_dangling() {
    local name="sorted_dangling_target_not_created"
    local link_name="sorted_dangling_symlink_kept"
    local root bed out victim link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/created_by_sort"
    link="$bed/track.bed.sorted"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    printf 'chr1\t10\t20\tSORTED_MARKER\n' > "$bed/track.bed.clip"
    ln -s "../created_by_sort" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_absent "$name" "$victim"
    assert_symlink_kept "$link_name" "$link" "../created_by_sort"
    rm -rf "$root"
}

# --- chromosome-size redirect in the output directory ---
chrom_existing() {
    local name="chrom_sizes_existing_target_preserved"
    local link_name="chrom_sizes_existing_symlink_kept"
    local root bed out victim backup inode link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    link="$out/hg19.chrom.sizes"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    ln -s "../victim" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    assert_symlink_kept "$link_name" "$link" "../victim"
    rm -rf "$root"
}

chrom_dangling() {
    local name="chrom_sizes_dangling_target_not_created"
    local link_name="chrom_sizes_dangling_symlink_kept"
    local root bed out victim link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/created_by_chrom"
    link="$out/hg19.chrom.sizes"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    ln -s "../created_by_chrom" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_absent "$name" "$victim"
    assert_symlink_kept "$link_name" "$link" "../created_by_chrom"
    rm -rf "$root"
}

# bedClip itself is not installed. rm of a symlink already at .clip is.
clip_symlink() {
    local name="clip_symlink_target_preserved"
    local link_name="clip_symlink_kept"
    local root bed out victim backup inode link
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    link="$bed/track.bed.clip"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "NOHEAD_MARKER"
    ln -s "../victim" "$link"
    run_bed2bw "$BIN_SCRIPT" "$bed" "$out" hg19
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    assert_symlink_kept "$link_name" "$link" "../victim"
    rm -rf "$root"
}

build_helpers() {
    local work="$1"
    gcc -shared -fPIC -O2 -o "$work/swap_before_open.so" "$HELPER_SRC"
    gcc -O2 -DSWAP_DRIVER -o "$work/open_driver" "$HELPER_SRC"
}

hook_plain_redirect_follows() {
    local name="hook_plain_redirect_follows"
    local root victim path
    root="$(new_case)"
    victim="$root/victim"
    path="$root/beds/track.bed.nohead"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    printf 'regular\n' > "$path"
    if ! build_helpers "$root"; then
        fail "$name" "could not compile tests/swap_before_open.c"
        rm -rf "$root"
        return
    fi
    SWAP_PATH="$path" SWAP_TARGET="$victim" LD_PRELOAD="$root/swap_before_open.so" \
        bash -c 'echo HOOKED > "$1"' bash "$path" || true
    if cmp -s "$victim" <(printf 'ORIGINAL-SENTINEL\n'); then
        fail "$name" "preload did not make a plain redirect follow the swapped symlink; victim still [$(show_bytes "$victim")]"
    else
        ok "$name"
    fi
    rm -rf "$root"
}

hook_nofollow_does_not_follow() {
    local name="hook_nofollow_does_not_follow"
    local root victim path backup
    root="$(new_case)"
    victim="$root/victim"
    path="$root/beds/track.bed.nohead"
    backup="$root/victim.bak"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    printf 'regular\n' > "$path"
    if ! build_helpers "$root"; then
        fail "$name" "could not compile tests/swap_before_open.c"
        rm -rf "$root"
        return
    fi
    SWAP_PATH="$path" SWAP_TARGET="$victim" LD_PRELOAD="$root/swap_before_open.so" \
        "$root/open_driver" "$path" nofollow || true
    if cmp -s "$victim" "$backup"; then
        ok "$name"
    else
        fail "$name" "O_NOFOLLOW open wrote the symlink target [$(show_bytes "$victim")]"
    fi
    rm -rf "$root"
}

toctou_nohead() {
    local name="toctou_nohead_target_preserved"
    local root bed out victim backup inode path
    root="$(new_case)"
    bed="$root/beds"
    out="$root/out"
    victim="$root/victim"
    backup="$root/victim.bak"
    path="$bed/track.bed.nohead"
    printf 'ORIGINAL-SENTINEL\n' > "$victim"
    cp "$victim" "$backup"
    inode="$(stat -c %i "$victim")"
    write_bed "$bed/track.bed" "TOCTOU_MARKER"
    printf 'regular-intermediate\n' > "$path"
    if ! build_helpers "$root"; then
        fail "$name" "could not compile tests/swap_before_open.c"
        rm -rf "$root"
        return
    fi
    SWAP_PATH="$path" SWAP_TARGET="$victim" LD_PRELOAD="$root/swap_before_open.so" \
        bash "$BIN_SCRIPT" -d "$out" "$bed" hg19 >/tmp/bed2bw_stdout.$$ 2>/tmp/bed2bw_stderr.$$ || true
    assert_regular_unchanged "$name" "$victim" "$backup" "$inode"
    rm -rf "$root"
}

control_unrelated
nohead_existing "$BIN_SCRIPT" bin
nohead_existing "$SRC_SCRIPT" src
nohead_dangling
nohead_space_dir
sorted_existing
sorted_dangling
chrom_existing
chrom_dangling
clip_symlink
hook_plain_redirect_follows
hook_nofollow_does_not_follow
toctou_nohead

rm -f /tmp/bed2bw_stdout.$$ /tmp/bed2bw_stderr.$$

printf 'passed=%s failed=%s\n' "$PASSES" "$FAILS"
if [ "$FAILS" -ne 0 ]; then
    exit 1
fi
exit 0
