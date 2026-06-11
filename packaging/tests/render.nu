# Rendering helpers for autopkgtest run tables.

use ../../formatting.nu [osc8-link]
use log-parsing.nu [format-subtest]

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
                let names = ($r.subtests | get name | uniq)
                $acc | append ($names | where { $in not-in $acc })
            }
        )

        $ordered | each {|r|
            let time_str = ($r.time | format date "%Y-%m-%d %H:%M")
            let log_cell = (osc8-link $r.log_url "🔗")
            let kind_cell = match $r.kind {
                "proposed" => $"(ansi yellow)proposed(ansi reset)"
                "running" => $"(ansi cyan)running(ansi reset)"
                "queued" => $"(ansi blue)queued(ansi reset)"
                _ => "base"
            }
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
export def render-tests-matrix [header: string, series_order: list<string>]: table -> any {
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
