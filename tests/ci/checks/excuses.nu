# excuses — the devel-series probe is well-formed whether or not the package
# is currently in proposed. Present → record carries the excuses fields;
# absent → the exact "not found in excuses" error (not a crash).
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let outcome = (try { { ok: (excuses xz-utils --raw) } } catch {|e| { err: $e.msg } })
if ($outcome | get ok? | is-not-empty) {
    let data = $outcome.ok
    for c in [source excuses autopkgtest] {
        if ($c not-in ($data | columns)) {
            fail $"excuses: present but missing field ($c)"
        }
    }
    print "excuses OK: package in proposed, schema valid"
} else if ($outcome.err | str contains "not found in stonking excuses") {
    print "excuses OK: package migrated, correct not-found error"
} else {
    fail $"excuses: unexpected failure — ($outcome.err)"
}
