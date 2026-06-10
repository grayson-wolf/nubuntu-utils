# Autopkgtest log parsing + status vocabulary.
# Pure parsing utilities — no network policy of its own (callers do the
# actual fetch and pass strings in). Two narrow helpers (classify-log-url,
# fetch-and-parse-logs) do shell out via curl/gzip because the conversion
# from a log URL to a parsed log is too useful to split across modules.

export const AUTOPKGTEST_URL = "https://autopkgtest.ubuntu.com"

# Format an autopkgtest subtest status with color (no emoji).
export def format-subtest [status: string]: nothing -> string {
    let display = match $status {
        "PASS" => "Pass"
        "PASS_SUPERFICIAL" => "Pass*"
        "FAIL" => "Fail"
        "FAIL_BADPKG" => "Deps"
        "FAIL_TIMEOUT" => "Timeout"
        "FAIL_STDERR" => "Stderr"
        "FLAKY" => "Flaky"
        "SKIP" => "Skip"
        "BROKEN" => "Broken"
        "TMPFAIL" => "Temp Fail"
        "BAD" => "Bad"
        "RUNNING" => "Running"
        "WAITING" => "Queued"
        _ => $status
    }
    let colored = match $status {
        "PASS" => $"(ansi green)($display)(ansi reset)"
        "PASS_SUPERFICIAL" => $"(ansi green_dimmed)($display)(ansi reset)"
        "FAIL" | "BROKEN" | "FAIL_TIMEOUT" | "FAIL_STDERR" => $"(ansi red)($display)(ansi reset)"
        "FAIL_BADPKG" => $"(ansi light_red)($display)(ansi reset)"
        "FLAKY" | "SKIP" | "TMPFAIL" => $"(ansi yellow)($display)(ansi reset)"
        "BAD" => $"(ansi dark_gray)($display)(ansi reset)"
        "RUNNING" => $"(ansi cyan)($display)(ansi reset)"
        "WAITING" => $"(ansi blue)($display)(ansi reset)"
        _ => $display
    }
    $colored
}

# Detect whether a log corresponds to a base or proposed-pocket run.
def detect-kind [log: string]: nothing -> string {
    if (($log | str contains "all-proposed") or ($log | str contains "apt-pocket=proposed")) {
        "proposed"
    } else { "base" }
}

# Source-package archive-pool prefix (matches Debian pool convention:
# "libX..." → "libx", else first letter).
export def package-prefix [package: string]: nothing -> string {
    if ($package | str starts-with "lib") {
        $package | str substring 0..3
    } else {
        $package | str substring 0..0
    }
}

# Parse a decompressed autopkgtest log into status + subtests + kind.
# Returns {kind: "base"|"proposed", overall: string, subtests: list<{name, status}>}
export def parse-autopkgtest-log [log: string]: nothing -> record {
    if ($log | is-empty) {
        return { kind: "base", overall: "BAD", subtests: [] }
    }
    let summary_split = ($log | split row "@@@@@@@@@@@@@@@@@@@@ summary")
    if ($summary_split | length) < 2 {
        # No summary section means run_tests() never completed → infrastructure failure
        # (testbed bomb, network error, exception during setup, etc.)
        return { kind: (detect-kind $log), overall: "TMPFAIL", subtests: [] }
    }
    let summary = ($summary_split | last)

    # Parse subtest lines. Format: "<name>   <STATUS>[ <reason>...]"
    # (possibly prefixed by "<n>s "). Statuses: PASS, PASS (superficial),
    # FAIL, FLAKY, SKIP, BROKEN.
    let subtests = (
        $summary
        | lines
        | each {|line|
            let l = ($line | str trim)
            # Strip "<n>s " timestamp prefix if present
            let stripped = if ($l | parse -r '^\d+s\s+(?P<rest>.+)$' | is-not-empty) {
                $l | parse -r '^\d+s\s+(?P<rest>.+)$' | get rest.0
            } else { $l }
            # Match "PASS (superficial)" first, then generic statuses with optional trailing text
            let superficial = ($stripped | parse -r '^(?P<name>\S.*?)\s+PASS\s+\(superficial\)\s*$')
            if ($superficial | is-not-empty) {
                { name: ($superficial | first | get name), status: "PASS_SUPERFICIAL" }
            } else {
                let parts = ($stripped | parse -r '^(?P<name>\S.*?)\s+(?P<status>PASS|FAIL|FLAKY|SKIP|BROKEN)(?:\s+(?P<reason>.*))?$')
                if ($parts | is-empty) { null } else {
                    let p = ($parts | first)
                    let reason = ($p | get -o reason | default "" | str trim)
                    let refined = if $p.status == "FAIL" {
                        if ($reason | str starts-with "badpkg") { "FAIL_BADPKG"
                        } else if ($reason | str starts-with "timed out") { "FAIL_TIMEOUT"
                        } else if ($reason | str starts-with "stderr") { "FAIL_STDERR"
                        } else { "FAIL" }
                    } else { $p.status }
                    { name: $p.name, status: $refined }
                }
            }
        }
        | where { $in != null }
    )

    # The summary section may also contain testbed-failure / autopkgtest-error
    # messages (psummary). Detect those for accurate overall classification.
    let testbed_failure = ($summary | str contains "testbed failure:")

    let overall = if $testbed_failure {
        "TMPFAIL"
    } else if ($subtests | is-empty) {
        "BAD"
    } else {
        let fails = ($subtests | get status)
        if "FAIL" in $fails { "FAIL"
        } else if "FAIL_STDERR" in $fails { "FAIL_STDERR"
        } else if "FAIL_TIMEOUT" in $fails { "FAIL_TIMEOUT"
        } else if "BROKEN" in $fails { "BROKEN"
        } else if "FAIL_BADPKG" in $fails { "FAIL_BADPKG"
        } else { "PASS" }
    }

    # Detect base vs proposed: --all-proposed adds proposed pocket to the testbed
    let kind = (detect-kind ($summary_split | first))

    { kind: $kind, overall: $overall, subtests: $subtests }
}

# Convert various autopkgtest URL forms to the raw log.gz URL.
# Accepts:
#   - already-raw `…/results/.../log.gz` URL (returned unchanged)
#   - run-page URL `…/packages/<pkg>/<series>/<arch>/<run_id>@`
# Returns "" if the URL doesn't match a known pattern.
export def to-log-url [url: string]: nothing -> string {
    if ($url | is-empty) { return "" }
    if ($url | str ends-with "log.gz") { return $url }
    # Match a run-page URL like
    # https://autopkgtest.ubuntu.com/packages/<pkg>/<series>/<arch>/<run_id>@[/]
    let m = ($url | parse -r '/packages/(?P<pkg>[^/]+)/(?P<series>[^/]+)/(?P<arch>[^/]+)/(?P<run>[^/@]+)@?/?$')
    if ($m | is-empty) { return "" }
    let r = ($m | first)
    let prefix = (package-prefix $r.pkg)
    $"($AUTOPKGTEST_URL)/results/autopkgtest-($r.series)/($r.series)/($r.arch)/($prefix)/($r.pkg)/($r.run)@/log.gz"
}

# Fetch a gzipped autopkgtest log and return its overall classification string.
# Accepts both raw log URLs and run-page URLs.
# Returns "" if the URL is empty / unrecognised / the fetch fails.
export def classify-log-url [log_url: string]: nothing -> string {
    let resolved = (to-log-url $log_url)
    if ($resolved | is-empty) { return "" }
    let result = (^curl -sf $resolved | complete)
    if $result.exit_code != 0 { return "" }
    let decoded = ($result.stdout | ^gzip -d | complete)
    if $decoded.exit_code != 0 { return "" }
    (parse-autopkgtest-log $decoded.stdout).overall
}

# Parse a listing-line timestamp like "20260608_160510_abc123" → datetime.
export def parse-run-timestamp [stamp: string]: nothing -> datetime {
    # Take "YYYYMMDD_HHMMSS" prefix (15 chars before the trailing _hash)
    let core = ($stamp | str substring 0..14)
    $core | into datetime --format "%Y%m%d_%H%M%S"
}

# Fetch and parse logs for a list of run records (source-agnostic).
# Input rows: {source, arch, stamp, log_url}
# Output rows: {source, arch, kind, time, log_url, overall, subtests}
export def fetch-and-parse-logs []: table -> table {
    $in | par-each {|r|
        let log = (do --ignore-errors { ^curl -s $r.log_url | ^gzip -d } | default "")
        let parsed = (parse-autopkgtest-log $log)
        {
            source:   $r.source
            arch:     $r.arch
            kind:     $parsed.kind
            time:     (parse-run-timestamp $r.stamp)
            log_url:  $r.log_url
            overall:  $parsed.overall
            subtests: $parsed.subtests
        }
    }
}
