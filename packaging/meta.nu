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
