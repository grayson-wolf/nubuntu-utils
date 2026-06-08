# SRU (Stable Release Update) tracking commands

use ../completions.nu [release-completions]
use ../formatting.nu [osc8-link, days-to-duration]
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
    let data = (http get $SRU_REPORT_URL | from yaml)

    let entries = if $all_series {
        $data | transpose series items | each {|row|
            $row.items | each {|item| $item | insert series $row.series}
        } | flatten
    } else {
        let s = ($series | default $LATEST_STABLE_RELEASE)
        let items = ($data | get -o $s | default [])
        if ($items | is-empty) {
            error make { msg: $"No SRU data for series '($s)'. Available: ($data | columns | str join ', ')" }
        }
        $items
    }

    let rows = ($entries | each {|entry|
        let bugs_formatted = ($entry.bugs | each {|bug| format-bug $bug } | str join " ")
        let age_dur = (days-to-duration $entry.age)

        let base = {
            package: $entry.pkg
            age: $age_dur
            "-release": ($entry | get -o release_version | default "")
            "-updates": ($entry | get -o update_version | default "")
            "-proposed": ($entry | get -o proposed_version | default "")
            signer: ($entry | get -o uploaders | default "")
            creator: ($entry | get -o creator | default "")
            bugs: $bugs_formatted
        }

        if $all_series {
            $base | insert series ($entry | get -o series | default "")
        } else {
            $base
        }
    })

    $rows
}
