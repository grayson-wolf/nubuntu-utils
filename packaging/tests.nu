# Autopkgtest running, requesting, and retry commands

use meta.nu [pkg-name]
use build.nu [test-urls]
use ../completions.nu [release-completions, ppa-completions, normalize-ppa-name]
use ../ubuntu-versions.nu [DEVEL_RELEASE]

const EXCUSES_URL = "https://ubuntu-archive-team.ubuntu.com/proposed-migration"

# Validate and return the expanded autopkgtest cookie path.
# Errors with setup instructions if the cookie file is missing.
export def autopkgtest-cookie []: nothing -> string {
    let cookie = ([$env.NUBUNTU_CACHE_DIR "autopkgtest.cookie"] | path join | path expand)
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
    let proposed = if ($params | where key == "all-proposed" | is-not-empty) { " (all-proposed)" } else { "" }
    { label: $"($release) ($package) ($arch)($proposed)", url: $url }
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

# Extract autopkgtest request URLs from `ppa tests --show-url` output.
export def ppa-test-urls [
    ppa_name: string
    --proposed (-p)
]: nothing -> list<string> {
    let raw = (ppa tests $ppa_name --show-url | lines)
    let urls = ($raw
        | where { $in =~ "request.cgi" }
        | each {|line| $line | str trim | split row " " | where { $in starts-with "https://" } | first }
    )
    if $proposed {
        $urls
    } else {
        $urls | where { $in !~ "all-proposed" }
    }
}

# Run autopkgtests in a specific distro's lxd image.
# Defaults to the current development release.
export def testin [
  distro: string@release-completions = $DEVEL_RELEASE # The distro to test in
]: nothing -> nothing {
  sudo autopkgtest-build-lxd $"ubuntu-daily:($distro)"
  sudo autopkgtest . --shell-fail -- lxd $"autopkgtest/ubuntu/($distro)/amd64"
}

# Display autopkgtest request URLs for the current package's PPA upload across all architectures.
# Shows clickable hyperlinks for both base and proposed variants.
export def testurl []: nothing -> nothing {
    let urls = test-urls --proposed

    # Group by arch and display with hyperlinks
    let arches = ($urls | get arch | uniq)
    for arch in $arches {
        let base = ($urls | where { $in.arch == $arch and not $in.proposed } | first | get url)
        let proposed = ($urls | where { $in.arch == $arch and $in.proposed } | first | get url)
        let b_link = $"\e]8;;($base)\e\\[B]\e]8;;\e\\"
        let p_link = $"\e]8;;($proposed)\e\\[P]\e]8;;\e\\"
        print $"($arch): ($b_link) ($p_link)\n($base)\n"
    }
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
            $"https://autopkgtest.ubuntu.com/request.cgi?($params | url build-query)"
        }
    } | flatten
}

# Download and split excuses YAML into per-package text entries.
def fetch-excuses-entries [series: string]: nothing -> list<string> {
    let url = $"($EXCUSES_URL)/($series)/update_excuses.yaml.xz"
    curl -s $url | xz -d | split row "\n- component:"
}

# Parse a raw excuses text entry into a YAML record.
def parse-excuses-entry [entry: string]: nothing -> record {
    let yaml_text = ("component:" + $entry | lines | each {|line|
        if ($line | str starts-with "  ") { $line | str substring 2.. } else { $line }
    } | str join "\n")
    $yaml_text | from yaml
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
    package?: string        # Package name (defaults to cwd package name)
    --series (-s): string = $DEVEL_RELEASE  # Ubuntu series
    --all-proposed (-p)     # Run against all of proposed
    --no-select (-n)        # Skip interactive selection, retry all
    --rev (-r)              # Reverse: find packages blocked BY this package (slow)
]: nothing -> nothing {
    let cookie = autopkgtest-cookie
    let pkg = $package | default (pkg-name)

    let entries = fetch-excuses-entries $series

    let urls = if $rev {
        print -e $"(ansi yellow)⏳ Scanning all entries for packages blocked by ($pkg)... \(this is slow\)(ansi reset)"
        # Pre-filter: only parse entries that textually mention the package in migrate-after context
        let candidates = ($entries | where { $in =~ "migrate-after" and $in =~ $pkg })
        mut fail_count = 0
        let results = ($candidates | par-each --threads 4 {|entry|
            let data = (try { parse-excuses-entry $entry } catch { null })
            if ($data == null) { return [] }
            let migrate_after = ($data | get -o dependencies.migrate-after | default [])
            if not ($pkg in $migrate_after) { return [] }
            collect-regressions $data $series $all_proposed
        } | flatten)
        if ($results | is-empty) and ($candidates | length) > 0 {
            print -e $"(ansi yellow)⚠ Some entries failed to parse; results may be incomplete(ansi reset)"
        }
        $results
    } else {
        # Default --blocks mode: find this package's own entry
        let matches = ($entries | where {|entry|
            let last_line = ($entry | lines | last | str trim)
            $last_line == $"source: ($pkg)"
        })
        if ($matches | is-empty) {
            print $"No excuses entry found for ($pkg) in ($series)."
            return
        }
        let data = (parse-excuses-entry ($matches | first))
        collect-regressions $data $series $all_proposed
    }

    if ($urls | is-empty) {
        print $"No regressions found for ($pkg)."
        return
    }

    let mode = if $rev { "caused by" } else { "blocking" }
    print $"Found ($urls | length) regression\(s\) ($mode) ($pkg)."

    select-and-submit $urls $cookie --no-select=$no_select --header $"Select regressions to retry for ($pkg):"
}

# Format an autopkgtest status with color and optional OSC8 hyperlink.
def format-status [status: string, log_url: string, interactive: bool]: nothing -> string {
    let display = match $status {
        "PASS" => "Pass"
        "OLD_PASS" => "Pass°"
        "REGRESSION" => "Regr ♻"
        "RUNNING" => "Run..."
        "RUNNING-ALWAYSFAIL" => "Run*"
        "RUNNING-REFERENCE" => "Run°"
        "ALWAYSFAIL" => "Fail*"
        "NEUTRAL" => "—"
        "OLD_NEUTRAL" => "—°"
        "IGNORE-FAIL" => "Ign"
        _ => $status
    }
    let colored = match $status {
        "PASS" | "OLD_PASS" => $"(ansi green)($display)(ansi reset)"
        "REGRESSION" => $"(ansi red)($display)(ansi reset)"
        "RUNNING" | "RUNNING-ALWAYSFAIL" | "RUNNING-REFERENCE" => $"(ansi yellow)($display)(ansi reset)"
        "ALWAYSFAIL" | "NEUTRAL" | "OLD_NEUTRAL" | "IGNORE-FAIL" => $"(ansi dark_gray)($display)(ansi reset)"
        _ => $display
    }
    if $interactive and ($log_url | is-not-empty) and $log_url != "https://autopkgtest.ubuntu.com/running" {
        $"\e]8;;($log_url)\e\\($colored)\e]8;;\e\\"
    } else {
        $colored
    }
}

# Statuses that indicate a problem or potential problem requiring attention.
const ACTIONABLE_STATUSES = ["REGRESSION", "RUNNING", "RUNNING-ALWAYSFAIL", "RUNNING-REFERENCE"]

# Show proposed-migration (excuses) status for a package.
# By default, only shows packages with regressions or in-progress tests.
# Prints metadata to stderr; returns the autopkgtest results as a table for pipelines.
export def excuses [
    package?: string                                   # Package name (defaults to cwd package)
    --series (-s): string = $DEVEL_RELEASE             # Ubuntu series
    --raw (-r)                                         # Output raw parsed YAML record
    --all (-a)                                         # Show all test results, not just actionable ones
]: nothing -> table {
    let pkg = $package | default (pkg-name)

    let entries = fetch-excuses-entries $series

    # Find the entry whose last line matches "source: <pkg>" exactly
    let matches = ($entries | where {|entry|
        let last_line = ($entry | lines | last | str trim)
        $last_line == $"source: ($pkg)"
    })

    if ($matches | is-empty) {
        error make { msg: $"Package '($pkg)' not found in ($series) excuses." }
    }

    let data = (parse-excuses-entry ($matches | first))

    if $raw {
        return $data
    }

    # Print metadata to stderr so table output is clean for pipelines
    let old_ver = ($data | get old-version)
    let new_ver = ($data | get new-version)
    let verdict = ($data | get migration-policy-verdict)
    let age = ($data | get -o policy_info.age.current-age | default "?")
    let age_req = ($data | get -o policy_info.age.age-requirement | default "?")

    print -e $"(ansi attr_bold)($pkg)(ansi reset): ($old_ver) → ($new_ver)"
    print -e $"Status: (ansi attr_bold)($verdict)(ansi reset) | Age: ($age) days \(requires: ($age_req)\)"
    print -e ""

    # Build the test results table
    let autopkgtest = ($data | get -o policy_info.autopkgtest)
    if ($autopkgtest | is-empty) {
        print -e "No autopkgtest data available."
        return []
    }

    let interactive = (term size | get columns) > 0

    let tests = ($autopkgtest | reject -o verdict | transpose pkg archinfo)

    # Filter to only actionable rows unless --all is set
    let tests = if $all {
        $tests
    } else {
        $tests | where {|row|
            $row.archinfo | values | any {|info|
                let status = ($info | get 0 | default "")
                $status in $ACTIONABLE_STATUSES
            }
        }
    }

    if ($tests | is-empty) {
        print -e "(no actionable test results — use -a to show all)"
        return []
    }

    # Collect all architectures
    let all_arches = ($tests | get archinfo | each { columns } | flatten | uniq | sort)

    # Build table rows
    let rows = ($tests | each {|row|
        let base = { package: $row.pkg }
        $all_arches | reduce --fold $base {|arch, acc|
            let info = ($row.archinfo | get -o $arch)
            let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
            let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
            let cell = if ($status | is-empty) {
                ""
            } else {
                format-status $status $log_url $interactive
            }
            $acc | insert $arch $cell
        }
    })

    $rows
}
