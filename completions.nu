# Shared custom completers for packaging commands

use ubuntu-versions.nu [SUPPORTED_RELEASES]

# Supported Ubuntu release names
export def release-completions []: nothing -> list<string> {
    $SUPPORTED_RELEASES
}

# Existing PPAs from `ppa list`
export def ppa-completions []: nothing -> list<string> {
    do --ignore-errors { ppa list | lines | where { $in != "" } } | default []
}

# Locally-cloned package names from $NUBUNTU_PKGS_DIR (default ~/pkgs/)
export def pkg-completions []: nothing -> list<string> {
    let pkgs_dir = ($env.NUBUNTU_PKGS_DIR? | default "~/pkgs" | path expand)
    if not ($pkgs_dir | path exists) { return [] }
    ls $pkgs_dir | where type == dir | get name | each { path basename }
}
