# archive-tests — xz-utils has recorded results with the full schema.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

# Skip the test on autopkgtest timeout or other transient environmental error
let ENVIRONMENTAL = '(?i)timed out|I/O error|error sending request|HTTP \d{3} (fetching|posting)|rate-limited'
let result = (try { { ok: true, rows: (archive-tests xz-utils --raw) } } catch {|e| { ok: false, err: ($e | to nuon) } })
if not $result.ok {
    if ($result.err =~ $ENVIRONMENTAL) {
        print $"archive-tests SKIP: upstream fetch failed (($result.err | str substring 0..120)) — environmental, not a regression"
        return
    }
    fail $"archive-tests: fetch raised a non-environmental error: ($result.err | str substring 0..200)"
}

let rows = $result.rows
if ($rows | is-empty) { fail "archive-tests: no rows for xz-utils" }
let cols = ($rows | get 0 | columns)
for c in [kind time log_url overall subtests triggers series] {
    if ($c not-in $cols) { fail $"archive-tests: missing column ($c)" }
}
if not ($rows | all {|r| $r.log_url | str starts-with "http" }) {
    fail "archive-tests: log_url not a URL"
}
print $"archive-tests OK: ($rows | length) rows"
