# Autopkgtest running, requesting, and retry commands

use meta.nu [pkg-name]
use build.nu [test-urls]
use ../completions.nu [release-completions, ppa-completions, normalize-ppa-name, pkg-completions]
use ../formatting.nu [osc8-link, lp-bug-link, days-to-duration]
use ../ubuntu-versions.nu [DEVEL_RELEASE]

const EXCUSES_URL = "https://ubuntu-archive-team.ubuntu.com/proposed-migration"

# Download and parse the full excuses YAML for a series.
# Returns the `sources` table from the parsed YAML.
def fetch-excuses [series: string]: nothing -> table {
    let url = $"($EXCUSES_URL)/($series)/update_excuses.yaml.xz"
    curl -s $url | xz -d | from yaml | get sources
}

# Return the expanded autopkgtest cookie path (does not check existence).
export def autopkgtest-cookie-path []: nothing -> string {
    [$env.NUBUNTU_CACHE_DIR "autopkgtest.cookie"] | path join | path expand
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
        let b_link = (osc8-link $base "[B]")
        let p_link = (osc8-link $proposed "[P]")
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

    let sources = fetch-excuses $series

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

# Format an autopkgtest status with color and OSC8 hyperlink.
def format-status [status: string, log_url: string]: nothing -> string {
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
    let link_url = if $log_url == "https://autopkgtest.ubuntu.com/running" { "" } else { $log_url }
    osc8-link $link_url $colored
}

# Statuses that indicate a problem or potential problem requiring attention.
const ACTIONABLE_STATUSES = ["REGRESSION", "RUNNING", "RUNNING-ALWAYSFAIL", "RUNNING-REFERENCE"]

# Show proposed-migration (excuses) status for a package.
# By default, only shows packages with regressions or in-progress tests.
# Prints metadata to stderr; returns the autopkgtest results as a table for pipelines.
export def excuses [
    package?: string@pkg-completions                   # Package name (defaults to cwd package)
    --series (-s): string = $DEVEL_RELEASE             # Ubuntu series
    --raw (-r)                                         # Output raw parsed YAML record
    --all (-a)                                         # Show all test results, not just actionable ones
    --why (-w)                                         # Show blocking dependencies' test results
]: nothing -> table {
    let pkg = $package | default (pkg-name)

    let sources = fetch-excuses $series

    let matches = ($sources | where source == $pkg)

    if ($matches | is-empty) {
        error make { msg: $"Package '($pkg)' not found in ($series) excuses." }
    }

    let data = ($matches | first)

    if $raw {
        return $data
    }

    # Print metadata to stderr so table output is clean for pipelines
    let old_ver = ($data | get old-version)
    let new_ver = ($data | get new-version)
    let verdict = ($data | get migration-policy-verdict)
    let age = ($data | get -o policy_info.age.current-age | default "?")
    let age_req = ($data | get -o policy_info.age.age-requirement | default "?")

    let verdict_display = match $verdict {
        "PASS" => $"(ansi green)Migrating(ansi reset)"
        "REJECTED_PERMANENTLY" => $"(ansi red)Blocked \(permanent\)(ansi reset)"
        "REJECTED_TEMPORARILY" => $"(ansi yellow)Blocked \(temporary\)(ansi reset)"
        "REJECTED_CANNOT_DETERMINE_IF_PERMANENT" => $"(ansi yellow)Blocked \(investigating\)(ansi reset)"
        "REJECTED_BLOCKED_BY_ANOTHER_ITEM" => $"(ansi magenta)Blocked by dependency(ansi reset)"
        "REJECTED_WAITING_FOR_ANOTHER_ITEM" => $"(ansi cyan)Waiting on dependency(ansi reset)"
        _ => $verdict
    }

    let age_dur = if ($age | describe) == "string" { $age } else { (days-to-duration $age) }
    let age_req_dur = if ($age_req | describe) == "string" { $age_req } else if $age_req == 0 { "none" } else { (days-to-duration $age_req) | into string }

    print -e $"(ansi attr_bold)($pkg)(ansi reset): ($old_ver) → ($new_ver)"
    print -e $"Status: ($verdict_display) | Age: ($age_dur) \(required: ($age_req_dur)\)"

    # Show dependency info when present
    let blocked_by = ($data | get -o dependencies.blocked-by | default [])
    let migrate_after = ($data | get -o dependencies.migrate-after | default [])
    if not ($blocked_by | is-empty) {
        print -e $"Blocked by: (ansi red)($blocked_by | str join ', ')(ansi reset)"
    }
    if not ($migrate_after | is-empty) {
        print -e $"Migrate after: (ansi yellow)($migrate_after | str join ', ')(ansi reset)"
    }

    # Show component mismatches (compacted by architecture)
    let mismatches = ($data | get -o excuses | default [] | where {|e| $e =~ "cannot depend"})
    if not ($mismatches | is-empty) {
        let parsed = ($mismatches | each {|line|
            let parts = ($line | parse "{pkg}/{arch} in {src} cannot depend on {dep} in {dest}")
            if ($parts | is-empty) { null } else { $parts | first }
        } | where {|r| $r != null})
        if not ($parsed | is-empty) {
            let grouped = ($parsed | group-by {|r| $"($r.pkg) in ($r.src) → ($r.dep) in ($r.dest)"})
            print -e $"(ansi red)Component mismatches:(ansi reset)"
            $grouped | transpose key rows | each {|g|
                let arches = ($g.rows | get arch | uniq | str join ", ")
                let r = ($g.rows | first)
                print -e $"  ($r.pkg)/{($arches)} in ($r.src) → ($r.dep) in ($r.dest)"
            } | ignore
        }
    }

    # Show missing builds
    let missing_builds = ($data | get -o missing-builds | default {})
    let missing_arches = ($missing_builds | get -o on-architectures | default [])
    if not ($missing_arches | is-empty) {
        print -e $"(ansi red)Missing builds:(ansi reset) ($missing_arches | str join ', ')"
    }
    let missing_unimportant = ($missing_builds | get -o on-unimportant-architectures | default [])
    if not ($missing_unimportant | is-empty) {
        print -e $"(ansi dark_gray)Missing builds \(unimportant\):(ansi reset) ($missing_unimportant | str join ', ')"
    }

    # Show old binaries (NBS cruft)
    let old_bins = ($data | get -o old-binaries | default {})
    if not ($old_bins | is-empty) and ($old_bins | describe | str starts-with "record") {
        let nbs_entries = ($old_bins | transpose ver bins | each {|entry|
            let names = if ($entry.bins | length) > 3 {
                let remaining = ($entry.bins | length) - 3
                $"($entry.bins | first 3 | str join ', ') + ($remaining) more"
            } else {
                $entry.bins | str join ", "
            }
            $"($names) \(from ($entry.ver)\)"
        })
        print -e $"(ansi yellow)Old binaries \(NBS\):(ansi reset) ($nbs_entries | str join '; ')"
    }

    # Show block bugs (when verdict is not PASS)
    let block_bugs = ($data | get -o policy_info.block-bugs | default {})
    if not ($block_bugs | is-empty) and ($block_bugs | describe | str starts-with "record") {
        let bb_verdict = ($block_bugs | get -o verdict | default "PASS")
        if $bb_verdict != "PASS" {
            let bug_ids = ($block_bugs | reject -o verdict | columns)
            let bug_display = ($bug_ids | each {|id|
                lp-bug-link ($id | into int) --color (ansi red)
            } | str join ", ")
            let reason = match $bb_verdict {
                "REJECTED_PERMANENTLY" => "permanently blocked"
                _ => $bb_verdict
            }
            print -e $"(ansi red)Block bugs:(ansi reset) ($bug_display) \(($reason)\)"
        }
    }

    # Show hints (manual blocks)
    let hints_list = ($data | get -o hints | default [])
    if not ($hints_list | is-empty) {
        let hint_display = ($hints_list | each {|h|
            $"($h.hint-type) by ($h.hint-from)"
        } | str join ", ")
        print -e $"(ansi magenta)Hints:(ansi reset) ($hint_display)"
    }

    # Show new binaries (from detailed-info)
    let detailed = ($data | get -o detailed-info | default [])
    let new_bins = ($detailed | where {|d| $d =~ "^New binary:"} | each {|d| $d | str replace "New binary: " ""})
    if not ($new_bins | is-empty) {
        print -e $"(ansi green)New binaries:(ansi reset) ($new_bins | str join ', ')"
    }

    print -e ""

    # --why mode: show combined test table for all blocking dependencies
    if $why {
        let dep_pkgs = ($blocked_by | append $migrate_after)
        if ($dep_pkgs | is-empty) {
            print -e "No blocking dependencies to investigate."
            return []
        }
        let all_rows = ($dep_pkgs | each {|dep_pkg|
            let dep_data = ($sources | where source == $dep_pkg)
            if ($dep_data | is-empty) { return [] }
            let dep_entry = ($dep_data | first)
            let autopkgtest = ($dep_entry | get -o policy_info.autopkgtest | default {})
            if ($autopkgtest | is-empty) { return [] }
            let tests = ($autopkgtest | reject -o verdict | transpose pkg archinfo)
            let tests = if $all { $tests } else {
                $tests | where {|row|
                    $row.archinfo | values | any {|info|
                        let status = ($info | get 0 | default "")
                        $status in $ACTIONABLE_STATUSES
                    }
                }
            }
            $tests | each {|row|
                { blocker: $dep_pkg, pkg: $row.pkg, archinfo: $row.archinfo }
            }
        } | flatten)

        if ($all_rows | is-empty) {
            print -e "\(no actionable test results in blocking dependencies\)"
            return []
        }

        let all_arches = ($all_rows | get archinfo | each { columns } | flatten | uniq | sort)
        let rows = ($all_rows | each {|row|
            let base = { blocker: $row.blocker, package: $row.pkg }
            $all_arches | reduce --fold $base {|arch, acc|
                let info = ($row.archinfo | get -o $arch)
                let status = if ($info | is-not-empty) { $info | get 0 | default "" } else { "" }
                let log_url = if ($info | is-not-empty) { $info | get 1 | default "" } else { "" }
                let cell = if ($status | is-empty) { "" } else { format-status $status $log_url }
                $acc | insert $arch $cell
            }
        })
        return $rows
    }

    # Build the test results table for the package itself
    let autopkgtest = ($data | get -o policy_info.autopkgtest)
    if ($autopkgtest | is-empty) {
        print -e "No autopkgtest data available."
        return []
    }

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
        print -e "\(no actionable test results — use -a to show all\)"
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
                format-status $status $log_url
            }
            $acc | insert $arch $cell
        }
    })

    $rows
}
