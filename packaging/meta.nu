# Package metadata helpers (no external dependencies)
# These parse debian/changelog for version and release info.

# Get the source package name from the current working directory.
export def pkg-name []: nothing -> string {
    pwd | path split | last
}

# Find the current release name the package is targetting in debian/changelog.
export def pkg-release []: nothing -> string {
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
