# Quilt patch management subcommands — all quilt operations under `q`.

use packaging/meta.nu [pkg-name]
use completions.nu [git-branch-completions, shunt-patch-completions]

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
    print "  q shunt    — Transplant a patch from another branch into this series"
    print $"\nRun `q <subcommand> --help` for details."
}

# Build the next sequential patch filename following the NNNN- convention.
# When the series has no numbered patches, returns "<name>.patch" unprefixed.
# When --number is given, that number is used verbatim (always prefixed).
def next-patch-filename [
    name: string
    --number (-n): int
]: nothing -> string {
    if $number != null {
        let padded = $number | fill --alignment right --character '0' --width 4
        return $"($padded)-($name).patch"
    }

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

    if ($numbers | is-empty) {
        $"($name).patch"
    } else {
        let next = ($numbers | math max) + 1
        let padded = $next | fill --alignment right --character '0' --width 4
        $"($padded)-($name).patch"
    }
}

# Apply all patches at --fuzz=0, capturing the result.
#
# An old-format working tree refuses to push until `quilt upgrade` rewrites the
# .pc metadata; that's safe and idempotent, so detect it, upgrade, and retry
# once. quilt also exits non-zero for benign states ("no patches in series",
# "fully applied"); those are folded into an `ok` flag so callers don't treat
# them as conflicts.
#
# Returns the push `complete` record plus an added `ok` bool.
def push-fuzz0 []: nothing -> record {
    mut res = (quilt push -a --fuzz=0 | complete)
    if $res.exit_code != 0 and (($res.stdout + $res.stderr) =~ 'quilt upgrade') {
        let upgraded = (quilt upgrade | complete)
        if $upgraded.exit_code == 0 {
            $res = (quilt push -a --fuzz=0 | complete)
        }
    }
    let benign = (($res.stdout + $res.stderr) =~ '(?i)no patches in series|fully applied')
    $res | insert ok ($res.exit_code == 0 or $benign)
}

# Apply all patches with --fuzz=0.
export def push []: nothing -> nothing {
    let res = (push-fuzz0)
    print -n $res.stdout
    if $res.stderr != "" { print -e -n $res.stderr }
    if not $res.ok {
        error make { msg: $"quilt push failed \(exit ($res.exit_code)\)" }
    }
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

    quilt new (next-patch-filename $name)
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

# Transplant a patch from another branch's series into the current branch.
#
# Use case: shunting the same patch between two parallel branches (e.g. a
# resolute merge and a stonking merge). The branch-to-branch path is primary
# and obviates copying .patch files around:
#
#   q shunt <branch> <patch>   # read <patch> from <branch>:debian/patches/
#
# To transplant a loose patch file instead (e.g. one you've exported), use
# the --file escape hatch; in that mode the branch argument is omitted:
#
#   q shunt --file ../my.patch
#
# The patch is written into debian/patches/ following the NNNN- numbering
# convention (override with --number), appended to the series, and `quilt push`
# is attempted at --fuzz=0. On a fuzz/conflict failure the patch and series
# entry are left in place so you can edit and `q push` manually.
export def shunt [
    branch?: string@git-branch-completions  # Source branch to read the patch from
    patch?: string@shunt-patch-completions  # Patch name in <branch>:debian/patches/
    --file (-f): string             # Transplant a loose patch file instead of a branch patch
    --name (-N): string             # Override the destination patch base name (no NNNN-/.patch)
    --number (-n): int              # Force a specific series number
    --no-apply (-A)                 # Skip the fuzz-0 apply check
]: nothing -> nothing {
    if ($file | is-not-empty) {
        if ($branch | is-not-empty) {
            error make { msg: "pass either <branch> <patch> or --file, not both" }
        }
    } else if ($branch | is-empty) or ($patch | is-empty) {
        error make { msg: "usage: q shunt <branch> <patch>   (or: q shunt --file <path>)" }
    }

    let basename = if ($file | is-not-empty) {
        $file | path basename
    } else {
        $patch | path basename
    }
    let dest_base = ($name | default ($basename | str replace -r '\.patch$' '' | str replace -r '^\d+-' ''))
    let dest_name = if $number != null {
        next-patch-filename $dest_base --number $number
    } else {
        next-patch-filename $dest_base
    }
    let dest_path = $"debian/patches/($dest_name)"

    if ($dest_path | path exists) {
        error make { msg: $"($dest_path) already exists; pass --name/--number to disambiguate" }
    }

    # Resolve and materialize the source patch content.
    let content = if ($file | is-not-empty) {
        if not ($file | path exists) {
            error make { msg: $"file not found: ($file)" }
        }
        open --raw $file
    } else {
        let src_ref = $"($branch):debian/patches/($basename)"
        let res = (git show $src_ref | complete)
        if $res.exit_code != 0 {
            error make { msg: $"could not read ($src_ref): ($res.stderr | str trim)" }
        }
        $res.stdout
    }

    $content | save --raw $dest_path

    # Quilt reads patch names from the series file; append unless already present.
    let series_file = "debian/patches/series"
    let existing = if ($series_file | path exists) {
        open $series_file | lines | each { str trim }
    } else {
        []
    }
    if not ($dest_name in $existing) {
        let series_text = ($existing | append $dest_name | str join (char newline))
        $"($series_text)(char newline)" | save --raw --force $series_file
    }

    if $no_apply {
        print $"Shunted ($basename) -> ($dest_path) \(apply check skipped\)."
        return
    }

    let applied = (push-fuzz0)
    if $applied.ok {
        print $"Shunted ($basename) -> ($dest_path); applies cleanly at fuzz 0."
    } else {
        print $"Shunted ($basename) -> ($dest_path), but it does NOT apply cleanly at fuzz 0:"
        print ($applied.stdout | str trim)
        print ($applied.stderr | str trim)
        print $"Edit ($dest_path) and rerun `q push` once resolved."
    }
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
