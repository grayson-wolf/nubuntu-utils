# madison — xz-utils is published, with a sane row schema.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let rows = (madison xz-utils --raw)
if ($rows | is-empty) { fail "madison: no rows for xz-utils" }
let cols = ($rows | get 0 | columns)
for c in [package version suite component arches] {
    if ($c not-in $cols) { fail $"madison: missing column ($c)" }
}
if not ($rows | all {|r| $r.package == "xz-utils" }) {
    fail "madison: row package mismatch"
}
if not ($rows | all {|r| $r.version | is-not-empty }) {
    fail "madison: empty version cell"
}
print $"madison OK: ($rows | length) rows"
