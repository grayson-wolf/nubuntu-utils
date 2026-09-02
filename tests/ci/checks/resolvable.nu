# resolvable — row schema + status/level taxonomy on a live source package.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

# A package with no library build-deps returns an empty table, not an error.
let empty = (resolvable hello --raw)
if ($empty | is-not-empty) { fail "resolvable: hello should have no library build-deps" }

# A real library-transition source package yields rows in the valid taxonomy.
# (Don't assert a specific status/level — it tracks live -proposed state.)
let rows = (resolvable haskell-pandoc-types --raw)
if ($rows | is-empty) { fail "resolvable: no rows for haskell-pandoc-types" }
let cols = ($rows | get 0 | columns)
for c in [name status version source level] {
    if ($c not-in $cols) { fail $"resolvable: missing column ($c)" }
}
let valid = ["fine", "ncr", "retrigger", "missing"]
if not ($rows | all {|r| $r.status in $valid }) {
    fail "resolvable: unexpected status value"
}
# actionable rows must carry a level >= 1; fine rows are level 0
if not ($rows | all {|r| if ($r.status in ["ncr", "retrigger"]) { $r.level >= 1 } else { $r.level == 0 } }) {
    fail "resolvable: level/status mismatch"
}
print $"resolvable OK: ($rows | length) rows"
