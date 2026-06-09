# Launchpad webservice helpers.
# Anonymous read-only queries against the LP REST API; cached on disk where
# the underlying data is immutable.

const LP_API = "https://api.launchpad.net/devel"

# Cache directory for LP publication records (immutable once published).
def lp-pub-cache-dir []: nothing -> string {
    let dir = ([$env.NUBUNTU_CACHE_DIR "lp-publications"] | path join)
    if not ($dir | path exists) { mkdir $dir }
    $dir
}

# Make a filesystem-safe filename for a (package, version) cache key.
def cache-key [package: string, version: string]: nothing -> string {
    let safe_ver = ($version | str replace --all ":" "_" | str replace --all "/" "_" | str replace --all "~" "_")
    $"($package)_($safe_ver).json"
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
    let key = (cache-key $package $version)
    let cache_file = ([(lp-pub-cache-dir) $key] | path join)
    if ($cache_file | path exists) {
        let cached = (open $cache_file)
        # Cached "null" sentinel means we already confirmed nothing exists.
        if ($cached | describe) == "string" and $cached == "null" { return null }
        return $cached
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
        "null" | save -f $cache_file
        return null
    }
    $first | save -f $cache_file
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
