# Dependency pocket/component analysis commands

use ../formatting.nu [with-spinner, lp-source-link, lp-source-url, osc8-link]
use ../completions.nu [pkg-completions]

# Get the archive component for a real binary package via apt-cache policy.
# Returns "" if no candidate component is found (likely a virtual package).
def policy-component [pkg: string]: nothing -> string {
    let output = (apt-cache policy $pkg | complete)
    if $output.exit_code != 0 { return "" }
    $output.stdout
    | lines
    | where { $in =~ '/(?:main|restricted|universe|multiverse)\s' }
    | first
    | default ""
    | parse -r '(?<component>main|restricted|universe|multiverse)'
    | get component
    | first
    | default ""
}

# Look up the first concrete provider of a virtual package via apt-cache showpkg.
# Returns "" if `pkg` is not virtual / has no providers.
def virtual-provider [pkg: string]: nothing -> string {
    let output = (apt-cache showpkg $pkg | complete)
    if $output.exit_code != 0 { return "" }
    # Take lines after "Reverse Provides:", first non-empty, first whitespace token.
    let after = ($output.stdout | split row "Reverse Provides:" | skip 1 | first | default "")
    if ($after | is-empty) { return "" }
    $after
    | lines
    | each { str trim }
    | where { ($in | is-not-empty) and (not ($in | str starts-with "(")) }
    | first
    | default ""
    | split row " "
    | first
    | default ""
}

# Resolve a package name to its component. For virtual packages, follows
# Reverse Provides to find a concrete provider.
# Returns { component: string, via: string } — `via` is "" unless the name
# was virtual and was resolved via a provider.
def pkg-component [pkg: string]: nothing -> record {
    let direct = (policy-component $pkg)
    if ($direct | is-not-empty) {
        return { component: $direct, via: "" }
    }
    let provider = (virtual-provider $pkg)
    if ($provider | is-empty) {
        return { component: "unknown", via: "" }
    }
    let provider_component = (policy-component $provider)
    {
        component: (if ($provider_component | is-empty) { "unknown" } else { $provider_component })
        via: $provider
    }
}

# Get the binary packages produced by a source package.
# Returns [] if `pkg` is not a known source.
def source-binaries [pkg: string]: nothing -> list<string> {
    let output = (apt-cache showsrc $pkg | complete)
    if $output.exit_code != 0 { return [] }
    $output.stdout
    | lines
    | where { $in | str starts-with "Binary:" }
    | each { str replace "Binary:" "" | split row "," | each { str trim } }
    | flatten
    | where { $in | is-not-empty }
    | uniq
}

# Resolve direct runtime dependencies of a (binary or source) package.
# If `pkg` is a source, unions the deps of all its produced binaries and
# excludes the binaries themselves from the result.
def resolve-deps [pkg: string]: nothing -> list<string> {
    let direct = (apt-cache-depends $pkg)
    if ($direct | is-not-empty) { return $direct }
    let bins = (source-binaries $pkg)
    if ($bins | is-empty) { return [] }
    $bins
    | each {|b| apt-cache-depends $b }
    | flatten
    | where { $in not-in $bins }
    | uniq
}

def apt-cache-depends [pkg: string]: nothing -> list<string> {
    let output = (apt-cache depends --no-suggests --no-recommends --no-conflicts --no-breaks --no-replaces --no-enhances $pkg | complete)
    if $output.exit_code != 0 { return [] }
    $output.stdout
    | lines
    | where { $in =~ '(?:Pre)?Depends:' }
    | each { str trim | str replace -r '^\|' '' | split row ': ' | get 1 }
    | where { not ($in | str starts-with '<') }
    | uniq
}

# Resolve transitive (recursive) runtime dependencies of a (binary or source) package.
def resolve-deps-recursive [pkg: string]: nothing -> list<string> {
    let direct = (apt-cache-depends-recurse $pkg)
    if ($direct | is-not-empty) { return ($direct | where { $in != $pkg }) }
    let bins = (source-binaries $pkg)
    if ($bins | is-empty) { return [] }
    $bins
    | each {|b| apt-cache-depends-recurse $b }
    | flatten
    | where { $in not-in $bins }
    | uniq
}

def apt-cache-depends-recurse [pkg: string]: nothing -> list<string> {
    let output = (apt-cache depends --recurse --no-suggests --no-recommends --no-conflicts --no-breaks --no-replaces --no-enhances $pkg | complete)
    if $output.exit_code != 0 { return [] }
    $output.stdout
    | lines
    | where { $in =~ '^\w' }
    | where { $in != $pkg }
    | uniq
}

# Resolve build dependencies of a source package.
# Parses Build-Depends and Build-Depends-Indep from apt-cache showsrc.
def resolve-build-deps [pkg: string]: nothing -> list<string> {
    apt-cache showsrc $pkg
    | lines
    | where { $in =~ '^Build-Depends' }
    | each { split row ': ' | get 1 }
    | each { split row ', ' }
    | flatten
    | each { str trim | str replace -r '\s*[\(\[<].*' '' }
    | where { $in != "" }
    | uniq
}

# Resolve a binary package name to its source package name via `apt-cache show`.
# Ubuntu binary names don't always match their source (e.g. `libc6` → `glibc`),
# so linking `+source/<binary>` directly would 404. Falls back to the input
# name when there's no explicit `Source:` field (source name == binary name) or
# the package can't be resolved (virtual / unknown), so the result is always
# safe to hand to `lp-source-link`.
def bin-to-source [pkg: string]: nothing -> string {
    let output = (apt-cache show $pkg | complete)
    if $output.exit_code != 0 { return $pkg }
    let src_line = (
        $output.stdout
        | lines
        | where { $in | str starts-with "Source:" }
        | get -o 0
        | default ""
    )
    if ($src_line | is-empty) { return $pkg }
    # `Source:` may carry a version, e.g. "Source: glibc (2.39-0ubuntu8.4)".
    $src_line
    | str replace -r '^Source:\s*' ''
    | str replace -r '\s*\(.*\)\s*$' ''
    | str trim
}

# Link a binary package name to its Launchpad source page, keeping the binary
# name as the visible label. Resolves binary → source first so the URL is valid.
def bin-source-link [pkg: string]: nothing -> string {
    lp-source-link (bin-to-source $pkg) --display $pkg
}

# Check which archive components (pockets) a package's dependencies live in.
# Lists main/restricted counts, and explicitly names packages in universe/multiverse.
# Virtual packages are resolved via their providers (shown as `name → provider`).
# Use -a/--all to list every package regardless of component.
export def dep-components [
    package: string       # The package to analyze (binary or source name)
    --recursive (-r)      # Include transitive (recursive) dependencies
    --build (-b)          # Analyze build dependencies instead of runtime
    --all (-a)            # Show all packages explicitly (don't flatten main/restricted)
]: nothing -> nothing {
    let deps = if $build {
        resolve-build-deps $package
    } else if $recursive {
        resolve-deps-recursive $package
    } else {
        resolve-deps $package
    }

    if ($deps | is-empty) {
        print $"No dependencies found for ($package)."
        return
    }

    # Classify each dependency by component, tracking virtual→provider resolution.
    let classified = ($deps | each {|dep|
        let info = (pkg-component $dep)
        { name: $dep, component: $info.component, via: $info.via }
    })

    let grouped = ($classified | group-by component)

    let mode = if $build { "build" } else if $recursive { "transitive" } else { "direct" }
    print $"($package) — ($deps | length) ($mode) dependencies:\n"

    for component in ["main", "restricted", "universe", "multiverse", "unknown"] {
        if $component in ($grouped | columns) {
            let entries = ($grouped | get $component)
            let count = ($entries | length)
            if (not $all) and ($component in ["main", "restricted"]) {
                print $"  ($count) in ($component)"
            } else {
                print $"  ($count) in ($component):"
                $entries
                | sort-by name
                | each {|e|
                    if ($e.via | is-not-empty) {
                        # Virtual package: `name` has no source page of its own,
                        # so link the concrete provider to its source instead.
                        print $"    - ($e.name) → (bin-source-link $e.via)"
                    } else {
                        print $"    - (bin-source-link $e.name)"
                    }
                }
            }
        }
    }
}

# Parse `apt-cache rdepends` stdout into a clean package-name list.
# Drops the 2-line header, strips the relation prefix (Depends:/PreDepends:),
# and removes blank lines. Caller dedups (single vs unioned).
def parse-rdepends [stdout: string]: nothing -> list<string> {
    $stdout
    | lines
    | skip 2
    | each {|line| $line | str trim | str replace -r '^[A-Za-z]+:\s*' '' }
    | where { $in != "" }
}

# Fetch reverse dependencies for a (binary or source) package.
# Uses apt-cache rdepends directly for binary packages; falls back to
# resolving source packages through their produced binaries and unioning.
export def revdeps [
    package: string # The package to check reverse dependencies for
]: nothing -> list<string> {
    let raw = (with-spinner $"Fetching reverse dependencies for ($package)..." { apt-cache rdepends $package | complete })

    # `apt-cache rdepends` exits 0 even for a source/virtual name that has no
    # binary of its own, emitting just `<name>` with no `Reverse Depends:`
    # header, so also gate  on the header so those names fall through to
    # source-package resolution instead of returning empty.
    if ($raw.exit_code == 0) and ($raw.stdout | str contains "Reverse Depends:") {
        return (parse-rdepends $raw.stdout | uniq)
    }

    # Not a binary package — try resolving as a source package.
    let bins = (source-binaries $package)
    if ($bins | is-empty) {
        print -e $"(ansi yellow)No package '($package)' found by apt-cache.(ansi reset)"
        return []
    }

    with-spinner $"Fetching reverse dependencies for ($package) source..." {
        $bins | par-each {|b|
            let r = (apt-cache rdepends $b | complete)
            if $r.exit_code != 0 { return [] }
            parse-rdepends $r.stdout
        } | flatten | uniq
    }
}

# Query where a package is published across the archive, as a table.
# Thin wrapper over `rmadison` that parses its pipe-delimited output into
# structured rows.
export def madison [
    package: string@pkg-completions          # Source/binary package to look up
    --debian (-d)                            # Query the Debian archive instead of Ubuntu
    --url (-u): string                       # Explicit madison URL/shorthand (overrides --debian)
    --suite (-s): string                     # Restrict to a suite (comma/space separated)
    --arch (-a): string                      # Restrict to an arch (comma/space separated)
    --raw                                    # Return structured rows (arches as list, no links)
]: nothing -> table {
    let host = if ($url | is-not-empty) { $url } else if $debian { "debian" } else { null }

    let args = ([
        (if ($host | is-not-empty) { ["-u" $host] } else { [] })
        (if ($suite | is-not-empty) { ["-s" $suite] } else { [] })
        (if ($arch | is-not-empty) { ["-a" $arch] } else { [] })
        [$package]
    ] | flatten)

    let result = (with-spinner $"Querying madison for ($package)..." { ^rmadison ...$args | complete })

    if $result.exit_code != 0 {
        error make { msg: $"rmadison failed for ($package): ($result.stderr | str trim)" }
    }

    let rows = ($result.stdout
    | lines
    | where { ($in | str trim) | is-not-empty }
    | each {|line|
        let cols = ($line | split row "|" | each { str trim })
        let suite_field = ($cols | get 2? | default "")
        let suite_parts = ($suite_field | split row "/")
        {
            package: ($cols | get 0? | default "")
            version: ($cols | get 1? | default "")
            suite: ($suite_parts | get 0? | default "")
            component: ($suite_parts | get 1? | default "main")
            arches: ($cols | get 3? | default "" | split row "," | each { str trim } | where { is-not-empty })
        }
    })

    if $raw { return $rows }

    # Only Ubuntu/Debian archives have canonical web pages to link to; a custom
    # --url host may not, so fall back to plain text there.
    let linkable = ($host == null) or ($host == "debian")

    $rows | each {|row|
        let ver_cell = if $linkable and ($row.version | is-not-empty) {
            if $debian {
                # packages.debian.org has no `-debug` suite pages (the debug
                # archive is the same source); strip the suffix so the link
                # resolves instead of erroring with "two or more packages".
                let suite = ($row.suite | str replace -r '-debug$' '')
                osc8-link $"https://packages.debian.org/source/($suite)/($row.package)" $row.version
            } else {
                osc8-link (lp-source-url $row.package $row.version) $row.version
            }
        } else {
            $row.version
        }
        {
            package: $row.package
            version: $ver_cell
            suite: $row.suite
            component: $row.component
            arches: ($row.arches | str join " ")
        }
    }
}
