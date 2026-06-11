# SRU (Stable Release Update) tracking commands

use ../completions.nu [release-completions]
use ../formatting.nu [osc8-link, days-to-duration, with-spinner, version-delta]
use ../ubuntu-versions.nu [LATEST_STABLE_RELEASE]

const SRU_REPORT_URL = "https://ubuntu-archive-team.ubuntu.com/sru_report.yaml"

# Format a bug ID with color based on its class, as a clickable hyperlink.
def format-bug [bug: record]: nothing -> string {
    let id = ($bug.id | into string)
    let cls = ($bug.cls | default "")
    let url = ($bug.url | default "")
    let blocked = ($cls =~ "blockproposed")

    let colored = if ($cls =~ "verified") {
        $"(ansi green)($id)(ansi reset)"
    } else if ($cls =~ "verificationfailed") {
        $"(ansi red)($id)(ansi reset)"
    } else if ($cls =~ "incomplete") {
        $"(ansi yellow)($id)(ansi reset)"
    } else if ($cls =~ "removal") {
        $"(ansi dark_gray)($id)(ansi reset)"
    } else if ($cls =~ "messages") {
        $"(ansi xterm_gold1)($id)(ansi reset)"
    } else if ($cls =~ "broken") {
        $"(ansi dark_gray)($id)(ansi reset)"
    } else {
        $id
    }

    let display = if $blocked { $"🚧($colored)" } else { $colored }
    osc8-link $url $display
}

# Show pending SRUs for a given series.
# Returns a table of packages with their versions, uploaders, and bug status.
export def sru-list [
    series?: string@release-completions  # Ubuntu series (default: latest stable)
    --all-series (-A)                    # Show all series combined
]: nothing -> table {
    let s = ($series | default $LATEST_STABLE_RELEASE)
    let entries = (fetch-sru-entries $s $all_series)
    let rows = (build-sru-rows $entries $all_series)
    print-sru-legend $s
    $rows
}

# Fetch the SRU report and return the entries for the requested series
# (or all series, flattened with a `series` field) for further processing.
export def fetch-sru-entries [series: string, all_series: bool]: nothing -> any {
    let data = with-spinner "Fetching SRU report..." { http get $SRU_REPORT_URL | from yaml }
    if $all_series {
        $data | transpose series items | each {|row|
            $row.items | each {|item| $item | insert series $row.series }
        } | flatten
    } else {
        let items = ($data | get -o $series | default [])
        if ($items | is-empty) {
            error make { msg: $"No SRU data for series '($series)'. Available: ($data | columns | str join ', ')" }
        }
        $items
    }
}

# Build the SRU display rows from raw entries.
# Shared by `sru-list` and `my sru` so coloring / column layout stays in one
# place.
export def build-sru-rows [entries: any, all_series: bool]: nothing -> table {
    $entries | each {|entry|
        let bugs_formatted = ($entry.bugs | each {|bug| format-bug $bug } | str join " ")
        let age_dur = (days-to-duration $entry.age)

        let r = ($entry | get -o release_version | default "")
        let u = ($entry | get -o update_version | default "")
        let p = ($entry | get -o proposed_version | default "")

        let cols = if ($u | is-not-empty) and ($p | is-not-empty) {
            let ru = (version-delta $r $u --old-color dark_gray)
            let up = (version-delta $u $p)
            { "-release": $ru.old, "-updates": $up.old, "-proposed": $up.new }
        } else if ($p | is-not-empty) {
            let rp = (version-delta $r $p)
            { "-release": $rp.old, "-updates": "", "-proposed": $rp.new }
        } else {
            { "-release": $r, "-updates": $u, "-proposed": $p }
        }

        let base = {
            package: $entry.pkg
            age: $age_dur
            "-release": $cols."-release"
            "-updates": $cols."-updates"
            "-proposed": $cols."-proposed"
            signer: ($entry | get -o uploaders | default "")
            creator: ($entry | get -o creator | default "")
            bugs: $bugs_formatted
        }

        if $all_series {
            $base | insert series ($entry | get -o series | default "")
        } else {
            $base
        }
    }
}

# Print the bug-status legend to stderr.
export def print-sru-legend [series: string]: nothing -> nothing {
    print -e $"Bug Legend: "
    print -e $"  (ansi green)Verified(ansi reset) / (ansi red)Verification failed(ansi reset) / (ansi yellow)Incomplete(ansi reset) / (ansi dark_gray)Candidate for Removal(ansi reset) / (ansi xterm_gold1)Has messages(ansi reset)"
    print -e $"  🚧 - Tagged with block-proposed-($series)"
    print -e $""
}
