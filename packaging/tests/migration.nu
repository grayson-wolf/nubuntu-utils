# Proposed-migration (excuses) tooling: fetching, displaying, and clustering.

use ../meta.nu [pkg-name]
use ../launchpad.nu [uploader-data]
use ../navigation.nu [poc]
use ../../completions.nu [pkg-completions, release-completions]
use ../../formatting.nu [osc8-link, lp-bug-link, days-to-duration, with-spinner, version-delta]
use ../../ubuntu-versions.nu [DEVEL_RELEASE, ARCHES]
use log-parsing.nu [classify-log-url, format-subtest]
use fetch.nu [fetch-excuses]
use autopkgtest.nu [autopkgtest-cookie, select-and-submit]

# Format an autopkgtest status with color and OSC8 hyperlink.
# If `refined` is non-empty and the britney status is a failure-bearing one
# (REGRESSION), the refined classification from the log is used
# instead (Deps, Timeout, Stderr, Broken, Temp Fail, etc.). When britney says
# REGRESSION but the log parses as PASS the refined value is shown with a `?`
# suffix to flag the inconsistency.
def format-status [status: string, log_url: string, refined: string = ""]: nothing -> string {
    let coarse_display = match $status {
        "PASS" => "Pass"
        "OLD_PASS" => "Pass°"
        "REGRESSION" => "Regr"
        "RUNNING" => "Run..."
        "RUNNING-ALWAYSFAIL" => "Run*"
        "RUNNING-REFERENCE" => "Run°"
        "ALWAYSFAIL" => "Fail*"
        "NEUTRAL" => "—"
        "OLD_NEUTRAL" => "—°"
        "IGNORE-FAIL" => "Ign"
        _ => $status
    }
    let use_refined = (
        ($refined | is-not-empty)
        and ($status in ["REGRESSION", "ALWAYSFAIL"])
    )
    let body = if $use_refined {
        if ($status == "REGRESSION") and ($refined == "PASS") {
            $"(ansi yellow_bold)Regr?(ansi reset)"
        } else {
            format-subtest $refined
        }
    } else {
        let coarse_colored = match $status {
            "PASS" | "OLD_PASS" => $"(ansi green)($coarse_display)(ansi reset)"
            "REGRESSION" => $"(ansi red)($coarse_display)(ansi reset)"
            "RUNNING" | "RUNNING-ALWAYSFAIL" | "RUNNING-REFERENCE" => $"(ansi yellow)($coarse_display)(ansi reset)"
            "ALWAYSFAIL" | "NEUTRAL" | "OLD_NEUTRAL" | "IGNORE-FAIL" => $"(ansi dark_gray)($coarse_display)(ansi reset)"
            _ => $coarse_display
        }
        $coarse_colored
    }
    let link_url = if $log_url == "https://autopkgtest.ubuntu.com/running" { "" } else { $log_url }
    osc8-link $link_url $body
}

# Statuses for which we'd want to fetch the log and refine the classification.
const REFINABLE_STATUSES = ["REGRESSION"]

# Refined log-derived statuses that count as a real test regression (not
# infrastructure / install / harness failure). Used by my-excuses --failing.
export const REAL_FAIL_REFINED = ["FAIL", "FAIL_STDERR", "FAIL_TIMEOUT", "BROKEN"]

# Given a list of unique log URLs, fetch and classify each in parallel.
# Returns a record { <url>: <overall_status> }.
def build-refinement-map [log_urls: list<string>]: nothing -> record {
    let urls = ($log_urls | where { $in | is-not-empty } | uniq)
    if ($urls | is-empty) { return {} }
    let pairs = ($urls | par-each {|u| { url: $u, overall: (classify-log-url $u) } })
    $pairs | reduce --fold {} {|p, acc| $acc | insert $p.url $p.overall }
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
    --why (-w)                                         # Refine REGRESSION cells with log-derived failure mode (real-fail / timeout / tmpfail / badpkg / broken)
    --failing (-f)                                     # Only rows with a real test regression (implies -w)
    --dependencies (-d)                                # Show blocking dependencies' test results
]: nothing -> table {
    # --failing implies --why
    let why = ($why or $failing)

    let pkg = $package | default (pkg-name)

    let sources = with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series }

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

    let vd = (version-delta $old_ver $new_ver)
    print -e $"(ansi attr_bold)($pkg)(ansi reset): ($vd.old) → ($vd.new)"
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

    # --dependencies mode: show the package's own test results, then the
    # combined test table for all blocking dependencies. Direct failures
    # come first (with blocker = the package itself).
    if $dependencies {
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

# Build a table of rows (one per blocking package) for an autopkgtest dict
# (the `policy_info.autopkgtest` substructure of an excuses entry).
# Columns: `package`, then one per architecture.
# Returns [] when there's no data or no actionable rows.
#
# - `all`: include non-actionable status rows
# - `delineate`: refine REGRESSION cells via log fetch
# - `arches_override`: if non-empty, use these arch columns instead of the
#   per-package union — useful for cross-package unified rendering.
export def build-autopkgtest-rows [
    autopkgtest: record
    all: bool = false
    delineate: bool = false
    arches_override: list<string> = []
    failing: bool = false  # drop rows with no real-fail arch (requires delineate)
]: nothing -> any {
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
    if ($tests | is-empty) { return [] }
    let all_arches = if ($arches_override | is-empty) {
        $tests | get archinfo | each { columns } | flatten | uniq | sort
    } else { $arches_override }

    let refinement = if $delineate {
        let urls = ($tests | each {|row|
            $all_arches | each {|arch|
                let info = ($row.archinfo | get -o $arch)
                if ($info | is-not-empty) {
                    let status = ($info | get 0 | default "")
                    let log_url = ($info | get 1 | default "")
                    if ($status in $REFINABLE_STATUSES) { $log_url } else { null }
                } else { null }
            }
        } | flatten | where { $in != null })
        build-refinement-map $urls
    } else { {} }

    # Filter on raw data before rendering: a row qualifies iff some arch has
    # a REGRESSION whose refined log classification is a real test failure.
    let tests = if $failing {
        $tests | where {|row|
            $all_arches | any {|arch|
                let info = ($row.archinfo | get -o $arch)
                if ($info | is-empty) { false } else {
                    let status = ($info | get 0 | default "")
                    let log_url = ($info | get 1 | default "")
                    if $status != "REGRESSION" or ($log_url | is-empty) { false } else {
                        ($refinement | get -o $log_url | default "") in $REAL_FAIL_REFINED
                    }
                }
            }
        }
    } else { $tests }

    $tests | each {|row|
        let base = { package: $row.pkg }
        $all_arches | reduce --fold $base {|arch, acc|
            let info = ($row.archinfo | get -o $arch)
            let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
            let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
            let refined = if ($delineate and ($log_url | is-not-empty)) {
                $refinement | get -o $log_url | default ""
            } else { "" }
            let cell = if ($status | is-empty) { "" } else {
                format-status $status $log_url $refined
            }
            $acc | insert $arch $cell
        }
    }
}

# Compact verdict mapping for the my-excuses summary table.
export def format-verdict-compact [verdict: string]: nothing -> string {
    match $verdict {
        "PASS" => $"(ansi green)migrating(ansi reset)"
        "REJECTED_PERMANENTLY" => $"(ansi red)blocked(ansi reset)"
        "REJECTED_TEMPORARILY" => $"(ansi yellow)tmp-block(ansi reset)"
        "REJECTED_CANNOT_DETERMINE_IF_PERMANENT" => $"(ansi yellow)investigating(ansi reset)"
        "REJECTED_BLOCKED_BY_ANOTHER_ITEM" => $"(ansi magenta)dep-block(ansi reset)"
        "REJECTED_WAITING_FOR_ANOTHER_ITEM" => $"(ansi cyan)dep-wait(ansi reset)"
        _ => $verdict
    }
}

# Classify the relationship between the current user and an upload.
# Returns "uploaded" | "sponsored" | "sponsored-by" | null.
export def classify-role [signer: any, creator: any, me: string]: nothing -> any {
    let s_match = (($signer | is-not-empty) and ($signer == $me))
    let c_match = (($creator | is-not-empty) and ($creator == $me))
    if $s_match and $c_match { return "uploaded" }
    if $s_match { return "sponsored" }
    if $c_match { return "sponsored-by" }
    null
}

export def format-role [role: string]: nothing -> string {
    match $role {
        "uploaded" => $"(ansi cyan)uploaded(ansi reset)"
        "sponsored" => $"(ansi magenta)sponsored(ansi reset)"
        "sponsored-by" => $"(ansi yellow)sponsored-by(ansi reset)"
        "watched" => $"(ansi red)watched(ansi reset)"
        _ => $role
    }
}

# Short human summary of the most relevant blocker(s) for an excuses entry.
export def summarize-issues [entry: record]: nothing -> string {
    mut parts = []
    let missing = ($entry | get -o missing-builds.on-architectures | default [])
    if ($missing | is-not-empty) {
        $parts = ($parts | append $"missing-builds: ($missing | str join ',')")
    }
    let blocked_by = ($entry | get -o dependencies.blocked-by | default [])
    if ($blocked_by | is-not-empty) {
        $parts = ($parts | append $"blocked-by: ($blocked_by | str join ',')")
    }
    let autopkgtest = ($entry | get -o policy_info.autopkgtest | default {})
    let at_verdict = ($autopkgtest | get -o verdict | default "PASS")
    if $at_verdict != "PASS" {
        let tests = ($autopkgtest | reject -o verdict | transpose pkg archinfo)
        let regr = ($tests | each {|t|
            $t.archinfo | values | where {|info|
                let s = ($info | get 0 | default "")
                $s == "REGRESSION"
            } | length
        } | append 0 | math sum)
        if $regr > 0 {
            $parts = ($parts | append $"autopkgtest: ($regr) regr")
        } else {
            $parts = ($parts | append "autopkgtest")
        }
    }
    let block_bugs = ($entry | get -o policy_info.block-bugs | default {})
    let bb_verdict = ($block_bugs | get -o verdict | default "PASS")
    if $bb_verdict != "PASS" {
        let n = ($block_bugs | reject -o verdict | columns | length)
        $parts = ($parts | append $"block-bugs: ($n)")
    }
    let hints = ($entry | get -o hints | default [])
    if ($hints | is-not-empty) {
        $parts = ($parts | append $"hints: ($hints | length)")
    }
    if ($parts | is-empty) { "—" } else { $parts | str join "; " }
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
    let sources = with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series }

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

# Submit migration-reference/0 autopkgtests for a source package.
# Requires an autopkgtest.ubuntu.com session cookie — see `retry-regressions --help`.
export def migration-reference [
    package?: string@pkg-completions              # Source package (defaults to cwd package)
    --series (-s): string@release-completions = $DEVEL_RELEASE  # Ubuntu series
]: nothing -> nothing {
    let cookie = autopkgtest-cookie
    let pkg = if ($package | is-empty) { pkg-name } else { $package }

    # Check ownership and warn if teams are responsible for this package
    let teams = poc $pkg
    if not ($teams | is-empty) {
        let teams_display = ($teams | each {|t| $"~($t)" } | str join ", ")
        gum confirm $"($pkg) is owned by ($teams_display). Consult them before re-running migration-reference tests. Continue?"
    }

    # Build one URL per arch and submit via interactive selection
    let urls = ($ARCHES | each {|arch|
        let params = { release: $series, package: $pkg, arch: $arch, trigger: "migration-reference/0" }
        $"https://autopkgtest.ubuntu.com/request.cgi?($params | url build-query)"
    })

    select-and-submit $urls $cookie --header $"Select migration-reference tests for ($pkg) / ($series):"
}
