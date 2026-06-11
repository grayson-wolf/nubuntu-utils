# Deprecated command wrappers — prints a warning then delegates to the new command.
# Remove these once muscle memory has adjusted.

use p.nu
use q.nu
use my.nu ["my excuses"]
use packaging/navigation.nu [pkg]
use completions.nu [release-completions, ppa-completions]
use ubuntu-versions.nu [DEVEL_RELEASE]

def deprecation-warning [old: string, new: string]: nothing -> nothing {
    print -e $"(ansi yellow_bold)⚠ `($old)` is deprecated, use `($new)` instead(ansi reset)"
}

# Legacy alias for `pkg`
export def --env gp [
    package: string
    --refetch (-r)
]: nothing -> nothing {
    deprecation-warning "gp" "pkg"
    if $refetch {
        pkg $package -r
    } else {
        pkg $package
    }
}

# Legacy wrapper for `p name`
export def "ppa-name" []: nothing -> string {
    deprecation-warning "ppa-name" "p name"
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
    deprecation-warning "ppa-build" "p build"
    p build --proposed=$proposed --security=$security --backports=$backports --no-deps=$no_deps ...$debuild_flags
}

# Legacy wrapper for `p up`
export def ppa-up [
    ppa_name: string
    --proposed (-p)
    --security (-s)
    --backports (-b)
]: nothing -> nothing {
    deprecation-warning "ppa-up" "p up"
    p up $ppa_name --proposed=$proposed --security=$security --backports=$backports
}

# Legacy wrapper for `p reap`
export def ppa-reap [
    name?: string
]: nothing -> list<string> {
    deprecation-warning "ppa-reap" "p reap"
    p reap $name
}

# Legacy wrapper for `p destroy`
export def ppa-destroy [
    ppa_name: string@ppa-completions
]: nothing -> nothing {
    deprecation-warning "ppa-destroy" "p destroy"
    p destroy $ppa_name
}

# Legacy wrapper for `p test`
export def ppa-autotest [
    --proposed (-p)
    --ppa: string@ppa-completions
    --no-select
]: nothing -> nothing {
    deprecation-warning "ppa-autotest" "p test"
    if ($ppa | is-not-empty) {
        p test --proposed=$proposed --ppa $ppa --no-select=$no_select
    } else {
        p test --proposed=$proposed --no-select=$no_select
    }
}

# Legacy wrapper for `p tests`
export def ppa-tests [
    ppa_name: string@ppa-completions
    --series (-s): string
    --raw (-r)
]: nothing -> any {
    deprecation-warning "ppa-tests" "p tests"
    if ($series | is-empty) {
        p tests $ppa_name --raw=$raw
    } else {
        p tests $ppa_name --series $series --raw=$raw
    }
}

# Legacy wrapper for `p sync`
export def testsync [
    --release (-r): string
]: nothing -> nothing {
    deprecation-warning "testsync" "p sync"
    if ($release | is-not-empty) {
        p sync -r $release
    } else {
        p sync
    }
}

# --- Quilt deprecated wrappers ---

# Legacy wrapper for `q push`
export def qpush []: nothing -> nothing {
    deprecation-warning "qpush" "q push"
    q push
}

# Legacy wrapper for `q pop`
export def qpop []: nothing -> nothing {
    deprecation-warning "qpop" "q pop"
    q pop
}

# Legacy wrapper for `q ref`
export def qref []: nothing -> nothing {
    deprecation-warning "qref" "q ref"
    q ref
}

# Legacy wrapper for `q add`
export def qadd [file: string]: nothing -> nothing {
    deprecation-warning "qadd" "q add"
    q add $file
}

# Legacy wrapper for `q header`
export def qheader []: nothing -> nothing {
    deprecation-warning "qheader" "q header"
    q header
}

# Legacy wrapper for `q series`
export def qstatus []: nothing -> nothing {
    deprecation-warning "qstatus" "q series"
    q series
}

# Legacy wrapper for `q top`
export def qtop []: nothing -> nothing {
    deprecation-warning "qtop" "q top"
    q top
}

# Legacy wrapper for `q new`
export def qnew [name: string]: nothing -> nothing {
    deprecation-warning "qnew" "q new"
    q new $name
}

# Legacy wrapper for `q edit`
export def qedit [file: string]: nothing -> nothing {
    deprecation-warning "qedit" "q edit"
    q edit $file
}

# Legacy wrapper for `q diff`
export def debpatch [
    patch_name: string
    --sid (-s)
]: nothing -> nothing {
    deprecation-warning "debpatch" "q diff"
    q diff $patch_name --sid=$sid
}

# Legacy wrapper for `my excuses`
# Deprecated 2026-06-11
export def my-excuses [
    --series (-s): string@release-completions = $DEVEL_RELEASE
    --user (-u): string = ""
    --detailed (-D)
    --why (-w)
    --failing (-f)
    --limit (-n): int = 0
    --raw (-r)
]: nothing -> any {
    deprecation-warning "my-excuses" "my excuses"
    my excuses --series $series --user $user --detailed=$detailed --why=$why --failing=$failing --limit $limit --raw=$raw
}
