# CI check runner (native mode)

def main [] {
    let here = ($env.CURRENT_FILE? | default "tests/ci/run.nu" | path dirname)
    let scripts = (glob $"($here)/checks/*.nu" | where { $in !~ 'lib.nu' } | sort)

    if ($scripts | is-empty) {
        error make { msg: $"no check scripts found in ($here)/checks" }
    }

    print $"Running ($scripts | length) native checks\n"

    mut passed: list<string> = []
    mut failed: list<string> = []

    for script in $scripts {
        let name = ($script | path basename)
        print $"--- ($name) ---"
        let res = (do { ^nu $script } | complete)
        print -n $res.stdout
        if ($res.stderr | str trim | is-not-empty) { print -e $res.stderr }
        if $res.exit_code == 0 {
            $passed = ($passed | append $name)
        } else {
            $failed = ($failed | append $name)
        }
    }

    print ""
    print $"native: ($passed | length)/($scripts | length) passed"
    if ($failed | is-not-empty) {
        print $"FAILED: ($failed | str join ', ')"
        exit 1
    }
    print "all checks passed"
}
