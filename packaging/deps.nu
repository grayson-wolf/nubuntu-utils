# Dependency pocket/component analysis commands

# Get the archive component (main, restricted, universe, multiverse) for a package.
# Returns "unknown" if the package is virtual or not found in any archive.
def pkg-component [pkg: string]: nothing -> string {
    let output = (apt-cache policy $pkg | complete)
    if $output.exit_code != 0 {
        return "unknown"
    }
    # Look for lines like: 500 http://archive.ubuntu.com/ubuntu resolute/main amd64 Packages
    let component = ($output.stdout
        | lines
        | where { $in =~ '/(?:main|restricted|universe|multiverse)\s' }
        | first
        | default ""
        | parse -r '(?<component>main|restricted|universe|multiverse)'
        | get component
        | first
        | default "unknown")
    $component
}

# Resolve direct runtime dependencies of a package (Pre-Depends + Depends only).
def resolve-deps [pkg: string]: nothing -> list<string> {
    apt-cache depends --no-suggests --no-recommends --no-conflicts --no-breaks --no-replaces --no-enhances $pkg
    | lines
    | where { $in =~ '(?:Pre)?Depends:' }
    | each { str trim | str replace -r '^\|' '' | split row ': ' | get 1 }
    | where { not ($in | str starts-with '<') }  # skip virtual/alternates
    | uniq
}

# Resolve transitive (recursive) runtime dependencies of a package.
def resolve-deps-recursive [pkg: string]: nothing -> list<string> {
    apt-cache depends --recurse --no-suggests --no-recommends --no-conflicts --no-breaks --no-replaces --no-enhances $pkg
    | lines
    | where { $in =~ '^\w' }  # top-level lines are package names
    | where { $in != $pkg }   # exclude the package itself
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
    | each { str trim | str replace -r '\s*[\(\[<].*' '' }  # strip version, arch, and profile qualifiers
    | where { $in != "" }
    | uniq
}

# Check which archive components (pockets) a package's dependencies live in.
# Lists main/restricted counts, and explicitly names packages in universe/multiverse.
# Use -a/--all to list every package regardless of component.
export def dep-components [
    package: string       # The package to analyze
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

    # Classify each dependency by component
    let classified = ($deps | each {|dep|
        { name: $dep, component: (pkg-component $dep) }
    })

    let grouped = ($classified | group-by component)

    let mode = if $build {
        "build"
    } else if $recursive {
        "transitive"
    } else {
        "direct"
    }
    print $"($package) — ($deps | length) ($mode) dependencies:\n"

    for component in ["main", "restricted", "universe", "multiverse", "unknown"] {
        if $component in ($grouped | columns) {
            let pkgs = ($grouped | get $component | get name)
            let count = ($pkgs | length)
            if (not $all) and ($component in ["main", "restricted"]) {
                print $"  ($count) in ($component)"
            } else {
                print $"  ($count) in ($component):"
                $pkgs | sort | each { print $"    - ($in)" }
            }
        }
    }
}
