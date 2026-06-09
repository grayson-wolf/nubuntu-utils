# Native PPA autopkgtest results table.
# Parses logs from autopkgtest.ubuntu.com directly (no LP credentials needed for
# public PPAs), in parallel, and renders one table per source package.

use ../../completions.nu [ppa-completions, normalize-ppa-name, pkg-completions]
use ../../formatting.nu [osc8-link]
use ../../ubuntu-versions.nu [DEVEL_RELEASE, SUPPORTED_RELEASES]
use ../meta.nu [pkg-name]

const AUTOPKGTEST_URL = "https://autopkgtest.ubuntu.com"

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
        _ => $status
    }
    let colored = match $status {
        "PASS" => $"(ansi green)($display)(ansi reset)"
        "PASS_SUPERFICIAL" => $"(ansi green_dimmed)($display)(ansi reset)"
        "FAIL" | "BROKEN" | "FAIL_TIMEOUT" | "FAIL_STDERR" => $"(ansi red)($display)(ansi reset)"
        "FAIL_BADPKG" => $"(ansi light_red)($display)(ansi reset)"
        "FLAKY" | "SKIP" | "TMPFAIL" => $"(ansi yellow)($display)(ansi reset)"
        "BAD" => $"(ansi dark_gray)($display)(ansi reset)"
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
def parse-run-timestamp [stamp: string]: nothing -> datetime {
    # Take "YYYYMMDD_HHMMSS" prefix (15 chars before the trailing _hash)
    let core = ($stamp | str substring 0..14)
    $core | into datetime --format "%Y%m%d_%H%M%S"
}

# Fetch and parse logs for a list of run records (source-agnostic).
# Input rows: {source, arch, stamp, log_url}
# Output rows: {source, arch, kind, time, log_url, overall, subtests}
def fetch-and-parse-logs []: table -> table {
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

# Fetch and parse all available test runs for a (series, owner, ppa).
# Returns table<source, arch, kind, time, log_url, overall, subtests>
# Keeps up to `max_per_arch` most recent runs per (source, arch) before downloading logs.
export def fetch-ppa-test-runs [
    series: string
    owner: string
    ppa: string
    max_per_arch: int = 4
    arches: list<string> = []  # empty = all
]: nothing -> table {
    let base = $"($AUTOPKGTEST_URL)/results/autopkgtest-($series)-($owner)-($ppa)/"

    # 1. Fetch the listing
    let listing_text = (do --ignore-errors { http get $"($base)?format=plain" } | default "")
    if ($listing_text | is-empty) { return [] }

    # 2. Parse listing into {arch, source, stamp, log_url}, filter by arch if requested
    let entries = (
        $listing_text
        | lines
        | where { ($in | str ends-with "log.gz") and ($in | is-not-empty) }
        | each {|line|
            let parts = ($line | split row "/")
            if ($parts | length) < 6 { null } else {
                {
                    arch:    ($parts | get 1)
                    source:  ($parts | get 3)
                    stamp:   ($parts | get 4)
                    log_url: $"($base)($line)"
                }
            }
        }
        | where { $in != null }
        | where { ($arches | is-empty) or ($in.arch in $arches) }
    )
    if ($entries | is-empty) { return [] }

    # 3. Keep top N most recent per (source, arch)
    let latest = (
        $entries
        | sort-by stamp --reverse
        | group-by --to-table { |r| $"($r.source)|($r.arch)" }
        | each {|g| $g.items | first $max_per_arch }
        | flatten
    )

    # 4. Parallel fetch + parse each log
    $latest | fetch-and-parse-logs
}

# Compute the autopkgtest URL "prefix" component for a package name
# (matches Debian pool convention: "libX..." → "libx", else first letter).
def package-prefix [package: string]: nothing -> string {
    if ($package | str starts-with "lib") {
        $package | str substring 0..3
    } else {
        $package | str substring 0..0
    }
}

# Fetch and parse archive autopkgtest runs for a (series, package) across the
# given arches. Scrapes the per-arch HTML listing page since the swift container
# does not support ?format=plain for the main archive containers.
# Returns the same shape as `fetch-ppa-test-runs`.
def fetch-archive-test-runs [
    series: string
    package: string
    arches: list<string>
    max_per_arch: int = 4
]: nothing -> table {
    let prefix = (package-prefix $package)
    let log_base = $"($AUTOPKGTEST_URL)/results/autopkgtest-($series)/($series)"

    let entries = (
        $arches | par-each {|arch|
            let page_url = $"($AUTOPKGTEST_URL)/packages/($prefix)/($package)/($series)/($arch)"
            let html = (do --ignore-errors { http get $page_url } | default "")
            if ($html | is-empty) { [] } else {
                # Extract run IDs (YYYYMMDD_HHMMSS_<hash>), keep unique in
                # appearance order. Page lists most-recent first.
                let ids = (
                    $html
                    | parse -r '(?P<id>\d{8}_\d{6}_[a-z0-9]+)'
                    | get id
                    | uniq
                    | first $max_per_arch
                )
                $ids | each {|id|
                    {
                        arch:    $arch
                        source:  $package
                        stamp:   $id
                        log_url: $"($log_base)/($arch)/($prefix)/($package)/($id)@/log.gz"
                    }
                }
            }
        } | flatten
    )
    if ($entries | is-empty) { return [] }
    $entries | fetch-and-parse-logs
}

# Shared renderer: per-source tables with one column per subtest.
# `header_fn` is a closure (string -> string) that builds the header from a
# source package name. Prints headers to stderr and returns the rendered
# display table(s) for pipeline use. When multiple sources are present,
# returns a concatenated table with a leading `source` column.
# `dedup_latest`: if true, keep only the latest run per (source, arch, kind);
# if false, keep all runs (history mode).
export def render-tests-tables [header_fn: closure, dedup_latest: bool = true]: table -> any {
    let runs = $in
    let prepared = if $dedup_latest {
        $runs
        | sort-by time --reverse
        | group-by --to-table { |r| $"($r.source)|($r.arch)|($r.kind)" }
        | each {|g| $g.items | first }
    } else {
        # History mode: time desc (most recent first), then arch asc (stable sort).
        $runs | sort-by source arch | sort-by time --reverse
    }

    let by_source = ($prepared | group-by --to-table source)
    let multi_source = (($by_source | length) > 1)

    let rendered = ($by_source | each {|g|
        let pkg = $g.source
        let rows = $g.items
        print -e $"\n(do $header_fn $pkg)"

        # Union of subtest names across this source's rows (preserve order of
        # first appearance, sorted by arch/kind/time for stability)
        let ordered = if $dedup_latest {
            $rows | sort-by arch kind time
        } else {
            $rows | sort-by arch | sort-by time --reverse
        }
        let subtest_names = (
            $ordered
            | reduce --fold [] {|r, acc|
                let names = ($r.subtests | get name)
                $acc | append ($names | where { $in not-in $acc })
            }
        )

        $ordered | each {|r|
            let time_str = ($r.time | format date "%Y-%m-%d %H:%M")
            let log_cell = (osc8-link $r.log_url "🔗")
            let kind_cell = if $r.kind == "proposed" { $"(ansi yellow)proposed(ansi reset)" } else { "base" }
            let overall_cell = (format-subtest $r.overall)
            mut row = if $multi_source {
                { source: $pkg, arch: $r.arch, kind: $kind_cell, time: $time_str, log: $log_cell, overall: $overall_cell }
            } else {
                { arch: $r.arch, kind: $kind_cell, time: $time_str, log: $log_cell, overall: $overall_cell }
            }
            for name in $subtest_names {
                let match = ($r.subtests | where name == $name)
                let cell = if ($match | is-empty) { "" } else {
                    format-subtest ($match | first | get status)
                }
                $row = ($row | insert $name $cell)
            }
            $row
        }
    } | flatten)

    print -e ""
    $rendered
}

# Cross-series matrix renderer: rows = arch, columns = series. Cells show
# overall status of the most recent run per (series, arch) regardless of pocket.
# Prints header to stderr; returns the matrix table for pipeline use.
def render-tests-matrix [header: string, series_order: list<string>]: table -> any {
    let runs = $in
    let deduped = (
        $runs
        | sort-by time --reverse
        | group-by --to-table { |r| $"($r.series)|($r.arch)" }
        | each {|g| $g.items | first }
    )

    print -e $"\n($header)\n"

    let series_present = ($deduped | get series | uniq)
    let cols = ($series_order | where { $in in $series_present })
    let arches = ($deduped | get arch | uniq | sort)
    $arches | each {|arch|
        mut row = { arch: $arch }
        for s in $cols {
            let match = ($deduped | where series == $s and arch == $arch)
            let cell = if ($match | is-empty) { "" } else {
                let r = ($match | first)
                osc8-link $r.log_url (format-subtest $r.overall)
            }
            $row = ($row | insert $s $cell)
        }
        $row
    }
}

const DEFAULT_ARCHES = [amd64 arm64 armhf i386 ppc64el riscv64 s390x]
const DEFAULT_SERIES = [$DEVEL_RELEASE]

# Show autopkgtest results for a package in the Ubuntu archive (no PPA).
# Default: per-source table for the devel series (one row per arch, latest run).
# Matrix mode (auto when --series has >1 entry, or via --matrix / --all-series):
# a single arch × series grid of overall statuses (no subtest columns).
# History mode (--history): show all recent runs per arch chronologically — useful
# for investigating when a test started failing. Incompatible with matrix mode.
# Default output is the display table (pipeline-filterable); use --raw for the
# structured row data including the `subtests` list column.
export def archive-tests [
    package?: string@pkg-completions          # Source package (defaults to cwd package)
    --series (-s): list<string> = $DEFAULT_SERIES   # Ubuntu series to query
    --arches (-a): list<string> = $DEFAULT_ARCHES   # Architectures to query
    --matrix (-m)                             # Force matrix view (auto when >1 series)
    --all-series                              # Shortcut: matrix across all supported series
    --history (-H)                            # Show all recent runs per arch (chronological)
    --limit (-l): int = 10                    # Max runs per arch to fetch in history mode
    --raw (-r)                                # Return structured records with full subtest data
]: nothing -> any {
    let pkg = if ($package | is-empty) { pkg-name } else { $package }
    let series_list = if $all_series { $SUPPORTED_RELEASES } else { $series }
    let use_matrix = $matrix or $all_series or (($series_list | length) > 1)
    if $history and $use_matrix {
        error make { msg: "--history is incompatible with matrix mode (use a single --series)" }
    }
    let max_per_arch = if $use_matrix { 1 } else if $history { $limit } else { 4 }

    # Fetch in parallel across series; tag each run with its series.
    let runs = (
        $series_list | par-each {|s|
            fetch-archive-test-runs $s $pkg $arches $max_per_arch
            | each {|r| $r | insert series $s }
        } | flatten
    )
    if ($runs | is-empty) {
        let series_disp = ($series_list | str join ", ")
        print -e $"(ansi yellow)No test results found for ($pkg) in ($series_disp).(ansi reset)"
        return
    }

    if $raw {
        let prepared = if $history {
            $runs | sort-by time --reverse
        } else {
            $runs
            | sort-by time --reverse
            | group-by --to-table { |r| $"($r.series)|($r.source)|($r.arch)|($r.kind)" }
            | each {|g| $g.items | first }
        }
        return $prepared
    }

    if $use_matrix {
        let series_disp = ($series_list | str join ", ")
        let header = $"(ansi cyan)($pkg)(ansi reset) — archive — series: (ansi yellow)($series_disp)(ansi reset)"
        $runs | render-tests-matrix $header $series_list
    } else {
        let s = ($series_list | first)
        $runs | render-tests-tables {|p|
            $"(ansi cyan)($p)(ansi reset) in (ansi yellow)($s)(ansi reset) — archive"
        } (not $history)
    }
}
