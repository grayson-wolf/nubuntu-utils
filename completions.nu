# Shared custom completers for packaging commands

use ubuntu-versions.nu [SUPPORTED_RELEASES, ARCHES]
use packaging/launchpad.nu [lp-ppa-names]

# Supported Ubuntu release names
export def release-completions []: nothing -> list<string> {
    $SUPPORTED_RELEASES
}

# Common LXD VM memory / disk sizes, for --memory / --disk on the
# lxd-spawning commands (spawn, ephemeral, testin). The values are
# suggestions only — any size lxc accepts is valid.
export def lxd-size-completions []: nothing -> list<string> {
    ["2GiB" "4GiB" "8GiB" "16GiB" "32GiB" "40GiB" "80GiB"]
}

# Your PPAs on Launchpad (cached 5min). Backed by `my ppas` / `p list`.
export def ppa-completions []: nothing -> list<string> {
    do --ignore-errors { lp-ppa-names } | default []
}

# Locally-cloned package names from $NUBUNTU_PKGS_DIR (default ~/pkgs/)
export def pkg-completions []: nothing -> list<string> {
    let pkgs_dir = ($env.NUBUNTU_PKGS_DIR | path expand)
    if not ($pkgs_dir | path exists) { return [] }
    ls $pkgs_dir | where type == dir | get name | each { path basename }
}

# Test names declared in a debian/tests/control file: both `Tests:` /
# `Test-Command:` stanza names and `Features: test-name=` overrides.
def control-test-names [control: string]: nothing -> list<string> {
    if not ($control | path exists) { return [] }
    let lines = (open $control | lines)
    # Only `Tests:` carries test names. `Test-Command:` is a shell command, not
    # a name; such stanzas are named (if at all) via `Features: test-name=...`.
    let stanza_names = ($lines
        | parse -r '^Tests:\s*(?P<name>\S.*)$'
        | each { get name | str trim }
        | each { split row ',' | each { str trim } }
        | flatten)
    let feature_names = ($lines
        | parse -r '^Features:.*\btest-name=(?P<name>\S+)'
        | each { get name | str trim })
    $stanza_names | append $feature_names | uniq | sort
}

# Test names from the current package's debian/tests/control (for testin --test).
export def local-test-completions []: nothing -> list<string> {
    control-test-names "debian/tests/control"
}

# Subcommands of `my`.
export def my-subcommand-completions []: nothing -> list<string> {
    ["excuses" "srus" "ppas"]
}

# Archive components served by merge-o-matic (merges.ubuntu.com/<c>.json).
export def component-completions []: nothing -> list<string> {
    ["main" "universe" "multiverse" "restricted"]
}

# Archive architectures (for --arch flags).
export def arch-completions []: nothing -> list<string> {
    $ARCHES
}

# Local git branch names (for --from-branch and other ref flags).
export def git-branch-completions []: nothing -> list<string> {
    let res = (git branch --format '%(refname:short)' | complete)
    if $res.exit_code != 0 { return [] }
    $res.stdout | lines | each { str trim } | where { $in | is-not-empty }
}

# Read the patch series of a given git ref without checking it out.
def series-for-ref [ref: string]: nothing -> list<string> {
    let res = (git show $"($ref):debian/patches/series" | complete)
    if $res.exit_code != 0 { return [] }
    $res.stdout | lines | each { str trim } | where { ($in | is-not-empty) and not ($in | str starts-with '#') }
}

# Patch names available to transplant via `q shunt <branch> <patch>`.
# The source branch is the positional just typed before this one, so it's the
# last bare token on the line; list that branch's series. If no branch is
# resolvable yet, fall back to the union across all local branches.
export def shunt-patch-completions [context: string]: nothing -> list<string> {
    let branches = (git-branch-completions)
    let tokens = ($context | str trim | split row -r '\s+')
    let branch = ($tokens | reverse | where { $in in $branches } | get 0? | default "")

    if ($branch | is-not-empty) {
        return (series-for-ref $branch)
    }

    $branches | each { series-for-ref $in } | flatten | uniq
}
