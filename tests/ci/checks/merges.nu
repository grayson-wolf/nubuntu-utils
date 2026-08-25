# merges — main component returns structured rows.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let rows = (merges main --raw)
if ($rows | is-empty) { fail "merges: no rows for main" }
if not ($rows | all {|r| ($r | columns | is-not-empty) }) {
    fail "merges: empty row record"
}
print $"merges OK: ($rows | length) outstanding merges"
