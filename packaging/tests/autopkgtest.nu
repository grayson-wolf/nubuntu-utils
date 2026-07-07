# Autopkgtest submission pipeline: cookie management, request submission,
# interactive selection, and regression retry.

use ../meta.nu [pkg-name]
use ../navigation.nu [poc]
use ../../completions.nu [pkg-completions, release-completions]
use ../../ubuntu-versions.nu [DEVEL_RELEASE, ARCHES]
use ../cache.nu [cache-file-flat]
use fetch.nu [fetch-excuses]
use log-parsing.nu [request-url]

# Return the expanded autopkgtest cookie path (does not check existence).
export def autopkgtest-cookie-path []: nothing -> string {
    cache-file-flat "autopkgtest.cookie"
}

# Validate and return the expanded autopkgtest cookie path.
# Errors with setup instructions if the cookie file is missing.
export def autopkgtest-cookie []: nothing -> string {
    let cookie = autopkgtest-cookie-path
    if not ($cookie | path exists) {
        error make { msg: $"Autopkgtest cookie not found at ($cookie). Export your autopkgtest.ubuntu.com session cookie to this file." }
    }
    $cookie
}

# Submit a single autopkgtest request URL using the cookie.
# Returns the HTTP status code as a string.
export def submit-autopkgtest [url: string, cookie: string]: nothing -> string {
    curl --cookie $cookie -o /dev/null --silent --head --write-out '%{http_code}' $url | str trim
}

# Parse an autopkgtest request URL into a human-readable label.
# Returns a record with {label, url} for use in gum choose.
export def label-autopkgtest-url [url: string]: nothing -> record<label: string, url: string> {
    let params = ($url | url parse | get params)
    let release = ($params | where key == "release" | get value | first | default "?")
    let package = ($params | where key == "package" | get value | first | default "?")
    let arch = ($params | where key == "arch" | get value | first | default "?")
    let proposed = if ($params | where key == "all-proposed" | is-not-empty) { "-proposed" } else { "" }
    let trigger = ($params | where key == "trigger" | get value | first | default "?")
    { label: $"($release)($proposed) ($package) ($arch) \(($trigger)\)", url: $url }
}

# Interactively select autopkgtest URLs via gum choose, then submit them in parallel.
# If --no-select, submits all without prompting.
export def select-and-submit [
    urls: list<string>
    cookie: string
    --no-select
    --header: string = "Select tests to submit:"
]: nothing -> nothing {
    let items = ($urls | each {|url| label-autopkgtest-url $url })

    let selected_urls = if $no_select {
        $urls
    } else {
        let choices = ($items | each { $"($in.label)|($in.url)" })
        let picked = ($choices | str join "\n" | gum choose --no-limit --selected="*" --label-delimiter="|" --header $header)
        if ($picked | is-empty) {
            print "No tests selected."
            return
        }
        $picked | lines
    }

    print $"Submitting ($selected_urls | length) test request\(s\)..."

    $selected_urls | par-each {|url|
        let result = (submit-autopkgtest $url $cookie)
        let label = (label-autopkgtest-url $url).label
        print $"  ($label): ($result)"
    } | ignore
}

# Extract regression request URLs from a parsed excuses entry.
def collect-regressions [data: record, series: string, all_proposed: bool]: nothing -> list<string> {
    let autopkgtest = ($data | get -o policy_info.autopkgtest | default {})
    let source = ($data | get source)
    let new_ver = ($data | get new-version)
    let trigger = $"($source)/($new_ver)"

    $autopkgtest | reject -o verdict | transpose pkg archinfo | each {|row|
        let test_pkg = ($row.pkg | split row "/" | first)
        $row.archinfo | transpose arch state_info | where { ($in.state_info | get 0) == "REGRESSION" } | each {|entry|
            let params = {
                release: $series
                arch: $entry.arch
                package: $test_pkg
                trigger: $trigger
            }
            let params = if $all_proposed { $params | insert all-proposed "1" } else { $params }
            (request-url $params)
        }
    } | flatten
}

# Retry autopkgtest regressions that block a package's migration.
# In default mode (--blocks), retries regressions in the package's own excuses entry.
# With --rev, scans all entries to find packages whose migration depends on this package
# (slow — parses many YAML entries, but pre-filters and parallelizes).
#
# Requires an autopkgtest.ubuntu.com session cookie at $NUBUNTU_CACHE_DIR/autopkgtest.cookie
# (default: ~/.cache/nubuntu-utils/autopkgtest.cookie). To create it, export your browser's
# session and SRVNAME cookies:
#
#   # bash:
#   printf "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tsession\tVALUE\n" > ~/.cache/nubuntu-utils/autopkgtest.cookie
#   printf "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tSRVNAME\tVALUE\n" >> ~/.cache/nubuntu-utils/autopkgtest.cookie
#
#   # nushell:
#   "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tsession\tVALUE\n" | save $"($env.NUBUNTU_CACHE_DIR)/autopkgtest.cookie"
#   "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tSRVNAME\tVALUE\n" | save --append $"($env.NUBUNTU_CACHE_DIR)/autopkgtest.cookie"
#
# Or, if you have an API key:
#
#   # bash:
#   printf "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tX-Api-Key\tuser:KEY\n" > ~/.cache/nubuntu-utils/autopkgtest.cookie
#
#   # nushell:
#   "autopkgtest.ubuntu.com\tTRUE\t/\tTRUE\t0\tX-Api-Key\tuser:KEY\n" | save $"($env.NUBUNTU_CACHE_DIR)/autopkgtest.cookie"
#
# The cookie is valid for one month.
export def retry-regressions [
    package?: string@pkg-completions        # Package name (defaults to cwd package name)
    --series (-s): string = $DEVEL_RELEASE  # Ubuntu series
    --all-proposed (-p)     # Run against all of proposed
    --no-select (-n)        # Skip interactive selection, retry all
    --rev (-r)              # Reverse: find packages blocked BY this package (slow)
]: nothing -> nothing {
    let cookie = autopkgtest-cookie
    let pkg = $package | default (pkg-name)

    let sources = fetch-excuses $series | get sources

    let urls = if $rev {
        print -e $"(ansi yellow)⏳ Scanning entries for packages blocked by ($pkg)...(ansi reset)"
        let candidates = ($sources | where {|row|
            let migrate_after = ($row | get -o dependencies.migrate-after | default [])
            $pkg in $migrate_after
        })
        $candidates | each {|data|
            collect-regressions $data $series $all_proposed
        } | flatten
    } else {
        # Default --blocks mode: find this package's own entry
        let matches = ($sources | where source == $pkg)
        if ($matches | is-empty) {
            print $"No excuses entry found for ($pkg) in ($series)."
            return
        }
        collect-regressions ($matches | first) $series $all_proposed
    }

    if ($urls | is-empty) {
        print $"No regressions found for ($pkg)."
        return
    }

    let mode = if $rev { "caused by" } else { "blocking" }
    print $"Found ($urls | length) regression\(s\) ($mode) ($pkg)."

    select-and-submit $urls $cookie --no-select=$no_select --header $"Select regressions to retry for ($pkg):"
}

# Submit migration-reference/0 autopkgtests for a source package.
# Requires an autopkgtest.ubuntu.com session cookie — see `retry-regressions --help`.
export def migration-reference [
    package?: string@pkg-completions              # Source package (defaults to cwd package)
    --series (-s): string@release-completions = $DEVEL_RELEASE  # Ubuntu series
]: nothing -> nothing {
    let cookie = autopkgtest-cookie
    let pkg = if ($package | is-empty) { pkg-name } else { $package }

    # Check ownership and warn if teams are responsible for this package
    let teams = poc $pkg
    if not ($teams | is-empty) {
        let teams_display = ($teams | each {|t| $"~($t)" } | str join ", ")
        gum confirm $"($pkg) is owned by ($teams_display). Consult them before re-running migration-reference tests. Continue?"
    }

    # Build one URL per arch and submit via interactive selection
    let urls = ($ARCHES | each {|arch|
        request-url { release: $series, package: $pkg, arch: $arch, trigger: "migration-reference/0" }
    })

    select-and-submit $urls $cookie --header $"Select migration-reference tests for ($pkg) / ($series):"
}
