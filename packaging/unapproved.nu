# Unapproved upload queue for an Ubuntu series.
#
# Mirrors the Launchpad "+queue?queue_state=1" page — uploads sitting in the
# Unapproved state, awaiting archive-admin review. Sources data from the LP
# REST API (distro_series.getPackageUploads with status=Unapproved), cached
# 5min (same TTL as other LP listings).

use ../completions.nu [release-completions]
use ../formatting.nu [osc8-link, lp-source-link, with-spinner]
use ../ubuntu-versions.nu [LATEST_STABLE_RELEASE]
use cache.nu [cache-file, cache-load, cache-save]
use http.nu [http-get]

const LP_API = "https://api.launchpad.net/devel"
const LP_WEB = "https://launchpad.net"
const QUEUE_TTL = 5min

# Walk the LP pagination chain for getPackageUploads on a series.
# Returns the full list of package_upload entry records.
def fetch-all-pages [url: string]: nothing -> list {
    mut out = []
    mut current = $url
    loop {
        let page = (http-get $current)
        if ($page | is-empty) { break }
        let entries = ($page | get -o entries | default [])
        $out = ($out | append $entries)
        let next = ($page | get -o next_collection_link | default "")
        if ($next | is-empty) { break }
        $current = $next
    }
    $out
}

# Fetch the unapproved queue for a series from the LP API (cached QUEUE_TTL).
# Returns raw package_upload records. An empty queue caches as [] and reads
# back without refetch.
def fetch-unapproved [series: string]: nothing -> list {
    let path = (cache-file "unapproved" $series)
    let cached = (cache-load $path $QUEUE_TTL)
    if $cached != null { return $cached }
    let first = $"($LP_API)/ubuntu/($series)?ws.op=getPackageUploads&status=Unapproved&ws.size=75"
    let entries = with-spinner $"Fetching unapproved queue for ($series)..." {
        fetch-all-pages $first
    }
    cache-save $path $entries
    $entries
}

# Project a raw package_upload record into a display row.
def build-queue-row [e: record]: nothing -> record {
    let pkg = ($e | get -o package_name | default "")
    let ver = ($e | get -o package_version | default "")
    let created = (try { ($e | get -o date_created | default "") | into datetime } catch { null })
    {
        package: (lp-source-link $pkg)
        version: (lp-source-link $pkg --version $ver)
        arches: ($e | get -o display_arches | default "")
        component: ($e | get -o component_name | default "")
        pocket: ($e | get -o pocket | default "")
        created: $created
        changes: (osc8-link ($e | get -o changes_file_url | default "") "🔗")
    }
}

# Show the unapproved upload queue for an Ubuntu series.
#
# Mirrors the Launchpad +queue?queue_state=1 page: uploads sitting in the
# Unapproved state awaiting archive-admin review. Data is cached 5min.
#
# Pass a package name to filter (substring match on package_name, like the
# web page's queue_text filter). --raw returns the full LP records.
export def main [
    series?: string@release-completions  # Ubuntu series (default: latest stable)
    --raw (-r)                           # Return the raw LP entry records
    --package (-p): string = ""          # Filter by package name (substring)
]: nothing -> any {
    let s = ($series | default $LATEST_STABLE_RELEASE)
    let entries = (fetch-unapproved $s)

    if ($entries | is-empty) {
        print -e $"(ansi yellow)No unapproved uploads in ($s).(ansi reset)"
        return
    }

    let filtered = if ($package | is-not-empty) {
        $entries | where { ($in | get -o package_name | default "") =~ $package }
    } else {
        $entries
    }

    if ($filtered | is-empty) {
        print -e $"(ansi yellow)No unapproved uploads matching '($package)' in ($s).(ansi reset)"
        return
    }

    if $raw { return $filtered }

    let queue_url = $"($LP_WEB)/ubuntu/($s)/+queue?queue_state=1"
    let queue_link = (osc8-link $queue_url "queue page")
    let count = ($filtered | length)
    print -e $"(ansi attr_bold)unapproved(ansi reset) — (ansi cyan)($count)(ansi reset) uploads in (ansi yellow)($s)(ansi reset) ($queue_link)"

    $filtered | each {|e| build-queue-row $e }
}
