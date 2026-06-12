# Dependency pocket/component analysis commands

use ../formatting.nu [with-spinner]

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
                        print $"    - ($e.name) → ($e.via)"
                    } else {
                        print $"    - ($e.name)"
                    }
                }
            }
        }
    }
}

# Fetch reverse dependencies for a package.
# Uses apt-cache to find all packages that depend on the given package.
export def revdeps [
    package: string # The package to check reverse dependencies for
]: nothing -> list<string> {
    let raw = (with-spinner $"Fetching reverse dependencies for ($package)..." { apt-cache rdepends $package | complete })
    if $raw.exit_code != 0 {
        print -e $"(ansi yellow)No package '($package)' found by apt-cache.(ansi reset)"
        return []
    }
    let output = ($raw.stdout | lines)

    if ($output | length) < 2 {
        return []
    }

    # Skip header lines (package name and "Reverse Depends:")
    # Each line may have a dependency type prefix like "Depends:", "Recommends:", etc.
    $output | skip 2 | each {|line|
        $line | str trim | str replace -r '^[A-Za-z]+:\s*' ''
    } | where { $in != "" } | uniq
}
