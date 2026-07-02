# Fetchers for autopkgtest runs from various sources.
# All return rows shaped like {source, arch, kind, time, log_url, overall, subtests}
# so they can be unioned and rendered uniformly.

use log-parsing.nu [AUTOPKGTEST_URL, fetch-and-parse-logs, package-prefix]
use ../http.nu [http-get]

const EXCUSES_URL = "https://ubuntu-archive-team.ubuntu.com/proposed-migration"

# Download and parse the full excuses YAML for a series.
# Returns parsed YAML (contains `generated-date` (as nushell date) and `sources`).
# The payload is xz-compressed
# (application/x-xz, not an HTTP Content-Encoding), so it's fetched raw and
# piped through an explicit `xz -d`.
export def fetch-excuses [series: string]: nothing -> table {
    let url = $"($EXCUSES_URL)/($series)/update_excuses.yaml.xz"
    let compressed = (http-get --raw $url)
    if ($compressed | is-empty) {
        error make { msg: $"No excuses data for series '($series)' \(($url) not found)" }
    }
    mut $out = $compressed | ^xz -d | from yaml
    $out.generated-date = $out.generated-date | split row "." | get 0 | into datetime --format "%Y-%m-%d %H:%M:%S" --timezone UTC | date to-timezone local
    $out
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

    # 1. Fetch the listing (plain-text index of the results container)
    let listing_text = (http-get $"($base)?format=plain")
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

# Common row builder for pending (running/waiting) autopkgtest jobs.
# Detects proposed-pocket via the "/migration-reference" trigger marker and
# produces a record shaped like fetch-ppa-test-runs output.
def make-pending-row [
    source: string
    arch: string
    triggers: list<string>
    time: datetime
    overall: string
]: nothing -> record {
    let proposed = ($triggers | any { $in | str contains "/migration-reference" })
    {
        source:   $source
        arch:     $arch
        kind:     (if $proposed { "proposed" } else { "base" })
        time:     $time
        log_url:  $"($AUTOPKGTEST_URL)/running"
        overall:  $overall
        subtests: []
    }
}

# Fetch currently running autopkgtest jobs for a PPA.
# Returns rows shaped like fetch-ppa-test-runs output (source, arch, kind,
# time, log_url, overall=RUNNING, subtests=[]), so render-tests-tables can
# display them alongside finished runs.
export def fetch-ppa-running [
    series: string
    owner: string
    ppa: string
    arches: list<string> = []  # empty = all
]: nothing -> table {
    let ppa_id = $"($owner)/($ppa)"
    let data = (http-get $"($AUTOPKGTEST_URL)/static/running.json" | default {})
    if ($data | is-empty) { return [] }
    let now = (date now)
    $data
    | transpose pkg jobs
    | each {|p|
        $p.jobs | transpose handle codenames | each {|h|
            $h.codenames | transpose codename arches | each {|c|
                if $c.codename != $series { return [] }
                $c.arches | transpose arch info | each {|a|
                    let jobinfo = ($a.info | get -o 0 | default {})
                    let ppas = ($jobinfo | get -o ppas | default [])
                    if $ppa_id not-in $ppas { return null }
                    if (not ($arches | is-empty)) and ($a.arch not-in $arches) { return null }
                    # info[1] is elapsed-seconds-since-submission, not a unix epoch.
                    let elapsed = ($a.info | get -o 1 | default 0 | into int)
                    let triggers = ($jobinfo | get -o triggers | default [])
                    make-pending-row $p.pkg $a.arch $triggers ($now - ($elapsed * 1sec)) "RUNNING"
                } | where { $in != null }
            } | flatten
        } | flatten
    } | flatten
}

# Fetch queued (waiting) autopkgtest jobs for a PPA. Same row shape as
# fetch-ppa-running but with overall=WAITING.
export def fetch-ppa-waiting [
    series: string
    owner: string
    ppa: string
    arches: list<string> = []
]: nothing -> table {
    let ppa_id = $"($owner)/($ppa)"
    let data = (http-get $"($AUTOPKGTEST_URL)/queues.json" | default {})
    if ($data | is-empty) { return [] }
    # Shape: {queue: {codename: {arch: [ {package, triggers, submit-time, ppas?}, ... ]}}}
    # PPA jobs live under the "ppa" queue; "ubuntu" entries lack the ppas field.
    let ppa_queue = ($data | get -o ppa | default {})
    if ($ppa_queue | is-empty) { return [] }
    $ppa_queue
    | transpose codename arches
    | each {|c|
        if $c.codename != $series { return [] }
        $c.arches | transpose arch entries | each {|a|
            if (not ($arches | is-empty)) and ($a.arch not-in $arches) { return [] }
            # Each entry is a string "pkgname\n{json-args}" — not a record.
            $a.entries | each {|raw|
                let parts = ($raw | split row "\n" --number 2)
                let pkg = ($parts | get -o 0 | default "" | str trim)
                if ($pkg | is-empty) { return null }
                let json_str = ($parts | get -o 1 | default "")
                let e = if ($json_str | is-empty) { {} } else {
                    try { $json_str | from json } catch { {} }
                }
                let ppas = ($e | get -o ppas | default [])
                if $ppa_id not-in $ppas { return null }
                let triggers = ($e | get -o triggers | default [])
                let submit_str = ($e | get -o submit-time | default "")
                let submit_time = if ($submit_str | is-empty) {
                    (date now)
                } else {
                    try { $submit_str | into datetime --format "%Y-%m-%d %H:%M:%S" --timezone UTC | date to-timezone local } catch { (date now) }
                }
                make-pending-row $pkg $a.arch $triggers $submit_time "WAITING"
            } | where { $in != null }
        } | flatten
    } | flatten
}

# Fetch and parse archive autopkgtest runs for a (series, package) across the
# given arches. Scrapes the per-arch HTML listing page since the swift container
# does not support ?format=plain for the main archive containers.
# Returns the same shape as `fetch-ppa-test-runs`.
export def fetch-archive-test-runs [
    series: string
    package: string
    arches: list<string>
    max_per_arch: int = 4
    --with-requester                          # Add a `requester` column (one extra HTTP per run)
]: nothing -> table {
    let prefix = (package-prefix $package)
    let log_base = $"($AUTOPKGTEST_URL)/results/autopkgtest-($series)/($series)"

    let entries = (
        $arches | par-each {|arch|
            let page_url = $"($AUTOPKGTEST_URL)/packages/($prefix)/($package)/($series)/($arch)"
            let html = (http-get $page_url | default "")
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
    let parsed = ($entries | fetch-and-parse-logs)
    if not $with_requester { return $parsed }
    $parsed | par-each --keep-order {|row|
        let stamp_match = ($row.log_url | parse -r '(?P<id>\d{8}_\d{6}_[a-z0-9]+)')
        let run_id = if ($stamp_match | is-empty) { "" } else { $stamp_match | first | get id }
        $row | insert requester (fetch-run-requester $package $series $row.arch $run_id)
    }
}

# Fetch the `Requester` field from a run's detail HTML page.
# Returns "" if the field is missing, "-" (migration-auto-triggered), or
# the fetch fails.
def fetch-run-requester [
    package: string
    series: string
    arch: string
    run_id: string
]: nothing -> string {
    if ($run_id | is-empty) { return "" }
    let url = $"($AUTOPKGTEST_URL)/packages/($package)/($series)/($arch)/($run_id)@"
    let html = (http-get $url | default "")
    if ($html | is-empty) { return "" }
    let m = ($html | parse -r '(?s)Requester</th>\s*<td>(?P<r>.*?)</td>')
    if ($m | is-empty) { return "" }
    let val = ($m | first | get r | str trim)
    # The HTML wraps the value in extra whitespace; strip tags as well.
    let stripped = ($val | str replace -r -a '<[^>]+>' '' | str trim)
    if $stripped == "-" or ($stripped | is-empty) { "" } else { $stripped }
}
