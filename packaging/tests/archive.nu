# Top-level `archive-tests` command — autopkgtest results for a package in the
# Ubuntu archive (no PPA).

use ../../completions.nu [pkg-completions]
use ../../ubuntu-versions.nu [DEVEL_RELEASE, SUPPORTED_RELEASES]
use ../../formatting.nu [with-spinner]
use ../meta.nu [pkg-name]
use fetch.nu [fetch-archive-test-runs]
use render.nu [render-tests-tables, render-tests-matrix]

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
    let runs = with-spinner $"Fetching archive tests for ($pkg)..." {
        $series_list | par-each {|s|
            (fetch-archive-test-runs $s $pkg $arches $max_per_arch --with-requester=$history)
            | each {|r| $r | insert series $s }
        } | flatten
    }
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
