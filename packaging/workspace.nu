# Package navigation, changelog, and lookup commands

use ../completions.nu [pkg-completions]
use build.nu [tarme]

# Make a directory and immediately enter it (inlined utility).
def --env mkcd [path: string]: nothing -> nothing {
    mkdir $path
    cd $path
}

# Bump the changelog version, commit it, then update the Maintainer field for Ubuntu.
# Produces two atomic commits:
#   1. "changelog" — the dch -i change to debian/changelog
#   2. "update-maintainer" — any Maintainer field updates (debian/control, debian/control.in)
export def dch-bump []: nothing -> nothing {
    dch -i
    git add debian/changelog
    git commit -m "changelog"

    update-maintainer
    # Stage any files update-maintainer modified, then check if there's anything to commit
    git add debian/control debian/control.in 2>/dev/null | ignore
    let staged = (git diff --cached --name-only | lines | where { $in != "" })
    if not ($staged | is-empty) {
        git commit -m "update-maintainer"
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
  let cache_file = ("~/.cache/package-team-mapping.nuon" | path expand)
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
