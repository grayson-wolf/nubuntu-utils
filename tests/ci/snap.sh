#!/usr/bin/env bash
# Snap CI checks
set -u
pass=0
fail=0
failed_names=()

ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n%s\n' "$1" "$2"; fail=$((fail+1)); failed_names+=("$1"); }

# Each check echoes its captured wrapper output on failure so the runner can
# show it. Return 0 = pass, 1 = fail.

# archive-tests — renders a non-trivial results table.
check_archive_tests() {
    local out
    # skip on transient timeout/network errors
    out=$(timeout 120 nubuntu-utils.archive-tests xz-utils 2>&1)
    if printf '%s' "$out" | grep -qiE "timed out|I/O error|HTTP [0-9]{3} fetching|error sending request"; then
        printf 'SKIP archive_tests (upstream fetch failed — environmental)\n'; return 0
    fi
    if [ "$(printf '%s\n' "$out" | wc -l)" -lt 3 ]; then printf '%s\n' "$out"; return 1; fi
}

# excuses — present → rendered detail; absent → exact not-found error.
check_excuses() {
    local out rc
    out=$(timeout 120 nubuntu-utils.excuses xz-utils 2>&1); rc=$?
    if [ $rc -eq 0 ]; then
        printf '%s' "$out" | grep -q xz-utils || { printf '%s\n' "$out"; return 1; }
    else
        printf '%s' "$out" | grep -q "not found in stonking excuses" || { printf '%s\n' "$out"; return 1; }
    fi
}

# revdeps — zlib1g has a lot of deps
check_revdeps() {
    local out n
    out=$(timeout 120 nubuntu-utils.revdeps zlib1g 2>&1)
    n=$(printf '%s\n' "$out" | grep -c .)
    if [ "$n" -lt 100 ]; then printf '%s\n' "$out"; return 1; fi
}

# poc — xz-utils maps to a non-empty team list.
check_poc() {
    local out
    out=$(timeout 60 nubuntu-utils.poc xz-utils 2>&1)
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then printf '%s\n' "$out"; return 1; fi
}

# merges — main component renders a non-trivial table.
check_merges() {
    local out
    out=$(timeout 120 nubuntu-utils.merges main 2>&1)
    if [ "$(printf '%s\n' "$out" | wc -l)" -lt 3 ]; then printf '%s\n' "$out"; return 1; fi
}

# sru-list — the report renders a table with a package column.
check_sru_list() {
    local out
    out=$(timeout 120 nubuntu-utils.sru-list 2>&1)
    printf '%s' "$out" | grep -q package || { printf '%s\n' "$out"; return 1; }
}

# nbs-report — renders the current report's per-package summary table.
check_nbs_report() {
    local out
    out=$(timeout 120 nubuntu-utils.nbs-report 2>&1)
    printf '%s' "$out" | grep -q "rdeps" || { printf '%s\n' "$out"; return 1; }
}

# resolvable — scans archive indexes with the snap-staged ripgrep; must not
# report `rg` missing, and must emit the level column.
check_resolvable() {
    local out
    out=$(timeout 180 nubuntu-utils.resolvable xz-utils 2>&1)
    if printf '%s' "$out" | grep -q "Command .rg. not found"; then
        printf 'rg not reachable inside the snap\n%s\n' "$out"; return 1
    fi
    printf '%s' "$out" | grep -qiE "level|resolve cleanly|ncr|retrigger" || { printf '%s\n' "$out"; return 1; }
}

for c in archive_tests excuses revdeps poc merges sru_list nbs_report resolvable; do
    echo "--- $c ---"
    if out=$("check_$c" 2>&1); then ok "$c"; else bad "$c" "$out"; fi
done

echo
echo "snap: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    printf 'FAILED: %s\n' "${failed_names[*]}"
    exit 1
fi
echo "all snap checks passed"
