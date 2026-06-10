# Package metadata helpers (no external dependencies)
# These parse debian/changelog for version and release info.

# Get the source package name from the current working directory.
export def pkg-name []: nothing -> string {
    pwd | path split | last
}

# Get the literal distribution from the top of debian/changelog (verbatim,
# including UNRELEASED, pocket suffixes, or Debian distros). Use
# `target-release` instead if you want the series the package actually
# uploads/tests against.
export def pkg-top-release []: nothing -> string {
    open debian/changelog | lines | first | split row " " | get 2 | str replace ";" ""
}

# Get the full version of the package from debian/changelog (epoch:upstream-revision).
export def pkg-version []: nothing -> string {
    open debian/changelog | lines | first | split row " " | get 1 | str replace -r '^\(' '' | str replace -r '\)$' ''
}

# Get the upstream version without epoch or debian revision (for orig tarball naming).
export def pkg-upstream-version []: nothing -> string {
    pkg-version | str replace -r '^[0-9]+:' '' | str replace -r '-[^-]+$' ''
}

# Find the most-recently-published Ubuntu release for this package by walking
# debian/changelog from top to bottom and returning the first entry whose
# distribution (after stripping pocket suffix like -backports/-security)
# matches a known Ubuntu codename. Skips UNRELEASED-prefixed entries and any
# Debian-only distros (unstable, experimental, bookworm, trixie, ...).
# Returns null if no Ubuntu entry is found (e.g. fresh Debian sync).
export def last-published-release []: nothing -> any {
    use ../ubuntu-versions.nu [ALL_RELEASES]
    let ubuntu_names = ($ALL_RELEASES | get name)
    open debian/changelog
        | lines
        | where { $in =~ '^\S+ \(.+?\) \S+; urgency=' }
        | each {|line|
            $line | split row " " | get 2 | str replace ";" "" | split row "-" | get 0
        }
        | where { $in !~ '(?i)^UNRELEASED' }
        | where { $in in $ubuntu_names }
        | get -o 0
}

# Canonical "what Ubuntu series does this package target for builds/uploads/
# tests?" helper. Strips pocket suffix from the top changelog entry; falls
# back to last-published-release, then $DEVEL_RELEASE, when the top entry is
# UNRELEASED, a Debian distro (unstable, experimental, ...), or otherwise
# not a known Ubuntu codename.
export def target-release []: nothing -> string {
    use ../ubuntu-versions.nu [ALL_RELEASES, DEVEL_RELEASE]
    let names = ($ALL_RELEASES | get name)
    let top = (pkg-top-release | split row "-" | get 0)
    if ($top in $names) and ($top !~ '(?i)^UNRELEASED') {
        $top
    } else {
        (try { last-published-release } catch { null }) | default $DEVEL_RELEASE
    }
}
