# Merge-o-Matic merges as a Nushell table.
#
# Mirrors the per-component pages at https://merges.ubuntu.com/<component>.html,
# sourced from the matching <component>.json feed. Each feed row is a 3-way
# version fork — base_version (the common Debian/Ubuntu ancestor), left_version
# (what Ubuntu currently ships) and right_version (the Debian version waiting to
# be merged in) — which maps onto the page's Base / Ubuntu / Debian columns.
#
# Two things the upstream HTML does that we reproduce, and two it doesn't:
#   - reproduce: the tripartite version delta (base→ubuntu→debian) and the
#     "in -proposed" exclusion driven by mom's own #d0d0d0 row shading (the
#     page's "Show Proposed" checkbox toggles exactly those rows).
#   - improve: every version is a clickable link (base/debian → Debian
#     snapshot, ubuntu → Launchpad); the page leaves base and debian bare.

use ../completions.nu [component-completions]
use ../formatting.nu [osc8-link, lp-source-link, version-delta, days-to-duration, with-spinner, bool-glyph]
use cache.nu [cache-file, cache-load, cache-save]

const MERGES_BASE = "https://merges.ubuntu.com"
const COMPONENTS = ["main", "universe", "multiverse", "restricted"]
const MERGES_TTL = 30min

# The merge-o-matic feed name for a component: the auto-merge set is plain
# (<component>), the manual-intervention set is <component>-manual. The two are
# disjoint — auto = mom could merge unattended, manual = needs a human.
def feed-name [component: string, manual: bool]: nothing -> string {
    if $manual { $"($component)-manual" } else { $component }
}

# Fetch one feed's JSON (cached MERGES_TTL). http get parses application/json
# straight to records; a cached empty feed (e.g. multiverse, routinely 0) reads
# back as [] and must NOT be mistaken for a miss, hence the explicit null guard.
def fetch-merges-json [component: string, manual: bool]: nothing -> table {
    let name = (feed-name $component $manual)
    let path = (cache-file "merges" $"($name).json")
    let cached = (cache-load $path $MERGES_TTL)
    if $cached == null {
        let fresh = (http get $"($MERGES_BASE)/($name).json")
        cache-save $path $fresh
        $fresh
    } else {
        $cached
    }
}

# Source packages whose merge is already sitting in -proposed, per mom.
#
# mom shades those rows #d0d0d0 on the component page (class=first marks the
# package-level row; the page's "Show Proposed" filter keys off exactly this
# colour). We scrape that set rather than re-derive it from a 70 MB excuses
# dump. Cached MERGES_TTL alongside the JSON. Degrades to [] (with a stderr
# note) if the page can't be fetched, so a mom outage never hides merges.
def fetch-proposed-set [component: string, manual: bool]: nothing -> list<string> {
    let name = (feed-name $component $manual)
    let path = (cache-file "merges" $"($name).html")
    let cached = (cache-load $path $MERGES_TTL)
    let html = if $cached == null {
        let fresh = (do --ignore-errors { http get --raw $"($MERGES_BASE)/($name).html" } | default "" | into string)
        if ($fresh | is-not-empty) { cache-save $path $fresh }
        $fresh
    } else {
        $cached | into string
    }
    if ($html | is-empty) {
        print -e $"(ansi yellow)merges: could not fetch ($name).html; -proposed filtering unavailable(ansi reset)"
        return []
    }
    # Each proposed package: a #d0d0d0 first-row whose first cell links its
    # merge REPORT. Lazily span from the shade marker to that first REPORT href
    # and take the final path segment (the source package, e.g.
    # libn/libnet-cups-perl/REPORT → libnet-cups-perl).
    $html
    | parse --regex '(?s)bgcolor=#d0d0d0 class=first.*?href="[^"]*?/(?<pkg>[^/"]+)/REPORT"'
    | get pkg
    | uniq
}

# URL for a specific Debian source version on snapshot.debian.org. Debian
# versions carry epochs (`1:`) and pluses (`+`) that must be percent-encoded;
# tildes resolve literally. Empty version → "" (no link).
def snapshot-url [pkg: string, version: string]: nothing -> string {
    if ($version | is-empty) { return "" }
    let enc = ($version | str replace --all ":" "%3A" | str replace --all "+" "%2B")
    $"https://snapshot.debian.org/package/($pkg)/($enc)/"
}

# Fetch + filter one component into raw rows tagged with `component` and
# `in_proposed`. Proposed merges are dropped unless include_proposed.
def fetch-component [component: string, manual: bool, include_proposed: bool]: nothing -> table {
    let json = (fetch-merges-json $component $manual)
    if ($json | is-empty) { return [] }
    let proposed = (fetch-proposed-set $component $manual)
    $json
    | each {|r| $r | insert component $component | insert in_proposed ($r.source_package in $proposed) }
    | where {|r| $include_proposed or (not $r.in_proposed) }
}

# Project one feed record into a display row. Versions are coloured as a
# tripartite delta against the chain base → ubuntu → debian, exactly like
# `sru-list` colours release → updates → proposed: the base tail is dimmed, the
# Ubuntu tail red (it diverges from the Debian target), the Debian tail green
# (the incoming change). Base/Debian link to the exact version on Debian
# snapshot; Ubuntu links to its Launchpad upload.
def build-merge-row [m: record, combined: bool, binaries: bool, show_proposed: bool]: nothing -> record {
    let pkg = $m.source_package
    let base = ($m.base_version | default "")
    let ubuntu = ($m.left_version | default "")
    let debian = ($m.right_version | default "")

    let bu = (version-delta $base $ubuntu --old-color dark_gray)
    let ud = (version-delta $ubuntu $debian)

    let base_cell = if ($base | is-empty) { "" } else { osc8-link (snapshot-url $pkg $base) $bu.old }
    let ubuntu_cell = if ($ubuntu | is-empty) { "" } else { lp-source-link $pkg --version $ubuntu --display $ud.old }
    let debian_cell = if ($debian | is-empty) { "" } else { osc8-link (snapshot-url $pkg $debian) $ud.new }

    mut row = {}
    if $combined { $row = ($row | insert component $m.component) }
    $row = ($row | merge {
        package: (osc8-link $"($m.link)REPORT" $pkg)
        teams: ($m.teams | default [] | str join ", ")
        age: (days-to-duration $m.age)
        base: $base_cell
        ubuntu: $ubuntu_cell
        debian: $debian_cell
    })
    if $show_proposed { $row = ($row | insert proposed (bool-glyph $m.in_proposed)) }
    $row = ($row | insert uploader ($m.user | default "" | str replace -r '\s*<[^>]*>' ''))
    if $binaries { $row = ($row | insert binaries ($m.binaries | default [] | str join ", ")) }
    $row
}

# Show outstanding archive merges (merge-o-matic) as a table.
#
# With no component, fetches all four (main, universe, multiverse, restricted),
# adds a `component` column and sorts oldest-first — a unified "what needs
# merging" board. Pass a component to mirror a single <component>.html page.
#
# Merges already sitting in -proposed are hidden by default (as if the page's
# "Show Proposed" box were unchecked); pass -p to include them, which adds a
# `proposed` ✓/· column. -m switches to the manual-merge feed (the disjoint
# set mom couldn't auto-merge). Binary lists are hidden unless -b.
# Data is cached for 30 minutes.
export def main [
    component?: string@component-completions  # main|universe|multiverse|restricted (default: all four)
    --manual (-m)     # use the manual-merge feed (<component>-manual.json) instead of the auto feed
    --proposed (-p)   # include merges already in -proposed (adds a `proposed` column)
    --binaries (-b)   # include the binary-package list column
    --raw (-r)        # return raw feed records (tagged component/in_proposed) instead of the table
]: nothing -> any {
    let comps = if ($component | is-empty) {
        $COMPONENTS
    } else if ($component in $COMPONENTS) {
        [$component]
    } else {
        error make { msg: $"Unknown component '($component)'. Choose one of: ($COMPONENTS | str join ', ')" }
    }

    let kind = if $manual { "manual merges" } else { "merges" }
    let entries = with-spinner $"Fetching ($kind) \(($comps | str join ', '))..." {
        $comps | par-each {|c| fetch-component $c $manual $proposed } | flatten
    }

    if ($entries | is-empty) {
        let scope = if ($component | is-empty) { "the archive" } else { $component }
        print -e $"(ansi yellow)No outstanding ($kind) in ($scope).(ansi reset)"
        return
    }

    let sorted = ($entries | sort-by age --reverse)
    if $raw { return $sorted }

    let combined = ($component | is-empty)
    $sorted | each {|m| build-merge-row $m $combined $binaries $proposed }
}
