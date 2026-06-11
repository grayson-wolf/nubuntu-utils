# Launchpad webservice helpers.
# Anonymous read-only queries against the LP REST API; cached on disk where
# the underlying data is immutable.

use cache.nu *

const LP_API = "https://api.launchpad.net/devel"

# Make a filesystem-safe filename for a (package, version) cache key.
def pub-cache-key [package: string, version: string]: nothing -> string {
    $"($package)_(cache-key $version).json"
}

# Extract the bare LP username (~slug) from a person link like
# "https://api.launchpad.net/devel/~someone", or null if input is null/empty.
def lp-user-from-link [link: any]: nothing -> any {
    if ($link | is-empty) { return null }
    let s = ($link | into string)
    let parts = ($s | split row "/~")
    if ($parts | length) < 2 { return null }
    $parts | last
}

# Fetch the LP source publication record for an exact (package, version) pair
# in the Ubuntu primary archive. Returns the first matching entry record, or
# null if no publication exists. Disk-cached forever (publications are immutable).
export def lp-source-publication [
    package: string
    version: string
]: nothing -> any {
    let key = (pub-cache-key $package $version)
    let cache_file = (cache-file "lp-publications" $key)
    if ($cache_file | path exists) {
        let cached = (try { open $cache_file } catch { null })
        # Cached "null" sentinel means we already confirmed nothing exists.
        if ($cached | describe) == "string" and $cached == "null" { return null }
        if $cached != null { return $cached }
    }
    let url = $"($LP_API)/ubuntu/+archive/primary"
    let raw = (curl -sG $url
        --data-urlencode "ws.op=getPublishedSources"
        --data-urlencode $"source_name=($package)"
        --data-urlencode $"version=($version)"
        --data-urlencode "exact_match=true"
        --data-urlencode "order_by_date=true"
        | complete)
    if $raw.exit_code != 0 {
        # Network error — don't cache, return null
        return null
    }
    let parsed = (try { $raw.stdout | from json } catch { null })
    if ($parsed | is-empty) {
        # Non-JSON response (HTML error page, rate-limit, etc.) — don't cache
        return null
    }
    let entries = ($parsed | get -o entries | default [])
    let first = if ($entries | is-empty) { null } else { $entries | first }
    if ($first | is-empty) {
        cache-save $cache_file "null"
        return null
    }
    cache-save $cache_file $first
    $first
}

# Extract the uploader-relevant LP usernames from a publication record.
# Returns { signer, creator, maintainer, sponsor } where each value is a
# username string (without the ~) or null. Returns null if no publication.
export def uploader-data [
    package: string
    version: string
]: nothing -> any {
    let pub = (lp-source-publication $package $version)
    if ($pub | is-empty) { return null }
    {
        signer:     (lp-user-from-link ($pub | get -o package_signer_link))
        creator:    (lp-user-from-link ($pub | get -o package_creator_link))
        maintainer: (lp-user-from-link ($pub | get -o package_maintainer_link))
        sponsor:    (lp-user-from-link ($pub | get -o sponsor_link))
    }
}

# Normalize a PPA name to owner/name format.
# Accepts: bare name, owner/name, or ppa:owner/name.
export def normalize-ppa-name [ppa_name: string]: nothing -> string {
    if ($ppa_name | str starts-with "ppa:") {
        $ppa_name | str replace "ppa:" ""
    } else if ("/" in $ppa_name) {
        $ppa_name
    } else {
        $"($env.LAUNCHPAD_NAME)/($ppa_name)"
    }
}

# Walk the Launchpad pagination chain for a person's `ppas` collection.
# Returns the full list of LP entry records.
export def lp-paginate-ppas [user: string]: nothing -> list {
    let first_url = $"($LP_API)/~($user)/ppas?ws.size=75"
    mut out = []
    mut url = $first_url
    loop {
        let raw = (^curl -sfL $url | complete)
        if $raw.exit_code != 0 { break }
        let page = (try { $raw.stdout | from json } catch { null })
        if ($page | is-empty) { break }
        let entries = ($page | get -o entries | default [])
        $out = ($out | append $entries)
        let next = ($page | get -o next_collection_link | default "")
        if ($next | is-empty) { break }
        $url = $next
    }
    $out
}

def lp-ppa-cache-path [user: string]: nothing -> string {
    # One-shot migration: remove pre-subdir flat file if present.
    let stale = (cache-file-flat $"ppas-($user).json")
    if ($stale | path exists) { try { rm -f $stale } }
    cache-file "ppas" $"($user).json"
}

# LP PPA entries for a user, with a 5-minute disk cache. Powers both
# `my ppas` (full entries) and `ppa-completions` (just names).
export def lp-ppa-entries [user?: string]: nothing -> list {
    let me = if ($user | is-empty) { $env.LAUNCHPAD_NAME? | default "" } else { $user }
    if ($me | is-empty) { return [] }
    let path = (lp-ppa-cache-path $me)
    let cached = (cache-load $path 5min)
    if ($cached | is-not-empty) { return $cached }
    let entries = (lp-paginate-ppas $me)
    if ($entries | is-not-empty) {
        cache-save $path $entries
    }
    $entries
}

# Convenience: just the PPA names for `user` (default $env.LAUNCHPAD_NAME).
# Used by the `ppa-completions` completer.
export def lp-ppa-names [user?: string]: nothing -> list<string> {
    lp-ppa-entries $user | get -o name | default []
}
