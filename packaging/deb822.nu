# deb822 / archive-index helpers
use cache.nu [cache-file, cache-fresh, cache-key]
use http.nu [http-get]

const INDEX_TTL = 10min

# Fetch a pocket index (Packages or Sources), cached to disk. Returns the cache FILE PATH
export def fetch-index [
    series: string
    pocket: string
    component: string
    kind: string              # Packages | Sources
    --ttl: duration = $INDEX_TTL
]: nothing -> string {
    let suite = if ($pocket == "release") { $series } else { $"($series)-($pocket)" }
    let key = (cache-key $"($suite)-($component)-($kind).txt")
    let path = (cache-file "deb822" $key)
    if (cache-fresh $path $ttl) { return $path }

    let sub = if ($kind == "Packages") { $"binary-amd64/Packages.xz" } else { "source/Sources.xz" }
    let url = $"https://archive.ubuntu.com/ubuntu/dists/($suite)/($component)/($sub)"
    (http-get --raw $url) | ^xz -d | decode utf-8 | save -f $path
    $path
}

# Pull one field out of a deb822 stanza
export def field [stanza: string, name: string]: nothing -> string {
    let prefix = $"($name): "
    mut collecting = false
    mut parts = []
    for line in ($stanza | lines) {
        if ($line | str starts-with $prefix) {
            $collecting = true
            $parts = ($parts | append ($line | str substring ($prefix | str length)..))
        } else if $collecting {
            if ($line | str starts-with " ") {
                $parts = ($parts | append ($line | str trim))
            } else {
                $collecting = false
            }
        }
    }
    $parts | str join " "
}

# Parse the fields we care about out of a single binary-package stanza.
export def parse-bin-stanza [stanza: string]: nothing -> record {
    {
        name: (field $stanza "Package")
        version: (field $stanza "Version")
        provides: (field $stanza "Provides" | split row "," | each { str trim } | where { is-not-empty })
        depends: (field $stanza "Depends" | split row "," | each { str trim } | where { is-not-empty })
        source: (field $stanza "Source" | str replace -r '\s*\(.*\)$' '')
    }
}

# Parse the fields we care about out of a single source-package stanza.
export def parse-src-stanza [stanza: string]: nothing -> record {
    let bd = ([(field $stanza "Build-Depends") (field $stanza "Build-Depends-Indep") (field $stanza "Build-Depends-Arch")]
        | where { is-not-empty } | str join ", ")
    {
        name: (field $stanza "Package")
        version: (field $stanza "Version")
        binaries: (field $stanza "Binary" | split row "," | each { str trim } | where { is-not-empty })
        build_deps: ($bd | split row "," | each { str trim | str replace -r '\s*[(\[<].*$' '' } | where { is-not-empty } | uniq)
    }
}

# The raw stanza text for a package name across the given index files, or "" if absent
export def stanza-raw [files: list<string>, name: string]: nothing -> string {
    # Escape regex metachars in the package name, then build the multiline stanza pattern by concatenation
    let esc = ($name | str replace -a -r '[.+*?^$(){}\[\]|\\]' '\$0')
    let pat = ('^Package: ' + $esc + '\n(?:\S.*\n| .*\n)*')
    for f in $files {
        # Use `rg` to extract the stanza (this is far faster than scanning a ~70MB string in nu).
        let r = (^rg --multiline --no-filename -o $pat $f | complete)
        if $r.exit_code == 0 and ($r.stdout | str trim | is-not-empty) {
            return $r.stdout
        }
    }
    ""
}

# Does any of the given files mention the literal string (e.g. a hashed virtual)?
export def files-contain [files: list<string>, needle: string]: nothing -> bool {
    for f in $files {
        if (^rg -F -q $needle $f | complete | get exit_code) == 0 { return true }
    }
    false
}

# The name of the binary package whose stanza Provides the given virtual atom, or "" if none.
export def provider-of [files: list<string>, atom: string]: nothing -> string {
    let esc = ($atom | str replace -a -r '[.+*?^$(){}\[\]|\\]' '\$0')
    for f in $files {
        # Match only Provides: lines carrying the atom (fixed-string body).
        let hit = (^rg -n --no-filename -e ('^Provides:.*\b' + $esc + '\b') $f | complete)
        if $hit.exit_code != 0 { continue }
        # First matching line number.
        let lineno = ($hit.stdout | lines | first | default "" | split row ':' | first | default "")
        if ($lineno | is-empty) { continue }
        # Walk backwards to the nearest Package: line at or above it.
        let pkg = (^awk -v $"n=($lineno)" '
            NR <= n { if ($0 ~ /^Package: /) pkg = substr($0, 10) }
            NR == n { print pkg; exit }
        ' $f | complete)
        if $pkg.exit_code == 0 and ($pkg.stdout | str trim | is-not-empty) {
            return ($pkg.stdout | str trim)
        }
    }
    ""
}

# Compare versions per a Debian relation operator. Uses `dpkg --compare-versions`.
# An empty/unknown operator is treated as satisfied (no constraint to violate).
export def version-satisfies [have: string, op: string, want: string]: nothing -> bool {
    if ($op | is-empty) { return true }
    let dpkg_op = (match $op { "<<" => "lt", "<=" => "le", "=" => "eq", ">=" => "ge", ">>" => "gt", _ => "" })
    if ($dpkg_op | is-empty) { return true }
    let r = (^dpkg --compare-versions $have $dpkg_op $want | complete)
    $r.exit_code == 0
}
