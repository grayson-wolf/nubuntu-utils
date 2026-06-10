# Proposed-migration (excuses) tooling: fetching, displaying, and clustering.

use ../meta.nu [pkg-name]
use ../launchpad.nu [uploader-data]
use ../../completions.nu [pkg-completions]
use ../../formatting.nu [osc8-link, lp-bug-link, days-to-duration, with-spinner, version-delta]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]
use log-parsing.nu [classify-log-url, format-subtest]

const EXCUSES_URL = "https://ubuntu-archive-team.ubuntu.com/proposed-migration"

# Download and parse the full excuses YAML for a series.
# Returns the `sources` table from the parsed YAML.
export def fetch-excuses [series: string]: nothing -> table {
    let url = $"($EXCUSES_URL)/($series)/update_excuses.yaml.xz"
    curl -s $url | xz -d | from yaml | get sources
}

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
const REAL_FAIL_REFINED = ["FAIL", "FAIL_STDERR", "FAIL_TIMEOUT", "BROKEN"]

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
    --dependencies (-d)                                # Show blocking dependencies' test results
]: nothing -> table {
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

    # --dependencies mode: show combined test table for all blocking dependencies
    if $dependencies {
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

        # If --why, collect every refinable cell's log URL and fetch in parallel.
        let refinement = if $why {
            let urls = ($all_rows | each {|row|
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

        let rows = ($all_rows | each {|row|
            let base = { blocker: $row.blocker, package: $row.pkg }
            $all_arches | reduce --fold $base {|arch, acc|
                let info = ($row.archinfo | get -o $arch)
                let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
                let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
                let refined = if ($why and ($log_url | is-not-empty)) {
                    $refinement | get -o $log_url | default ""
                } else { "" }
                let cell = if ($status | is-empty) { "" } else { format-status $status $log_url $refined }
                $acc | insert $arch $cell
            }
        })
        return $rows
    }

    # Build the test results table for the package itself
    let rows = (build-autopkgtest-rows ($data | get -o policy_info.autopkgtest | default {}) $all $why [])
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
def build-autopkgtest-rows [
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
def format-verdict-compact [verdict: string]: nothing -> string {
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
def classify-role [signer: any, creator: any, me: string]: nothing -> any {
    let s_match = (($signer | is-not-empty) and ($signer == $me))
    let c_match = (($creator | is-not-empty) and ($creator == $me))
    if $s_match and $c_match { return "uploaded" }
    if $s_match { return "sponsored" }
    if $c_match { return "sponsored-by" }
    null
}

def format-role [role: string]: nothing -> string {
    match $role {
        "uploaded" => $"(ansi cyan)uploaded(ansi reset)"
        "sponsored" => $"(ansi magenta)sponsored(ansi reset)"
        "sponsored-by" => $"(ansi yellow)sponsored-by(ansi reset)"
        _ => $role
    }
}

# Short human summary of the most relevant blocker(s) for an excuses entry.
def summarize-issues [entry: record]: nothing -> string {
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

# Show proposed-migration excuses for every package YOU uploaded, sponsored,
# or had sponsored. Cross-references the excuses YAML with LP publication
# history (cached) to identify your packages by `package_signer_link` /
# `package_creator_link` matching $env.LAUNCHPAD_NAME (or --user).
#
# Default output: summary table (source, version, role, verdict, issues).
# --detailed: also render the full per-package excuses output for each match.
# --raw: structured records with `role` and `uploader_data` columns added.
export def my-excuses [
    --series (-s): string = $DEVEL_RELEASE  # Ubuntu series
    --user (-u): string = ""                # LP username (default: $env.LAUNCHPAD_NAME)
    --detailed (-D)                         # Also render full per-package excuses output
    --why (-w)                              # Refine REGRESSION cells with log-derived failure mode (only with --detailed)
    --failing (-f)                          # Only rows with a real test regression (implies -D and -w)
    --limit (-n): int = 0                   # Cap on excuses sources to query (0 = all). Useful for testing.
    --raw (-r)                              # Return structured records
]: nothing -> any {
    # --failing implies --detailed and --why
    let detailed = ($detailed or $failing)
    let why = ($why or $failing)

    let me = if ($user | is-empty) { $env.LAUNCHPAD_NAME? | default "" } else { $user }
    if ($me | is-empty) {
        error make { msg: "No user — pass --user or set $env.LAUNCHPAD_NAME" }
    }

    let all_sources = (with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series })
    let sources = if $limit > 0 { $all_sources | first $limit } else { $all_sources }
    let n = ($sources | length)

    let candidates = (with-spinner $"Querying LP uploader data for ($n) sources..." {
        $sources | par-each --threads 16 {|src|
            let v = ($src | get -o new-version | default "-")
            if $v == "-" { return null }
            let ud = (uploader-data $src.source $v)
            if ($ud | is-empty) { return null }
            let role = (classify-role $ud.signer $ud.creator $me)
            if ($role | is-empty) { return null }
            $src | insert role $role | insert uploader_data $ud
        } | where { $in != null }
    })

    if ($candidates | is-empty) {
        print -e $"(ansi yellow)No matching packages for ($me) in ($series).(ansi reset)"
        return
    }

    if $raw {
        return $candidates
    }

    let summary = ($candidates | each {|c|
        {
            source: $c.source
            "new-version": ($c | get -o new-version)
            role: (format-role $c.role)
            verdict: (format-verdict-compact ($c | get migration-policy-verdict))
            issues: (summarize-issues $c)
        }
    })

    print -e $"(ansi attr_bold)my-excuses(ansi reset) — (ansi cyan)($candidates | length)(ansi reset) packages for (ansi cyan)($me)(ansi reset) in (ansi yellow)($series)(ansi reset)"

    if not $detailed {
        return $summary
    }

    # Detailed: print summary table to stderr, return one unified autopkgtest
    # table with a `blocked-package` column at the front.
    print -e ($summary | table --expand)
    print -e ""

    let global_arches = ($candidates | each {|c|
        let at = ($c | get -o policy_info.autopkgtest | default {})
        if ($at | is-empty) { [] } else {
            $at | reject -o verdict | values | each { columns } | flatten | uniq
        }
    } | flatten | uniq | sort)

    let unified = ($candidates | each {|c|
        let at = ($c | get -o policy_info.autopkgtest | default {})
        let rows = (build-autopkgtest-rows $at false $why $global_arches $failing)
        $rows | each {|r| { "blocked-package": $c.source } | merge $r }
    } | flatten)

    $unified
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
