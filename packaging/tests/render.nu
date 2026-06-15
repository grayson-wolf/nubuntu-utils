# Rendering helpers for autopkgtest run tables.

use ../../formatting.nu [osc8-link]
use log-parsing.nu [format-subtest]

# Keep only the most recent run per (series, source, arch, kind). Input rows
# may omit `series` (treated as ""). Shared by the raw paths of `p tests` /
# `archive-tests` and by this module's table renderer.
export def dedup-latest-runs []: table -> table {
    $in
    | sort-by time --reverse
    | group-by --to-table { |r| $"(($r | get -o series | default ''))|($r.source)|($r.arch)|($r.kind)" }
    | each {|g| $g.items | first }
}

# Shared renderer: per-source tables with one column per subtest.
# `header_fn` is a closure (string -> string) that builds the header from a
# source package name. Prints headers to stderr and returns the rendered
# display table(s) for pipeline use. When multiple sources are present,
# returns a concatenated table with a leading `source` column. When rows carry
# a `series` field spanning more than one series, a `series` column is added.
# `dedup_latest`: if true, keep only the latest run per (series, source, arch,
# kind); if false, keep all runs (history mode).
export def render-tests-tables [header_fn: closure, dedup_latest: bool = true]: table -> any {
    let runs = $in
    let multi_series = (
        ($runs | columns | any { $in == "series" })
        and (($runs | get series | uniq | length) > 1)
    )

    let prepared = if $dedup_latest {
        $runs | dedup-latest-runs
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
        # first appearance, sorted by series/arch/kind/time for stability)
        let ordered = if $dedup_latest {
            if $multi_series { $rows | sort-by series arch kind time } else { $rows | sort-by arch kind time }
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
            mut row = {}
            if $multi_source { $row = ($row | insert source $pkg) }
            if $multi_series { $row = ($row | insert series ($r | get -o series | default "")) }
            $row = ($row
                | insert arch $r.arch
                | insert kind $kind_cell
                | insert time $time_str
                | insert log $log_cell
                | insert overall $overall_cell)
            if not $dedup_latest {
                let trig_str = (
                    ($r | get -o triggers | default [])
                    | each {|t|
                        if $t == "migration-reference/0" {
                            $"(ansi attr_bold)(ansi purple)($t)(ansi reset)"
                        } else { $t }
                    }
                    | str join " "
                )
                let req_str = ($r | get -o requester | default "")
                $row = ($row | insert triggers $trig_str | insert requester $req_str)
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
