# Salsa (Debian GitLab) fork-and-clone workflow.
#
# Given a Debian source package name, discovers its upstream salsa project
# via the Debian Vcs-Git field, forks it to the user's personal namespace
# if a fork doesn't already exist, then clones into ~/pkgs/<pkg>/salsa/.

use http.nu [http-get, http-post]
use meta.nu [pkg-name]
use ../completions.nu [pkg-completions]
use ../formatting.nu [with-spinner]

# Salsa API base URL.
const SALSA_API = "https://salsa.debian.org/api/v4"

# Find the salsa project path for a Debian source package by reading the
# Vcs-Git field from `apt-cache showsrc`. Returns null if the package has
# no salsa Vcs.
def salsa-project-path [package: string]: nothing -> any {
    let vcs = (apt-cache showsrc $package | complete)
    if $vcs.exit_code != 0 or ($vcs.stdout | is-empty) {
        error make { msg: $"($package) is not a known source package (apt-cache showsrc failed)." }
    }
    let lines = ($vcs.stdout | lines | where $in starts-with "Vcs-Git:")
    if ($lines | is-empty) { return null }
    let url = ($lines.0 | str replace "Vcs-Git:" "" | str trim)
    # Strip .git suffix and any [path] suffix
    let clean = ($url | str replace -r '\.git.*$' "")
    # Extract the path after salsa.debian.org/
    let m = ($clean | parse -r 'salsa\.debian\.org/(?<p>.+)')
    if ($m | is-empty) { return null }
    $m.0.p
}

# URL-encode a project path for the GitLab API (salsa uses %2F for /).
def salsa-encode-path [path: string]: nothing -> string {
    $path | str replace -a "/" "%2F"
}

# Look up a salsa project by path via the GitLab API.
# Returns the project record (with id, http_url_to_repo, etc.) or null on 404.
def salsa-lookup-project [project_path: string]: nothing -> any {
    let encoded = (salsa-encode-path $project_path)
    http-get $"($SALSA_API)/projects/($encoded)"
}

# Check whether the user already has a fork of a salsa project.
# Returns the fork project record or null.
def salsa-check-fork [project_id: int, user: string]: nothing -> any {
    let forks = (http-get $"($SALSA_API)/projects/($project_id)/forks?per_page=100")
    if ($forks | is-empty) { return null }
    $forks | where ($in.namespace.path? | default "") == $user | get 0?
}

# Fork a salsa project to the user's personal namespace.
# Requires $env.SALSA_TOKEN. Returns the fork project record.
def salsa-fork [project_id: int]: nothing -> any {
    let token = $env.SALSA_TOKEN?
    if ($token | is-empty) {
        error make { msg: "SALSA_TOKEN is not set. Create a personal access token at https://salsa.debian.org/-/user_settings/personal_access_tokens (scope: api) and add it to your env config." }
    }
    http-post $"($SALSA_API)/projects/($project_id)/fork" --headers {"PRIVATE-TOKEN": $token}
}

# Clone or re-enter a Debian salsa fork for a package.
#
# If no package argument is given, infers the current package from the
# working directory (like `pkg`). Looks up the upstream salsa project via
# the Debian Vcs-Git field, forks it to the user's personal namespace if
# a fork doesn't already exist, then clones into ~/pkgs/<pkg>/salsa/ and
# cd's into it. Use -r to refetch (delete and reclone).
#
# Requires $env.SALSA_TOKEN for the initial fork (not needed if the fork
# already exists or for cloning public repos).
export def --env main [
    package?: string@pkg-completions # Package name (defaults to current directory)
    --refetch (-r) # Delete the local salsa clone and reclone
]: nothing -> nothing {
    let pkg = $package | default (pkg-name)

    let pkgs_root = ($env.NUBUNTU_PKGS_DIR | path expand)
    let salsa_dir = ($pkgs_root | path join $pkg "salsa")

    if $refetch and ($salsa_dir | path exists) {
        gum confirm $"This will delete ($salsa_dir) and discard any local changes. Continue?"
        cd ~
        rm -rf $salsa_dir
    }

    if ($salsa_dir | path exists) {
        cd $salsa_dir
        return
    }

    let project_path = (salsa-project-path $pkg)
    if ($project_path | is-empty) {
        error make { msg: $"($pkg) has no Vcs-Git on salsa.debian.org \(or is not a known source package\)." }
    }

    let project = (salsa-lookup-project $project_path)
    if ($project | is-empty) {
        error make { msg: $"Salsa project '($project_path)' not found for ($pkg)." }
    }

    let user = $env.LAUNCHPAD_NAME

    let fork = (salsa-check-fork $project.id $user)
    let fork_rec = if ($fork | is-empty) {
        with-spinner $"Forking ($project_path) on salsa..." { salsa-fork $project.id }
        let new_fork = (salsa-check-fork $project.id $user)
        if ($new_fork | is-empty) {
            let fork_project_path = $user + "/" + ($project_path | split row "/" | last)
            let fork_project = (salsa-lookup-project $fork_project_path)
            if ($fork_project | is-empty) {
                error make { msg: $"Fork was created but could not be found at ($fork_project_path). Wait a moment and retry." }
            }
            $fork_project
        } else {
            $new_fork
        }
    } else {
        $fork
    }

    let parent_dir = ($pkgs_root | path join $pkg)
    if not ($parent_dir | path exists) { mkdir $parent_dir }
    let clone_url = $fork_rec.http_url_to_repo
    gum spin --title $"Cloning salsa fork of ($pkg)..." -- git clone $clone_url $salsa_dir
    cd $salsa_dir
}
