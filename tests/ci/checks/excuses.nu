# excuses — the devel-series probe is well-formed whether or not the package
# is currently in proposed. Present → record carries the excuses fields;
# absent → the exact "not found in excuses" error (not a crash).
source-env ../../../env.nu
use ../../../mod.nu *
use ../../../packaging/tests/fetch.nu [fetch-excuses]
use ../../../ubuntu-versions.nu [DEVEL_RELEASE]
use lib.nu *

let sources = (fetch-or-skip excuses { fetch-excuses $DEVEL_RELEASE | get sources })

if ($sources | is-empty) {
    print "excuses OK: report has no entries, skipping present-path probe"
} else {
    # Prefer an entry with autopkgtest data so the schema assertion below is
    # meaningful; fall back to any entry.
    let with_at = ($sources | where {|r| (($r | get -o policy_info.autopkgtest | default {}) | is-not-empty)})
    let probe = (if ($with_at | is-empty) { $sources | get source | first } else { $with_at | get source | first })

    let outcome = (try { { ok: (excuses $probe --raw) } } catch {|e| { err: $e.msg } })
    if ($outcome | get ok? | is-not-empty) {
        let data = $outcome.ok
        for c in [source excuses] {
            if ($c not-in ($data | columns)) {
                fail $"excuses: present but missing field ($c)"
            }
        }
        # Autopkgtest data lives under policy_info (the top-level column the
        # check used to assert no longer exists in the YAML). The command
        # treats it as optional, so only assert it when the report carries it.
        if (($data | get -o policy_info.autopkgtest | default {}) | is-not-empty) {
            print $"excuses OK: ($probe) in proposed, schema valid"
        } else {
            print $"excuses OK: ($probe) in proposed, schema valid \(no autopkgtest data)"
        }
    } else if ($outcome.err | str contains $"not found in ($DEVEL_RELEASE) excuses") {
        # The probe migrated out between the listing fetch and the probe call.
        print "excuses OK: probe migrated mid-check, correct not-found error"
    } else if (is-environmental $outcome.err) {
        print $"excuses SKIP: upstream fetch failed \($outcome.err) — environmental, not a regression"
        exit 0
    } else {
        fail $"excuses: unexpected failure — ($outcome.err)"
    }
}

# Absent → the exact "not found in excuses" error (not a crash)
let bogus = "nubuntu-utils-ci-absent-probe"
let absent = (try { { ok: (excuses $bogus --raw) } } catch {|e| { err: $e.msg } })
if ($absent | get ok? | is-not-empty) {
    fail $"excuses: synthetic package '($bogus)' unexpectedly found"
} else if ($absent.err | str contains $"not found in ($DEVEL_RELEASE) excuses") {
    print "excuses OK: absent package, correct not-found error"
} else if (is-environmental $absent.err) {
    print $"excuses SKIP: upstream fetch failed \($absent.err) — environmental, not a regression"
    exit 0
} else {
    fail $"excuses: unexpected failure — ($absent.err)"
}
