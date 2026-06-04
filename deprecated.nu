# Deprecated command wrappers — prints a warning then delegates to the new command.
# Remove these once muscle memory has adjusted.

use p.nu
use q.nu
use packaging/workspace.nu [pkg]
use completions.nu [ppa-completions]

# Legacy alias for `pkg`
export def --env gp [
    package: string
    --refetch (-r)
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `gp` is deprecated, use `pkg` instead(ansi reset)"
    if $refetch {
        pkg $package -r
    } else {
        pkg $package
    }
}

# Legacy wrapper for `p name`
export def "ppa-name" []: nothing -> string {
    print $"(ansi yellow_bold)⚠ `ppa-name` is deprecated, use `p name` instead(ansi reset)"
    p name
}

# Legacy wrapper for `p build`
export def --wrapped ppa-build [
    --proposed (-p)
    --security (-s)
    --backports (-b)
    --no-deps (-d)
    ...debuild_flags: string
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `ppa-build` is deprecated, use `p build` instead(ansi reset)"
    p build --proposed=$proposed --security=$security --backports=$backports --no-deps=$no_deps ...$debuild_flags
}

# Legacy wrapper for `p up`
export def ppa-up [
    ppa_name: string
    --proposed (-p)
    --security (-s)
    --backports (-b)
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `ppa-up` is deprecated, use `p up` instead(ansi reset)"
    p up $ppa_name --proposed=$proposed --security=$security --backports=$backports
}

# Legacy wrapper for `p reap`
export def ppa-reap [
    name?: string
]: nothing -> list<string> {
    print $"(ansi yellow_bold)⚠ `ppa-reap` is deprecated, use `p reap` instead(ansi reset)"
    p reap $name
}

# Legacy wrapper for `p destroy`
export def ppa-destroy [
    ppa_name: string@ppa-completions
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `ppa-destroy` is deprecated, use `p destroy` instead(ansi reset)"
    p destroy $ppa_name
}

# Legacy wrapper for `p test`
export def ppa-autotest [
    --proposed (-p)
    --ppa: string@ppa-completions
    --no-select
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `ppa-autotest` is deprecated, use `p test` instead(ansi reset)"
    if ($ppa | is-not-empty) {
        p test --proposed=$proposed --ppa $ppa --no-select=$no_select
    } else {
        p test --proposed=$proposed --no-select=$no_select
    }
}

# Legacy wrapper for `p tests`
export def --wrapped ppa-tests [
    ppa_name: string@ppa-completions
    ...flags: string
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `ppa-tests` is deprecated, use `p tests` instead(ansi reset)"
    p tests $ppa_name ...$flags
}

# Legacy wrapper for `p sync`
export def testsync [
    --release (-r): string
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `testsync` is deprecated, use `p sync` instead(ansi reset)"
    if ($release | is-not-empty) {
        p sync -r $release
    } else {
        p sync
    }
}

# --- Quilt deprecated wrappers ---

# Legacy wrapper for `q push`
export def qpush []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qpush` is deprecated, use `q push` instead(ansi reset)"
    q push
}

# Legacy wrapper for `q pop`
export def qpop []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qpop` is deprecated, use `q pop` instead(ansi reset)"
    q pop
}

# Legacy wrapper for `q ref`
export def qref []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qref` is deprecated, use `q ref` instead(ansi reset)"
    q ref
}

# Legacy wrapper for `q add`
export def qadd [file: string]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qadd` is deprecated, use `q add` instead(ansi reset)"
    q add $file
}

# Legacy wrapper for `q header`
export def qheader []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qheader` is deprecated, use `q header` instead(ansi reset)"
    q header
}

# Legacy wrapper for `q series`
export def qstatus []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qstatus` is deprecated, use `q series` instead(ansi reset)"
    q series
}

# Legacy wrapper for `q top`
export def qtop []: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qtop` is deprecated, use `q top` instead(ansi reset)"
    q top
}

# Legacy wrapper for `q new`
export def qnew [name: string]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qnew` is deprecated, use `q new` instead(ansi reset)"
    q new $name
}

# Legacy wrapper for `q edit`
export def qedit [file: string]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `qedit` is deprecated, use `q edit` instead(ansi reset)"
    q edit $file
}

# Legacy wrapper for `q diff`
export def debpatch [
    patch_name: string
    --sid (-s)
]: nothing -> nothing {
    print $"(ansi yellow_bold)⚠ `debpatch` is deprecated, use `q diff` instead(ansi reset)"
    q diff $patch_name --sid=$sid
}
