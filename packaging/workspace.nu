# Run update-maintainer, suppressing its "Maintainer is already X" /
# already-correct chatter when nothing actually changed. Output is shown
# only when debian/control or debian/control.in was modified.
def quiet-update-maintainer []: nothing -> nothing {
    let snap = {|p|
        if ($p | path exists) { open --raw $p | hash sha256 } else { "" }
    }
    let before = {
        control: (do $snap "debian/control")
        control_in: (do $snap "debian/control.in")
    }
    let res = (^update-maintainer | complete)
    let after = {
        control: (do $snap "debian/control")
        control_in: (do $snap "debian/control.in")
    }
    if $before != $after {
        if not ($res.stdout | is-empty) { print -n $res.stdout }
        if not ($res.stderr | is-empty) { print -en $res.stderr }
    }
}

# Package navigation, changelog, and lookup commands

use ../completions.nu [pkg-completions]
use ../ubuntu-versions.nu [SUPPORTED_RELEASES, ALL_RELEASES, release-rank]
use meta.nu [last-published-release]
use build.nu [tarme]

# Make a directory and immediately enter it (inlined utility).
def --env mkcd [path: string]: nothing -> nothing {
    mkdir $path
    cd $path
}

# Bump the changelog version, prompt for a target Ubuntu release via gum,
# and update the Maintainer field for Ubuntu.
#
# Flow: gum-choose target release (default-selected to the package's
# most-recent Ubuntu target) → optional older-than confirm → `dch -i`
# (with --distribution if a release was picked, so EDITOR opens with the
# correct distro already set) → update-maintainer → commits.
#
# Picking "(keep UNRELEASED)" or cancelling the picker leaves the entry
# UNRELEASED; cancelling the older-than confirm aborts before any dch call.
#
# By default produces two atomic commits:
#   1. "changelog" — the dch changes
#   2. "update-maintainer" — any debian/control{,​.in} updates
# With --no-commit, stages nothing and makes no commits.
export def dch-bump [
    --no-commit (-n)  # Skip all git add/commit steps
]: nothing -> nothing {
    if (which gum | is-empty) {
        error make { msg: "dch-bump requires gum (sudo apt install gum)" }
    }
    if not (is-terminal --stdin) {
        error make { msg: "dch-bump requires an interactive TTY (gum picker)" }
    }

    let anchor = (last-published-release)
    let supported_newest_first = ($SUPPORTED_RELEASES | reverse)
    let options = ($supported_newest_first ++ ["(keep UNRELEASED)"])

    let preselect = if ($anchor != null) and ($anchor in $SUPPORTED_RELEASES) {
        ["--selected" $anchor]
    } else {
        []
    }

    let pick = (
        $options
        | str join "\n"
        | ^gum choose --header "Target release for new changelog entry:" ...$preselect
        | str trim
    )

    let target = if ($pick | is-empty) or ($pick == "(keep UNRELEASED)") {
        null
    } else {
        $pick
    }

    if $target != null and $anchor != null {
        let pr = (release-rank $target)
        let ar = (release-rank $anchor)
        if $pr >= 0 and $ar >= 0 and $pr < $ar {
            gum confirm $"($target) is older than this package's most-recent target \(($anchor)\). Continue?"
        }
    }

    if $target == null {
        dch -i
    } else {
        dch -i --distribution $target --force-distribution
    }
    quiet-update-maintainer

    if not $no_commit {
        git add debian/changelog
        git commit -m "changelog"

        # Stage any files update-maintainer modified. control.in is optional.
        git add debian/control
        if ("debian/control.in" | path exists) {
            git add debian/control.in
        }
        let staged = (git diff --cached --name-only | lines | where { $in != "" })
        if not ($staged | is-empty) {
            git commit -m "update-maintainer"
        }
    }
}

# Get or go to a package
# If the package exists locally, cd into it. Otherwise, fetch it with git-ubuntu.
# Use -r to force-remove and refetch.
export def --env pkg [
    package: string@pkg-completions # the name of the package to fetch or go to
    --refetch (-r) # Force-remove and refetch the package
]: nothing -> nothing {
    let pkgs_root = ($env.NUBUNTU_PKGS_DIR? | default "~/pkgs" | path expand)
    let pkg_dir = ($pkgs_root | path join $package $package)

    if $refetch {
        gum confirm $"This will delete ($pkgs_root)/($package) and discard any local changes. Continue?"
        cd ~
        rm -rf ($pkgs_root | path join $package)
    }

    if ($pkg_dir | path exists) {
        cd $pkg_dir
    } else {
        mkcd ($pkgs_root | path join $package)
        gum spin --title $"Cloning ($package)..." -- git ubuntu clone $package
        cd $package
        git ubuntu remote add $env.LAUNCHPAD_NAME
        tarme
    }
}

# Package Ownership Check
# Check who a package belongs to, returning all owners as a list.
# Caches the team mapping JSON for one day to avoid repeated downloads.
export def poc [
  package: string # The package to check
]: nothing -> list<string> {
  let cache_file = ([$env.NUBUNTU_CACHE_DIR "package-team-mapping.nuon"] | path join)
  let max_age = 1day

  # Use cached file if fresh enough
  let use_cache = if ($cache_file | path exists) {
      let age = (date now) - ($cache_file | path expand | ls $in | first | get modified)
      $age < $max_age
  } else {
      false
  }

  let data = if $use_cache {
      open $cache_file
  } else {
      let json = (http get https://static-reports.ubuntu.com/package-team-mapping.json)
      $json | save -f $cache_file
      $json
  }

  $data | columns | where {|k| $package in ($data | get $k) }
}

# Fetch reverse dependencies for a package
# Uses apt-cache to find all packages that depend on the given package.
export def revdeps [
    package: string # The package to check reverse dependencies for
]: nothing -> list<string> {
    let output = apt-cache rdepends $package | lines

    if ($output | length) < 2 {
        return []
    }

    # Skip header lines (package name and "Reverse Depends:")
    # Each line may have a dependency type prefix like "Depends:", "Recommends:", etc.
    $output | skip 2 | each {|line|
        $line | str trim | str replace -r '^[A-Za-z]+:\s*' ''
    } | where { $in != "" } | uniq
}
