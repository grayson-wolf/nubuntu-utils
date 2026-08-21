# Canonical lists of source package names
#
# Source of truth: the archive `override.<series>.<component>.src` indices.
# Both Ubuntu and Debian publish these; each line is `<package>\t<section>`,
# so we keep only the name. Ubuntu serves them plain (~1.2MB),
# Debian gzipped (~240KB).

use cache.nu *
use ../ubuntu-versions.nu [DEVEL_RELEASE]

const CACHE_TTL = 1day

# Per-distro index location, components, and whether the files are gzipped.
const DISTROS = {
    ubuntu: {
        base: "https://archive.ubuntu.com/ubuntu/indices"
        components: [main universe multiverse restricted]
        gz: false
    }
    debian: {
        base: "https://deb.debian.org/debian/indices"
        components: [main contrib non-free non-free-firmware]
        gz: true
    }
}

def cache-path [distro: string, series: string]: nothing -> string {
    cache-file "source-packages" $"($distro)-($series).nuon"
}

# Resolve the effective series for a distro when none is passed.
def default-series [distro: string]: nothing -> string {
    if $distro == "ubuntu" { $DEVEL_RELEASE } else { "sid" }
}

# Fetch one override .src index and return its package names.
def fetch-component [base: string, series: string, comp: string, gz: bool]: nothing -> list<string> {
    let ext = if $gz { "src.gz" } else { "src" }
    let url = $"($base)/override.($series).($comp).($ext)"
    let raw = (^curl -sfL $url | complete)
    if $raw.exit_code != 0 { return [] }
    let text = if $gz {
        let dec = ($raw.stdout | ^gzip -d | complete)
        if $dec.exit_code != 0 { return [] }
        $dec.stdout
    } else {
        $raw.stdout
    }
    $text | lines | each {|l| $l | split row "\t" | get 0? } | where { $in | is-not-empty }
}

# Fetch and merge the override .src indices for all components of a distro
# series. Returns a sorted unique list of source package names.
def fetch-source-packages [distro: string, series: string]: nothing -> list<string> {
    let d = ($DISTROS | get $distro)
    $d.components | par-each --threads 4 {|comp|
        fetch-component $d.base $series $comp $d.gz
    } | flatten | uniq | sort
}

# Return the cached list of source package names for a distro series,
# refreshing from the archive when stale or absent. Returns an empty list if
# the fetch fails and there is no cache (e.g. offline first run) — callers
# treat empty as "cannot validate", not "package does not exist".
export def source-package-names [
    --distro: string = "ubuntu"  # ubuntu | debian
    series?: string              # series/suite (default: devel for ubuntu, sid for debian)
]: nothing -> list<string> {
    let s = ($series | default (default-series $distro))
    let path = (cache-path $distro $s)
    let cached = (cache-load $path $CACHE_TTL)
    if ($cached | is-not-empty) { return $cached }
    let fresh = (fetch-source-packages $distro $s)
    if ($fresh | is-not-empty) {
        cache-save $path $fresh
        return $fresh
    }
    # Fetch failed; fall back to a stale cache if one exists rather than nothing.
    if ($path | path exists) {
        try { open $path } catch { [] }
    } else {
        []
    }
}

# Check whether a name is a real source package in a distro.
export def is-source-package [
    name: string
    --distro: string = "ubuntu"  # ubuntu | debian
    series?: string              # series/suite (default: devel for ubuntu, sid for debian)
]: nothing -> any {
    let names = (source-package-names --distro $distro $series)
    if ($names | is-empty) { return null }
    $name in $names
}

# Check whether a name is a known source package in Ubuntu OR Debian
export def is-known-source-package [name: string]: nothing -> any {
    let ubuntu = (is-source-package $name --distro ubuntu)
    if $ubuntu == true { return true }
    let debian = (is-source-package $name --distro debian)
    if $ubuntu == null and $debian == null { return null }
    ($ubuntu == true) or ($debian == true)
}
