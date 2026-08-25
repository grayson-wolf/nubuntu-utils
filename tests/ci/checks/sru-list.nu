# sru-list — the pending-SRU report parses into rows with the expected schema.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let rows = (sru-list)
let cols = ($rows | get 0? | default {} | columns)
for c in [package age -release -updates -proposed signer creator bugs] {
    if ($c not-in $cols) { fail $"sru-list: missing column ($c)" }
}
print $"sru-list OK: ($rows | length) pending SRUs"
