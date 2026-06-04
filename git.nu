# GitHub / git helper commands

use packaging/meta.nu [pkg-version]

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
        let version = pkg-version
        let tags = [
            $"reconstruct/($version)"
            $"split/($version)"
            $"logical/($version)"
            "old/ubuntu"
            "old/debian"
            "new/debian"
        ]
        for tag in $tags {
            if not (git tag -l $tag | is-empty) {
                git push $remote $tag
            }
        }
    }
}
