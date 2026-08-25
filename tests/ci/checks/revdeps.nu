# revdeps — zlib1g resolves a large reverse-dependency set.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let rdeps = (revdeps zlib1g)
if ($rdeps | length) < 100 {
    fail $"revdeps: suspiciously few rdeps for zlib1g (($rdeps | length))"
}
if not ($rdeps | all {|r| $r | is-not-empty }) {
    fail "revdeps: empty entry in result"
}
print $"revdeps OK: ($rdeps | length) reverse deps"
