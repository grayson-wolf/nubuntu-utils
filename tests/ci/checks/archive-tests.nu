# archive-tests — xz-utils has recorded results with the full schema.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let rows = (archive-tests xz-utils --raw)
if ($rows | is-empty) { fail "archive-tests: no rows for xz-utils" }
let cols = ($rows | get 0 | columns)
for c in [kind time log_url overall subtests triggers series] {
    if ($c not-in $cols) { fail $"archive-tests: missing column ($c)" }
}
if not ($rows | all {|r| $r.log_url | str starts-with "http" }) {
    fail "archive-tests: log_url not a URL"
}
print $"archive-tests OK: ($rows | length) rows"
