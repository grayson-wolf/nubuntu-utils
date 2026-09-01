# NBS (not built from source) report.
use ../formatting.nu [osc8-link, lp-source-url, with-spinner]
use ../ubuntu-versions.nu [DEVEL_RELEASE]
use cache.nu [cache-file-flat, cache-load, cache-save]

const NBS_BASE = "https://static-reports.ubuntu.com/nbs"
const NBS_PAGE = $"($NBS_BASE)/nbs.html"
const NBS_CSV = $"($NBS_BASE)/nbs.csv"
const NBS_TTL = 60min
const MS_PER_DAY = 86_400_000

# Fetch the current report HTML (cached NBS_TTL, flat singleton file).
def fetch-report []: nothing -> string {
    let path = (cache-file-flat "nbs.html")
    let cached = (cache-load $path $NBS_TTL)
    if $cached != null { return ($cached | into string) }
    let fresh = (http get $NBS_PAGE)
    if ($fresh | is-not-empty) { cache-save $path $fresh }
    $fresh
}

# Fetch the nbs.csv time series (cached NBS_TTL, flat singleton file).
def fetch-nbs []: nothing -> table {
    let path = (cache-file-flat "nbs.csv")
    let cached = (cache-load $path $NBS_TTL)
    let rows = if $cached != null {
        $cached
    } else {
        let fresh = (http get --raw $NBS_CSV | decode utf-8 | from csv)
        if ($fresh | is-not-empty) { cache-save $path $fresh }
        $fresh
    }
    $rows | into int time removable total | sort-by time
}

# Parse the report HTML into structured data:
#   generated: datetime, series: string, remove_cmd: string,
#   removable: list<string>,
#   packages: table(name, removable),
#   rdeps: table(package, rdep, rdep_status, component, supported, arches, via),
#   dependents: table(package, component, supported, deps)
# rdep_status is the page's span class
def parse-report [html: string]: nothing -> record {
    let generated = (try {
        $html | parse --regex 'Generated at (?<ts>[^.]+)\.' | get 0.ts | into datetime
    } catch { null })

    mut section = ""
    mut series = ""
    mut remove_cmd = ""
    mut removable = []
    mut packages = []
    mut rdeps = []
    mut dependents = []

    for line in ($html | lines) {
        if ($line | str contains "<h2>Reverse dependencies</h2>") { $section = "rdeps"; continue }
        if ($line | str contains "<h2>Packages which depend on NBS packages</h2>") { $section = "dependents"; continue }
        if ($line =~ 'font-family: monospace') {
            $remove_cmd = ($line | parse --regex 'monospace">(?<cmd>[^<]+)' | get 0?.cmd | default "")
            $series = ($remove_cmd | parse --regex '-s (?<s>\w+)' | get 0?.s | default "")
            $removable = ($remove_cmd | split row " -y " | get 1? | default "" | split row " " | where {|p| $p | is-not-empty })
            continue
        }
        if $section == "rdeps" {
            if ($line =~ 'colspan="5"') {
                let m = ($line | parse --regex '<span class="(?<cls>[a-z]+)">(?<pkg>[^<]+)</span>' | get 0?)
                if $m != null {
                    $packages = ($packages | append { name: $m.pkg, removable: ($m.cls == "removable") })
                }
            } else if ($line starts-with '<tr><td>&nbsp;' and ($packages | is-not-empty)) {
                let m = ($line | parse --regex '<span class="(?<cls>[a-z]+)">(?<rdep>[^<]+)</span></td> <td><span class="component(?<sup>[a-z]+)">(?<component>[^<]+)</span></td><td>(?<arches>[^<]*)</td><td>(?<via>[^<]*)</td>' | get 0?)
                if $m != null {
                    $rdeps = ($rdeps | append {
                        package: ($packages | last | get name)
                        rdep: $m.rdep
                        rdep_status: $m.cls
                        component: $m.component
                        supported: ($m.sup == "sup")
                        arches: $m.arches
                        via: $m.via
                    })
                }
            }
        } else if $section == "dependents" {
            if ($line starts-with '<tr><td>') {
                let m = ($line | parse --regex '^<tr><td>(?<pkg>[^<]+)</td> <td><span class="component(?<sup>[a-z]+)">(?<component>[^<]+)</span></td><td>(?<deps>[^<]*)</td></tr>$' | get 0?)
                if $m != null {
                    $dependents = ($dependents | append {
                        package: $m.pkg
                        component: $m.component
                        supported: ($m.sup == "sup")
                        deps: ($m.deps | split row " ")
                    })
                }
            }
        }
    }
    {
        generated: $generated
        series: $series
        remove_cmd: $remove_cmd
        removable: $removable
        packages: $packages
        rdeps: $rdeps
        dependents: $dependents
    }
}

def pkg-cell [name: string, removable: bool, link: string]: nothing -> string {
    let cell = if ($link | is-empty) { $name } else { osc8-link $link $name }
    if $removable { $"(ansi green_bold)($cell)(ansi reset)" } else { $cell }
}

def rdep-cell [name: string, status: string, link: string]: nothing -> string {
    let cell = if ($link | is-empty) { $name } else { osc8-link $link $name }
    match $status {
        "nbs" => $"(ansi blue)($cell)(ansi reset)"
        "removable" => $"(ansi green_bold)($cell)(ansi reset)"
        _ => $cell
    }
}

def component-cell [component: string, supported: bool]: nothing -> string {
    if $supported { $"(ansi red)($component)(ansi reset)" } else { $"(ansi dark_gray)($component)(ansi reset)" }
}

# Map every binary name in the report to a Launchpad source-package URL.
# One batched `apt-cache show` call instead of bin-source-link's per-package
# shell-out; names absent from the local apt cache fall back to a source link under
# their own name, which is right for the NBS binaries themselves and a
# good guess for the rdeps.
def link-map [names: list<string>]: nothing -> record {
    let unique = ($names | uniq)
    let out = (^apt-cache show ...$unique | complete)
    mut map = {}
    mut current = ""
    if $out.exit_code == 0 {
        for line in ($out.stdout | lines) {
            if ($line | str starts-with "Package: ") {
                $current = ($line | str replace 'Package: ' '')
            } else if (($line | str starts-with "Source: ") and ($current | is-not-empty) and ($current in $unique)) {
                # `Source:` may carry a version, e.g. "Source: glibc (2.39-...)".
                let src = ($line | str replace 'Source: ' '' | str replace -r '\s*\(.*\)\s*$' '')
                $map = ($map | upsert $current $src)
                $current = ""
            }
        }
    }
    let resolved = $map
    $unique | each {|n| { $n: (lp-source-url ($resolved | get -o $n | default $n)) } } | reduce --fold {} {|it, acc| $acc | merge $it }
}

# Project the report to one summary row per NBS package
def build-current-rows [report: record]: nothing -> table {
    let links = with-spinner "Resolving binary → source links..." { link-map ($report.packages | get name) }
    $report.packages | each {|p|
        let rows = ($report.rdeps | where package == $p.name)
        let nbs_rdeps = ($rows | where rdep_status != "normal" | length)
        let sup_rdeps = ($rows | where supported | length)
        {
            package: (pkg-cell $p.name $p.removable ($links | get -o $p.name | default ""))
            rdeps: ($rows | length)
            "nbs rdeps": $nbs_rdeps
            "main/restr": $sup_rdeps
            via: ($rows | get via | uniq | str join " ")
        }
    }
}

# List the full reverse-dependency set of one NBS package.
def build-package-rows [report: record, package: string]: nothing -> table {
    let pkg = ($report.packages | where name == $package | get -o 0)
    if $pkg == null {
        error make { msg: $"($package) is not NBS in ($report.series)" }
    }
    let rows = ($report.rdeps | where package == $package)
    let names = [$package] ++ ($rows | get rdep)
    let links = with-spinner "Resolving binary → source links..." { link-map $names }
    let url = ($links | get -o $package | default "")
    let removable = if $pkg.removable { " (safely removable)" } else { "" }
    let label = if ($url | is-empty) { $package } else { osc8-link $url $package }
    print -e $"(ansi attr_bold)($label)(ansi reset) — ($rows | length) reverse deps($removable)"
    $rows | each {|r|
        {
            "reverse dep": (rdep-cell $r.rdep $r.rdep_status ($links | get -o $r.rdep | default ""))
            component: (component-cell $r.component $r.supported)
            arches: $r.arches
            via: $r.via
        }
    }
}

# Project the "Packages which depend on NBS packages" section.
def build-dependent-rows [report: record]: nothing -> table {
    let names = ($report.dependents | get package) ++ ($report.dependents | get deps | flatten)
    let links = with-spinner "Resolving binary → source links..." { link-map $names }
    $report.dependents | each {|d|
        let url = ($links | get -o $d.package | default "")
        {
            package: (if ($url | is-empty) { $d.package } else { osc8-link $url $d.package })
            component: (component-cell $d.component $d.supported)
            "nbs deps": ($d.deps | each {|n|
                let u = ($links | get -o $n | default "")
                if ($u | is-empty) { $n } else { osc8-link $u $n }
            } | str join " ")
        }
    }
}

# Collapse the sample stream to one row per UTC day
def daily-samples [rows: table]: nothing -> table {
    $rows
    | group-by {|r| $r.time // $MS_PER_DAY }
    | values
    | each {|g| $g | last }
}

# Render a signed day-over-day delta
def fmt-delta [d: int]: nothing -> string {
    if $d < 0 {
        $"(ansi green)($d)(ansi reset)"
    } else if $d > 0 {
        $"(ansi red)+($d)(ansi reset)"
    } else {
        $"(ansi dark_gray)0(ansi reset)"
    }
}

# Project the daily samples into display rows
def build-history-rows [daily: table]: nothing -> table {
    $daily | enumerate | each {|it|
        let r = $it.item
        let prev_total = if $it.index == 0 { $r.total } else { ($daily | get ($it.index - 1)).total }
        let removable = if $r.removable > 0 {
            $"(ansi green_bold)($r.removable)(ansi reset)"
        } else {
            $"(ansi dark_gray)0(ansi reset)"
        }
        {
            date: (($r.time * 1_000_000) | into datetime | date to-timezone UTC | format date "%Y-%m-%d")
            removable: $removable
            total: $r.total
            "Δ total": (fmt-delta ($r.total - $prev_total))
        }
    }
}

# Show the current NBS (not built from source) report.
export def "nbs-report" [
    package?: string        # drill into one NBS package's reverse deps
    --history (-H)          # show the over-time graph as a daily table
    --dependents (-d)       # show packages which depend on NBS packages
    --days: int = 30        # (with -H) number of most recent days to show
    --all (-a)              # (with -H) show the full daily history
    --raw (-r)              # return raw parsed data (report record, or samples with -H)
]: nothing -> any {
    if $history {
        let rows = with-spinner "Fetching NBS time series..." { fetch-nbs }
        if ($rows | is-empty) {
            print -e $"(ansi yellow)No NBS data fetched from ($NBS_CSV).(ansi reset)"
            return
        }
        if $raw {
            return ($rows | update time {|r| ($r.time * 1_000_000) | into datetime })
        }
        let daily = (daily-samples $rows)
        let latest = ($daily | last)
        let latest_date = (($latest.time * 1_000_000) | into datetime | date to-timezone UTC | format date "%Y-%m-%d")
        let page = (osc8-link $NBS_PAGE "nbs page")
        print -e $"(ansi attr_bold)nbs history(ansi reset) — (ansi cyan)($latest.total)(ansi reset) NBS binaries, (ansi green)($latest.removable)(ansi reset) safely removable, as of ($latest_date) ($page)"
        # Deltas are computed against the full history first, so the first
        # shown row compares against the day before the window, not itself.
        let report = (build-history-rows $daily)
        return (if $all { $report } else { $report | last $days })
    }

    let html = with-spinner "Fetching NBS report..." { fetch-report }
    if ($html | is-empty) {
        print -e $"(ansi yellow)No NBS report fetched from ($NBS_PAGE).(ansi reset)"
        return
    }
    let report = (parse-report $html)
    if $raw { return $report }

    let series = if ($report.series | is-empty) { $DEVEL_RELEASE } else { $report.series }
    if ($report.packages | is-empty) {
        print -e $"(ansi yellow)No NBS packages in ($series).(ansi reset)"
        return
    }

    if ($package | is-not-empty) {
        return (build-package-rows $report $package)
    }

    let generated = if $report.generated != null {
        $report.generated | date to-timezone local | format date "%Y-%m-%d %H:%M"
    } else { "unknown" }
    let page = (osc8-link $NBS_PAGE "nbs page")
    print -e $"(ansi attr_bold)nbs(ansi reset) — (ansi cyan)($report.packages | length)(ansi reset) NBS binaries in (ansi yellow)($series)(ansi reset), (ansi green)($report.removable | length)(ansi reset) safely removable, generated ($generated) ($page)"
    if ($report.remove_cmd | is-not-empty) {
        print -e $"(ansi dark_gray)($report.remove_cmd)(ansi reset)"
    }
    if not $dependents {
        print -e $"(ansi green_bold)package(ansi reset): safely removable · (ansi blue_bold)nbs rdeps(ansi reset): reverse deps that are NBS themselves · (ansi red_bold)main/restr(ansi reset): reverse deps in main/restricted"
    }

    if $dependents { return (build-dependent-rows $report) }
    build-current-rows $report
}
