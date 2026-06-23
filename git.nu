# GitHub / git helper commands

# Fetch the GitHub token, reusing $env.GITHUB_TOKEN if already set.
def github-token []: nothing -> string {
    $env.GITHUB_TOKEN? | default (gh auth token | str trim)
}

# Run an external command with the GitHub API Key exposed.
export def --wrapped withgit [
    ...cmd: string # the external command to run
] {
    if ($cmd | is-empty) {
        error make { msg: "withgit requires a command. Use: withgit <external cmd> or pass a closure to withgit-do" }
    }
    with-env { GITHUB_TOKEN: (github-token) } {
        run-external $cmd.0 ...($cmd | skip 1)
    }
}

# Run a closure with the GitHub API Key exposed (supports internal nushell commands)
export def withgit-do [
    block: closure # the closure to run with GITHUB_TOKEN set
] {
    with-env { GITHUB_TOKEN: (github-token) } {
        do $block
    }
}

# Push to your Launchpad fork
# Wraps `git push $LAUNCHPAD_NAME` with optional --force and merge tag pushing.
# Passes through any extra refspecs (e.g., branch names, tags).
export def --wrapped lppush [
    --force (-f)      # Force-push (maps to --force-with-lease for safety)
    --merge-tags (-m) # Also push merge tags (reconstruct/*, split/*, logical/*, old/*, new/*)
    ...refs: string   # Optional refspecs to push (e.g., branch, tag)
]: nothing -> nothing {
    let remote = $env.LAUNCHPAD_NAME
    if $force {
        git push $remote --force-with-lease ...$refs
    } else {
        git push $remote ...$refs
    }

    if $merge_tags {
        # Discover merge tags by glob rather than reconstructing names from the
        # changelog version. git-ubuntu stamps reconstruct/split/logical with
        # the version of the *old/ubuntu* delta being merged (and DEP-14-mangles
        # it: ':'->'%', '~'->'_', ...), which is NOT the current changelog
        # version that `pkg-version` returns.
        let tag_patterns = [
            "reconstruct/*"
            "split/*"
            "logical/*"
            "old/ubuntu"
            "old/debian"
            "new/debian"
        ]
        let tags = (
            git tag -l ...$tag_patterns
                | lines
                | where { not ($in | str trim | is-empty) }
        )
        for tag in $tags {
            git push $remote $tag
        }
    }
}

# Resolve the git-ubuntu binary to use.
# Checks $env.GIT_UBUNTU_BIN first (useful for pointing at a local fork);
# falls back to the system `git-ubuntu`.
def gu []: nothing -> string {
    $env.GIT_UBUNTU_BIN? | default "git-ubuntu"
}

# git ubuntu deltarebase helpers. Run bare `dr` to see available subcommands.
export def dr []: nothing -> nothing {
    print "git ubuntu deltarebase helpers. Available subcommands:\n"
    print "  dr auto      — Start (or restart) an automatic deltarebase"
    print "  dr continue  — Continue a paused deltarebase"
    print "  dr abort     — Abort an in-progress deltarebase"
    print $"\nRun `dr <subcommand> --help` for details."
    print $"\nTo use a local git-ubuntu fork, set \$env.GIT_UBUNTU_BIN to its path."
}

# Run `git ubuntu deltarebase auto`.
# Pass extra flags through (e.g., --dry-run).
export def --wrapped "dr auto" [
    ...flags: string  # Extra flags forwarded to deltarebase auto
]: nothing -> nothing {
    run-external (gu) "deltarebase" "auto" ...$flags
}

# Continue a paused `git ubuntu deltarebase`.
export def --wrapped "dr continue" [
    ...flags: string  # Extra flags forwarded to deltarebase continue
]: nothing -> nothing {
    run-external (gu) "deltarebase" "continue" ...$flags
}

# Abort an in-progress `git ubuntu deltarebase`.
export def "dr abort" []: nothing -> nothing {
    run-external (gu) "deltarebase" "abort"
}
