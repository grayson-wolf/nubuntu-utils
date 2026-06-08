# Proposed-migration (excuses) tooling: fetching, displaying, and clustering.

use ../meta.nu [pkg-name]
use ../../completions.nu [pkg-completions]
use ../../formatting.nu [osc8-link, lp-bug-link, days-to-duration]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]

const EXCUSES_URL = "https://ubuntu-archive-team.ubuntu.com/proposed-migration"

# Download and parse the full excuses YAML for a series.
# Returns the `sources` table from the parsed YAML.
export def fetch-excuses [series: string]: nothing -> table {
    let url = $"($EXCUSES_URL)/($series)/update_excuses.yaml.xz"
    curl -s $url | xz -d | from yaml | get sources
}

# Format an autopkgtest status with color and OSC8 hyperlink.
def format-status [status: string, log_url: string]: nothing -> string {
    let display = match $status {
        "PASS" => "Pass"
        "OLD_PASS" => "Pass°"
        "REGRESSION" => "Regr ♻"
        "RUNNING" => "Run..."
        "RUNNING-ALWAYSFAIL" => "Run*"
        "RUNNING-REFERENCE" => "Run°"
        "ALWAYSFAIL" => "Fail*"
        "NEUTRAL" => "—"
        "OLD_NEUTRAL" => "—°"
        "IGNORE-FAIL" => "Ign"
        _ => $status
    }
    let colored = match $status {
        "PASS" | "OLD_PASS" => $"(ansi green)($display)(ansi reset)"
        "REGRESSION" => $"(ansi red)($display)(ansi reset)"
        "RUNNING" | "RUNNING-ALWAYSFAIL" | "RUNNING-REFERENCE" => $"(ansi yellow)($display)(ansi reset)"
        "ALWAYSFAIL" | "NEUTRAL" | "OLD_NEUTRAL" | "IGNORE-FAIL" => $"(ansi dark_gray)($display)(ansi reset)"
        _ => $display
    }
    let link_url = if $log_url == "https://autopkgtest.ubuntu.com/running" { "" } else { $log_url }
    osc8-link $link_url $colored
}

# Statuses that indicate a problem or potential problem requiring attention.
const ACTIONABLE_STATUSES = ["REGRESSION", "RUNNING", "RUNNING-ALWAYSFAIL", "RUNNING-REFERENCE"]

# Show proposed-migration (excuses) status for a package.
# By default, only shows packages with regressions or in-progress tests.
# Prints metadata to stderr; returns the autopkgtest results as a table for pipelines.
export def excuses [
    package?: string@pkg-completions                   # Package name (defaults to cwd package)
    --series (-s): string = $DEVEL_RELEASE             # Ubuntu series
    --raw (-r)                                         # Output raw parsed YAML record
    --all (-a)                                         # Show all test results, not just actionable ones
    --why (-w)                                         # Show blocking dependencies' test results
]: nothing -> table {
    let pkg = $package | default (pkg-name)

    let sources = fetch-excuses $series

    let matches = ($sources | where source == $pkg)

    if ($matches | is-empty) {
        error make { msg: $"Package '($pkg)' not found in ($series) excuses." }
    }

    let data = ($matches | first)

    if $raw {
        return $data
    }

    # Print metadata to stderr so table output is clean for pipelines
    let old_ver = ($data | get old-version)
    let new_ver = ($data | get new-version)
    let verdict = ($data | get migration-policy-verdict)
    let age = ($data | get -o policy_info.age.current-age | default "?")
    let age_req = ($data | get -o policy_info.age.age-requirement | default "?")

    let verdict_display = match $verdict {
        "PASS" => $"(ansi green)Migrating(ansi reset)"
        "REJECTED_PERMANENTLY" => $"(ansi red)Blocked \(permanent\)(ansi reset)"
        "REJECTED_TEMPORARILY" => $"(ansi yellow)Blocked \(temporary\)(ansi reset)"
        "REJECTED_CANNOT_DETERMINE_IF_PERMANENT" => $"(ansi yellow)Blocked \(investigating\)(ansi reset)"
        "REJECTED_BLOCKED_BY_ANOTHER_ITEM" => $"(ansi magenta)Blocked by dependency(ansi reset)"
        "REJECTED_WAITING_FOR_ANOTHER_ITEM" => $"(ansi cyan)Waiting on dependency(ansi reset)"
        _ => $verdict
    }

    let age_dur = if ($age | describe) == "string" { $age } else { (days-to-duration $age) }
    let age_req_dur = if ($age_req | describe) == "string" { $age_req } else if $age_req == 0 { "none" } else { (days-to-duration $age_req) | into string }

    print -e $"(ansi attr_bold)($pkg)(ansi reset): ($old_ver) → ($new_ver)"
    print -e $"Status: ($verdict_display) | Age: ($age_dur) \(required: ($age_req_dur)\)"

    # Show dependency info when present
    let blocked_by = ($data | get -o dependencies.blocked-by | default [])
    let migrate_after = ($data | get -o dependencies.migrate-after | default [])
    if not ($blocked_by | is-empty) {
        print -e $"Blocked by: (ansi red)($blocked_by | str join ', ')(ansi reset)"
    }
    if not ($migrate_after | is-empty) {
        print -e $"Migrate after: (ansi yellow)($migrate_after | str join ', ')(ansi reset)"
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
            } | str join ", ")
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

    # --why mode: show combined test table for all blocking dependencies
    if $why {
        let dep_pkgs = ($blocked_by | append $migrate_after)
        if ($dep_pkgs | is-empty) {
            print -e "No blocking dependencies to investigate."
            return []
        }
        let all_rows = ($dep_pkgs | each {|dep_pkg|
            let dep_data = ($sources | where source == $dep_pkg)
            if ($dep_data | is-empty) { return [] }
            let dep_entry = ($dep_data | first)
            let autopkgtest = ($dep_entry | get -o policy_info.autopkgtest | default {})
            if ($autopkgtest | is-empty) { return [] }
            let tests = ($autopkgtest | reject -o verdict | transpose pkg archinfo)
            let tests = if $all { $tests } else {
                $tests | where {|row|
                    $row.archinfo | values | any {|info|
                        let status = ($info | get 0 | default "")
                        $status in $ACTIONABLE_STATUSES
                    }
                }
            }
            $tests | each {|row|
                { blocker: $dep_pkg, pkg: $row.pkg, archinfo: $row.archinfo }
            }
        } | flatten)

        if ($all_rows | is-empty) {
            print -e "\(no actionable test results in blocking dependencies\)"
            return []
        }

        let all_arches = ($all_rows | get archinfo | each { columns } | flatten | uniq | sort)
        let rows = ($all_rows | each {|row|
            let base = { blocker: $row.blocker, package: $row.pkg }
            $all_arches | reduce --fold $base {|arch, acc|
                let info = ($row.archinfo | get -o $arch)
                let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
                let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
                let cell = if ($status | is-empty) { "" } else { format-status $status $log_url }
                $acc | insert $arch $cell
            }
        })
        return $rows
    }

    # Build the test results table for the package itself
    let autopkgtest = ($data | get -o policy_info.autopkgtest)
    if ($autopkgtest | is-empty) {
        print -e "No autopkgtest data available."
        return []
    }

    let tests = ($autopkgtest | reject -o verdict | transpose pkg archinfo)

    # Filter to only actionable rows unless --all is set
    let tests = if $all {
        $tests
    } else {
        $tests | where {|row|
            $row.archinfo | values | any {|info|
                let status = ($info | get 0 | default "")
                $status in $ACTIONABLE_STATUSES
            }
        }
    }

    if ($tests | is-empty) {
        print -e "\(no actionable test results — use -a to show all\)"
        return []
    }

    # Collect all architectures
    let all_arches = ($tests | get archinfo | each { columns } | flatten | uniq | sort)

    # Build table rows
    let rows = ($tests | each {|row|
        let base = { package: $row.pkg }
        $all_arches | reduce --fold $base {|arch, acc|
            let info = ($row.archinfo | get -o $arch)
            let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
            let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
            let cell = if ($status | is-empty) {
                ""
            } else {
                format-status $status $log_url
            }
            $acc | insert $arch $cell
        }
    })

    $rows
}

# Show the largest co-migration clusters currently blocking proposed migration.
# Each row is a group of packages that must all migrate together (linked by
# migrate-after dependencies). Useful for identifying active transitions.
# The `waiting_for` column is a full list — pipe for detail:
#   excuses-clusters | first | get waiting_for
export def excuses-clusters [
    --series (-s): string = $DEVEL_RELEASE  # Ubuntu series
    --limit (-n): int = 5                   # Maximum number of clusters to show
]: nothing -> table<package: string, size: int, waiting_for: list<string>> {
    let sources = fetch-excuses $series

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
