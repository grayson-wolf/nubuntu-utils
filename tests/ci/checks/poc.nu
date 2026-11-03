# poc — xz-utils maps to a package team.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let teams = (fetch-or-skip poc { poc xz-utils })
if ($teams | is-empty) { fail "poc: no team for xz-utils" }
print $"poc OK: ($teams | str join ", ")"
