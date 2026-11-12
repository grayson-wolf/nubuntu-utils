# poc — xz-utils maps to a package team.
source-env ../../../env.nu
use ../../../mod.nu *
use ../../../packaging/cache.nu [cache-file-flat, cache-save]
use lib.nu *

# Seed the cache with a non-mapping payload and make sure poc ignores it and refetches.
cache-save (cache-file-flat "package-team-mapping.nuon") "Default page for the haproxy-operator charm"

let teams = (fetch-or-skip poc { poc xz-utils })
if ($teams | is-empty) { fail "poc: no team for xz-utils" }
print $"poc OK: ($teams | str join ", ")"
