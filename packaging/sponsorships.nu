# Ubuntu sponsorship miner (UDD) helpers.
#
# Wraps the UDD "Ubuntu Sponsorship Miner" CGI, which records sponsored
# uploads (sponsor + sponsoree). The endpoint matches on real names / emails
# only — never Launchpad usernames — so callers resolve LP names to display
# names (see `lp-display-name` in launchpad.nu) before querying here.

use cache.nu *

const MINER_URL = "https://udd.debian.org/cgi-bin/ubuntu-sponsorships.cgi"

# Decode the handful of HTML entities the miner emits and strip any tags.
def html-clean [s: string]: nothing -> string {
    $s
    | str replace -r -a '<[^>]+>' ''
    | str replace -a '&lt;' '<'
    | str replace -a '&gt;' '>'
    | str replace -a '&amp;' '&'
    | str replace -a '&quot;' '"'
    | str replace -a '&#39;' "'"
    | str trim
}

# Pull an email out of a `title="Real Name <addr>"` attribute, or "" if the
# miner recorded no address (it stores "N/A").
def email-from-title [attr: string]: nothing -> string {
    let m = ($attr | str replace -a '&lt;' '<' | str replace -a '&gt;' '>'
        | parse -r '<(?P<addr>[^<>]+)>')
    if ($m | is-empty) { return "" }
    let addr = ($m | first | get addr | str trim)
    if $addr == "N/A" { "" } else { $addr }
}

# Parse the miner's HTML table into clean records. One record per data row;
# the `<th>` header row is dropped (it carries no `<td>` cells).
def parse-sponsorships [html: string]: nothing -> table {
    $html
    | parse -r '(?s)<tr>(?P<row>.*?)</tr>'
    | get row
    | each {|row|
        let cells = ($row | parse -r '(?s)<td(?P<attr>[^>]*)>(?P<cell>.*?)</td>')
        if ($cells | length) < 8 { return null }
        let c = ($cells | get cell)
        let a = ($cells | get attr)
        let bugs = ($c | get 6 | parse -r 'bugs/(?P<id>\d+)' | get id | each { into int })
        {
            date:           (html-clean ($c | get 0))
            sponsor:        (html-clean ($c | get 1))
            sponsor_email:  (email-from-title ($a | get 1))
            sponsoree:      (html-clean ($c | get 2))
            sponsoree_email: (email-from-title ($a | get 2))
            package:        (html-clean ($c | get 3))
            package_url:    (($c | get 3 | parse -r 'href="(?P<u>[^"]+)"' | get -o u.0) | default "")
            version:        (html-clean ($c | get 4))
            version_url:    (($c | get 4 | parse -r 'href="(?P<u>[^"]+)"' | get -o u.0) | default "")
            series:         (html-clean ($c | get 5))
            bugs:           $bugs
            action:         (html-clean ($c | get 7))
        }
    }
    | where { $in != null }
}

# Fetch sponsorship rows for a real `name`. By default `name` is the
# sponsoree (packages sponsored FOR them); with `--given` it is the sponsor
# (packages they sponsored for others). Disk-cached 5 minutes.
export def fetch-sponsorships [
    name: string
    --given (-g)
]: nothing -> table {
    if ($name | is-empty) { return [] }
    let role = if $given { "sponsor" } else { "sponsoree" }
    let path = (cache-file "sponsorships" $"($role)-(cache-key $name).json")
    let cached = (cache-load $path 5min)
    if ($cached | is-not-empty) { return $cached }

    let params = if $given {
        [--data-urlencode $"sponsor=($name)" --data-urlencode "sponsor_search=name"
         --data-urlencode "sponsoree=" --data-urlencode "sponsoree_search=name"]
    } else {
        [--data-urlencode "sponsor=" --data-urlencode "sponsor_search=name"
         --data-urlencode $"sponsoree=($name)" --data-urlencode "sponsoree_search=name"]
    }
    let raw = (^curl -sfG $MINER_URL --data-urlencode "render=html" ...$params | complete)
    if $raw.exit_code != 0 { return [] }
    let rows = (parse-sponsorships $raw.stdout)
    if ($rows | is-not-empty) { cache-save $path $rows }
    $rows
}
