# Proposed-migration (excuses) tooling: fetching, displaying, and clustering.
# Display/classification helpers (formatters, the autopkgtest taxonomy, and the
# row builder) live in excuses-format.nu.

use ../meta.nu [pkg-name]
use ../../completions.nu [pkg-completions]
use ../../formatting.nu [osc8-link, lp-bug-link, lp-source-link, days-to-duration, with-spinner, version-delta, fmt-date-relative]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]
use fetch.nu [fetch-excuses]
use excuses-format.nu [format-verdict, build-autopkgtest-rows, parse-dependency-issues]

# Show proposed-migration (excuses) status for a package.
# By default, only shows packages with regressions or in-progress tests.
# Prints metadata to stderr; returns the autopkgtest results as a table for pipelines.
export def excuses [
    package?: string@pkg-completions                   # Package name (defaults to cwd package)
    --series (-s): string = $DEVEL_RELEASE             # Ubuntu series
    --raw (-r)                                         # Output raw parsed YAML record
    --all (-a)                                         # Show all test results, not just actionable ones
    --why (-w)                                         # Refine REGRESSION cells with log-derived failure mode (real-fail / timeout / tmpfail / badpkg / broken)
    --failing (-f)                                     # Only rows with a real test regression (implies -w)
    --dependencies (-d)                                # Show blocking dependencies' test results
]: nothing -> table {
    # --failing implies --why
    let why = ($why or $failing)

    let pkg = $package | default (pkg-name)

    let excuses = with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series }

    let date = $excuses | get generated-date
    let sources = $excuses | get sources

    let matches = ($sources | where source == $pkg)

    if ($matches | is-empty) {
        error make { msg: $"Package '($pkg)' not found in ($series) excuses." }
    }

    let data = ($matches | first)

    if $raw {
        return $data
    }

    print -e $"Excuses as of (fmt-date-relative $date)"

    print-excuses-detail $data $pkg

    # --dependencies mode: show the package's own test results, then the
    # combined test table for all blocking dependencies. Direct failures
    # come first (with blocker = the package itself).
    if $dependencies {
        let blocked_by = ($data | get -o dependencies.blocked-by | default [])
        let migrate_after = ($data | get -o dependencies.migrate-after | default [])
        let self_at = ($data | get -o policy_info.autopkgtest | default {})
        let dep_pkgs = ($blocked_by | append $migrate_after)

        # Resolve each dep to its autopkgtest substructure; drop deps with none.
        let dep_entries = ($dep_pkgs | each {|dep_pkg|
            let d = ($sources | where source == $dep_pkg)
            if ($d | is-empty) { null } else {
                let at = ($d | first | get -o policy_info.autopkgtest | default {})
                if ($at | is-empty) { null } else { { pkg: $dep_pkg, at: $at } }
            }
        } | where { $in != null })

        if ($self_at | is-empty) and ($dep_entries | is-empty) {
            print -e "\(no test data for package or blocking dependencies\)"
            return []
        }

        # Union of arches across self + all deps so cross-package rows align.
        let all_entries = (
            (if ($self_at | is-empty) { [] } else { [{ pkg: $pkg, at: $self_at }] })
            | append $dep_entries
        )
        let all_arches = ($all_entries | each {|e|
            $e.at | reject -o verdict | values | each { columns } | flatten
        } | flatten | uniq | sort)

        let rows = ($all_entries | each {|e|
            build-autopkgtest-rows $e.at $all $why $all_arches $failing
                | each {|r| { blocker: $e.pkg } | merge $r }
        } | flatten)

        if ($rows | is-empty) {
            print -e "\(no actionable test results for package or blocking dependencies\)"
            return []
        }
        return $rows
    }

    # Build the test results table for the package itself
    let rows = (build-autopkgtest-rows ($data | get -o policy_info.autopkgtest | default {}) $all $why [] $failing)
    if ($rows | is-empty) {
        let autopkgtest = ($data | get -o policy_info.autopkgtest)
        if ($autopkgtest | is-empty) {
            print -e "No autopkgtest data available."
        } else {
            print -e "\(no actionable test results — use -a to show all\)"
        }
        return []
    }
    $rows
}

# Print the human-readable excuses header for a package to stderr: version
# delta, verdict, age, dependency blockers, component mismatches, missing
# builds, NBS cruft, block bugs, hints, and new binaries.
def print-excuses-detail [data: record, pkg: string]: nothing -> nothing {
    # Print metadata to stderr so table output is clean for pipelines
    let old_ver = ($data | get old-version)
    let new_ver = ($data | get new-version)
    let verdict = ($data | get migration-policy-verdict)
    let age = ($data | get -o policy_info.age.current-age | default "?")
    let age_req = ($data | get -o policy_info.age.age-requirement | default "?")

    let verdict_display = (format-verdict $verdict)

    let age_dur = if ($age | describe) == "string" { $age } else { (days-to-duration $age) }
    let age_req_dur = if ($age_req | describe) == "string" { $age_req } else if $age_req == 0 { "none" } else { (days-to-duration $age_req) | into string }

    let vd = (version-delta $old_ver $new_ver)
    let pkg_link = (lp-source-link $pkg)
    let old_link = (lp-source-link $pkg --version $old_ver --display $vd.old)
    let new_link = (lp-source-link $pkg --version $new_ver --display $vd.new)
    print -e $"(ansi attr_bold)($pkg_link)(ansi reset): ($old_link) → ($new_link)"
    print -e $"Status: ($verdict_display) | Age: ($age_dur) \(required: ($age_req_dur)\)"

    # Show dependency info when present
    let blocked_by = ($data | get -o dependencies.blocked-by | default [])
    let migrate_after = ($data | get -o dependencies.migrate-after | default [])
    if not ($blocked_by | is-empty) {
        let links = ($blocked_by | each {|p| lp-source-link $p --display $"(ansi red)($p)(ansi reset)" } | str join " ")
        print -e $"Blocked by: ($links)"
    }
    if not ($migrate_after | is-empty) {
        let links = ($migrate_after | each {|p| lp-source-link $p --display $"(ansi yellow)($p)(ansi reset)" } | str join " ")
        print -e $"Migrate after: ($links)"
    }

    # Show component mismatches (compacted by architecture)
    let mismatches = ($data | get -o excuses | default [] | where {|e| $e =~ "cannot depend"})
    if not ($mismatches | is-empty) {
        let parsed = ($mismatches | each {|line|
            let parts = ($line | parse "{pkg}/{arch} in {src} cannot depend on {dep} in {dest}")
            if ($parts | is-empty) { null } else { $parts | first }
        } | where {|r| $r != null})
        if not ($parsed | is-empty) {
            let grouped = ($parsed | group-by {|r| $"($r.pkg) in ($r.src) → ($r.dep) in ($r.dest)"})
            print -e $"(ansi red)Component mismatches:(ansi reset)"
            $grouped | transpose key rows | each {|g|
                let arches = ($g.rows | get arch | uniq | str join ", ")
                let r = ($g.rows | first)
                print -e $"  ($r.pkg)/{($arches)} in ($r.src) → ($r.dep) in ($r.dest)"
            } | ignore
        }
    }

    # Show dependency problems: unsatisfiable install-deps and arches where the
    # package is uninstallable (so autopkgtest never ran there).
    let dep_issues = (parse-dependency-issues ($data | get -o excuses | default []))
    if ($dep_issues.unsat | is-not-empty) {
        let grouped = ($dep_issues.unsat | group-by pkg)
        print -e $"(ansi red)Unsatisfiable dependencies:(ansi reset)"
        $grouped | transpose pkg rows | each {|g|
            let arches = ($g.rows | get arch | uniq | str join ", ")
            print -e $"  ($g.pkg)/{($arches)}"
        } | ignore
    }
    if ($dep_issues.impossible | is-not-empty) {
        let grouped = ($dep_issues.impossible | group-by {|r| $"($r.src) → ($r.dep)"})
        print -e $"(ansi red)Impossible depends:(ansi reset)"
        $grouped | transpose key rows | each {|g|
            let arches = ($g.rows | get arch | uniq | str join ", ")
            let r = ($g.rows | first)
            print -e $"  ($r.src) → ($r.dep)/($r.ver)/{($arches)}"
        } | ignore
    }
    if ($dep_issues.uninstallable | is-not-empty) {
        let arches = ($dep_issues.uninstallable | uniq | str join ", ")
        print -e $"(ansi yellow)Uninstallable \(no autopkgtest\):(ansi reset) ($arches)"
    }

    # Show missing builds
    let missing_builds = ($data | get -o missing-builds | default {})
    let missing_arches = ($missing_builds | get -o on-architectures | default [])
    if not ($missing_arches | is-empty) {
        print -e $"(ansi red)Missing builds:(ansi reset) ($missing_arches | str join ', ')"
    }
    let missing_unimportant = ($missing_builds | get -o on-unimportant-architectures | default [])
    if not ($missing_unimportant | is-empty) {
        print -e $"(ansi dark_gray)Missing builds \(unimportant\):(ansi reset) ($missing_unimportant | str join ', ')"
    }

    # Show old binaries (NBS cruft)
    let old_bins = ($data | get -o old-binaries | default {})
    if not ($old_bins | is-empty) and ($old_bins | describe | str starts-with "record") {
        let nbs_entries = ($old_bins | transpose ver bins | each {|entry|
            let names = if ($entry.bins | length) > 3 {
                let remaining = ($entry.bins | length) - 3
                $"($entry.bins | first 3 | str join ', ') + ($remaining) more"
            } else {
                $entry.bins | str join ", "
            }
            $"($names) \(from ($entry.ver)\)"
        })
        print -e $"(ansi yellow)Old binaries \(NBS\):(ansi reset) ($nbs_entries | str join '; ')"
    }

    # Show block bugs (when verdict is not PASS)
    let block_bugs = ($data | get -o policy_info.block-bugs | default {})
    if not ($block_bugs | is-empty) and ($block_bugs | describe | str starts-with "record") {
        let bb_verdict = ($block_bugs | get -o verdict | default "PASS")
        if $bb_verdict != "PASS" {
            let bug_ids = ($block_bugs | reject -o verdict | columns)
            let bug_display = ($bug_ids | each {|id|
                lp-bug-link ($id | into int) --color (ansi red)
            } | str join " ")
            let reason = match $bb_verdict {
                "REJECTED_PERMANENTLY" => "permanently blocked"
                _ => $bb_verdict
            }
            print -e $"(ansi red)Block bugs:(ansi reset) ($bug_display) \(($reason)\)"
        }
    }

    # Show hints (manual blocks)
    let hints_list = ($data | get -o hints | default [])
    if not ($hints_list | is-empty) {
        let hint_display = ($hints_list | each {|h|
            $"($h.hint-type) by ($h.hint-from)"
        } | str join ", ")
        print -e $"(ansi magenta)Hints:(ansi reset) ($hint_display)"
    }

    # Show new binaries (from detailed-info)
    let detailed = ($data | get -o detailed-info | default [])
    let new_bins = ($detailed | where {|d| $d =~ "^New binary:"} | each {|d| $d | str replace "New binary: " ""})
    if not ($new_bins | is-empty) {
        print -e $"(ansi green)New binaries:(ansi reset) ($new_bins | str join ', ')"
    }

    print -e ""
}

# `my-excuses` (now `my excuses`) lives in my.nu — see that module.

# Show the largest co-migration clusters currently blocking proposed migration.
# Each row is a group of packages that must all migrate together (linked by
# migrate-after dependencies). Useful for identifying active transitions.
# The `waiting_for` column is a full list — pipe for detail:
#   excuses-clusters | first | get waiting_for
export def excuses-clusters [
    --series (-s): string = $DEVEL_RELEASE  # Ubuntu series
    --limit (-n): int = 5                   # Maximum number of clusters to show
]: nothing -> table<package: string, size: int, waiting_for: list<string>> {
    let sources = with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series | get sources }

    # Build {package, waiting_for} for every entry that has migrate-after deps
    let with_deps = (
        $sources
        | each {|row|
            let after = ($row | get -o dependencies.migrate-after | default [])
            if ($after | is-empty) { null } else {
                { package: $row.source, waiting_for: $after }
            }
        }
        | where { $in != null }
        | sort-by { $in.waiting_for | length } --reverse
    )

    # Walk sorted entries, deduplicating: packages already absorbed into a larger
    # cluster are skipped (but their deps are still added to `seen`).
    # Stop when cluster size drops below 3 or we've emitted `limit` clusters.
    mut seen: list<string> = []
    mut results: list<record> = []

    for entry in $with_deps {
        if $entry.package in $seen {
            $seen = ($seen | append $entry.waiting_for)
            continue
        }
        let sz = ($entry.waiting_for | length)
        if $sz < 3 { break }
        if ($results | length) >= $limit { break }

        let excuses_url = $"https://ubuntu-archive-team.ubuntu.com/proposed-migration/update_excuses.html#($entry.package)"
        $results = ($results | append {
            package:     (osc8-link $excuses_url $entry.package)
            size:        $sz
            waiting_for: $entry.waiting_for
        })
        $seen = ($seen | append $entry.waiting_for)
    }

    $results
}
