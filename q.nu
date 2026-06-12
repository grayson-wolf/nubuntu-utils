# Quilt patch management subcommands — all quilt operations under `q`.

use packaging/meta.nu [pkg-name]

# Quilt patch management commands. Run bare `q` to see available subcommands.
export def main []: nothing -> nothing {
    print "Quilt patch management commands. Available subcommands:\n"
    print "  q push     — Apply all patches (--fuzz=0)"
    print "  q pop      — Unapply all patches"
    print "  q ref      — Refresh current patch (git-style headers)"
    print "  q add      — Register a file for the current patch"
    print "  q header   — Edit DEP-3 patch header interactively"
    print "  q series   — Show the patch series"
    print "  q top      — Show the topmost applied patch"
    print "  q new      — Create a new numbered quilt patch"
    print "  q edit     — Register file, open in editor, refresh"
    print "  q diff     — Generate an upstream-ready patch diff"
    print $"\nRun `q <subcommand> --help` for details."
}

# Apply all patches with --fuzz=0.
export def push []: nothing -> nothing {
    quilt push -a --fuzz=0
}

# Unapply all patches.
export def pop []: nothing -> nothing {
    quilt pop -a
}

# Refresh the current patch with git-style headers (no timestamps, no index).
export def ref []: nothing -> nothing {
    quilt refresh -p ab --no-timestamps --no-index
}

# Register a file for the current quilt patch.
export def add [
    file: string  # The file to register
]: nothing -> nothing {
    quilt add $file
}

# Edit the DEP-3 patch header interactively.
export def header []: nothing -> nothing {
    quilt header -e --dep3
}

# Show the patch series.
export def series []: nothing -> nothing {
    quilt series
}

# Show the topmost applied patch.
export def top []: nothing -> nothing {
    quilt top
}

# Create a new numbered quilt patch.
# Automatically applies all existing patches first, then creates a new patch
# with the next sequential number prefix (e.g., 0005-fix-foo.patch).
export def new [
    name: string # Descriptive patch name, without the number prefix or .patch suffix
]: nothing -> nothing {
    # Ensure the full series is applied before creating a new patch
    do --ignore-errors { push }

    # Inspect series for the NNNN- convention
    let series_file = "debian/patches/series"
    let numbers = if ($series_file | path exists) {
        open $series_file
        | lines
        | each { str trim }
        | where { $in =~ '^\d+-' }
        | each { parse -r '^(?<n>\d+)-' | get n.0 | into int }
    } else {
        []
    }

    let filename = if ($numbers | is-empty) {
        $"($name).patch"
    } else {
        let next = ($numbers | math max) + 1
        let padded = $next | fill --alignment right --character '0' --width 4
        $"($padded)-($name).patch"
    }

    quilt new $filename
}

# Register a file with the current quilt patch, open it in $EDITOR, and refresh.
# Streamlines the common quilt add → edit → refresh cycle.
export def edit [
    file: string  # The file to register and edit
]: nothing -> nothing {
    quilt add $file
    run-external $env.EDITOR $file
    quilt refresh -p ab --no-timestamps --no-index
}

# Generate a patch diff from the upstream branch suitable for upstreaming.
# Defaults to diffing against pkg/ubuntu/devel; use -s/--sid for pkg/debian/sid.
export def diff [
    patch_name: string # The name of the patch, to be prefixed with the package name
    --sid (-s) # Use pkg/debian/sid instead of pkg/ubuntu/devel
]: nothing -> nothing {
    let pkg_name = pkg-name
    let upstream = if $sid { "pkg/debian/sid" } else { "pkg/ubuntu/devel" }
    git diff $upstream HEAD -- . ':!debian/changelog' | save $"../($pkg_name)-($patch_name).patch"
}
