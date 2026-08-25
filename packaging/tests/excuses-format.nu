# Presentation + classification helpers for proposed-migration (excuses) data.
# Pure projections from excuses/autopkgtest records to display text, plus the
# autopkgtest status taxonomy and the cross-package row builder. Shared by the
# `excuses` command (migration.nu) and the `my excuses` lens (my.nu).

use log-parsing.nu [classify-log-url, format-subtest]
use ../../formatting.nu [osc8-link, lp-source-spec-link]

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
# infrastructure / install / harness failure). Used by my excuses --failing.
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
        let base = { package: (lp-source-spec-link $row.pkg) }
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

# Parse the free-text `excuses` lines britney emits for dependency problems
# into compact display groups. Three shapes are recognised:
#   "<bin>/<arch> has unsatisfiable dependency"
#   "uninstallable on arch <arch>, not running autopkgtest there"
#   "Impossible Depends: <src> -> <dep>/<ver>/<arch>"
# Returns a record { unsat: list<record>, uninstallable: list<arch>,
# impossible: list<record> } — all empty when no such lines exist.
export def parse-dependency-issues [lines: list<string>]: nothing -> record {
    let unsat = ($lines | each {|l|
        let p = ($l | parse "{pkg}/{arch} has unsatisfiable dependency")
        if ($p | is-empty) { null } else { $p | first }
    } | where { $in != null })
    let uninstallable = ($lines | each {|l|
        let p = ($l | parse "uninstallable on arch {arch}, not running autopkgtest there")
        if ($p | is-empty) { null } else { $p | first | get arch }
    } | where { $in != null })
    let impossible = ($lines | each {|l|
        let p = ($l | parse "Impossible Depends: {src} -> {dep}/{ver}/{arch}")
        if ($p | is-empty) { null } else { $p | first }
    } | where { $in != null })
    { unsat: $unsat, uninstallable: $uninstallable, impossible: $impossible }
}

# Map a migration-policy verdict to a colored display label.
# Default: verbose form for the `excuses` header ("Migrating",
# "Blocked (permanent)", ...). `--compact`: short form for the `my excuses`
# summary table ("migrating", "blocked", "tmp-block", ...).
export def format-verdict [verdict: string, --compact]: nothing -> string {
    if $compact {
        match $verdict {
            "PASS" => $"(ansi green)migrating(ansi reset)"
            "REJECTED_PERMANENTLY" => $"(ansi red)blocked(ansi reset)"
            "REJECTED_TEMPORARILY" => $"(ansi yellow)tmp-block(ansi reset)"
            "REJECTED_CANNOT_DETERMINE_IF_PERMANENT" => $"(ansi yellow)investigating(ansi reset)"
            "REJECTED_BLOCKED_BY_ANOTHER_ITEM" => $"(ansi magenta)dep-block(ansi reset)"
            "REJECTED_WAITING_FOR_ANOTHER_ITEM" => $"(ansi cyan)dep-wait(ansi reset)"
            _ => $verdict
        }
    } else {
        match $verdict {
            "PASS" => $"(ansi green)Migrating(ansi reset)"
            "REJECTED_PERMANENTLY" => $"(ansi red)Blocked \(permanent\)(ansi reset)"
            "REJECTED_TEMPORARILY" => $"(ansi yellow)Blocked \(temporary\)(ansi reset)"
            "REJECTED_CANNOT_DETERMINE_IF_PERMANENT" => $"(ansi yellow)Blocked \(investigating\)(ansi reset)"
            "REJECTED_BLOCKED_BY_ANOTHER_ITEM" => $"(ansi magenta)Blocked by dependency(ansi reset)"
            "REJECTED_WAITING_FOR_ANOTHER_ITEM" => $"(ansi cyan)Waiting on dependency(ansi reset)"
            _ => $verdict
        }
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
    let dep_issues = (parse-dependency-issues ($entry | get -o excuses | default []))
    if ($dep_issues.unsat | is-not-empty) {
        let arches = ($dep_issues.unsat | get arch | uniq | str join ',')
        $parts = ($parts | append $"unsat-deps: ($arches)")
    } else if ($dep_issues.uninstallable | is-not-empty) {
        $parts = ($parts | append $"uninstallable: ($dep_issues.uninstallable | uniq | str join ',')")
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
