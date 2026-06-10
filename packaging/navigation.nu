# Package navigation: find/clone packages and inspect their ownership.

use ../completions.nu [pkg-completions]
use build.nu [tarme]

# Make a directory and immediately enter it.
def --env mkcd [path: string]: nothing -> nothing {
    mkdir $path
    cd $path
}

# Get or go to a package
# If the package exists locally, cd into it. Otherwise, fetch it with git-ubuntu.
# Use -r to force-remove and refetch.
export def --env pkg [
    package: string@pkg-completions # the name of the package to fetch or go to
    --refetch (-r) # Force-remove and refetch the package
]: nothing -> nothing {
    let pkgs_root = ($env.NUBUNTU_PKGS_DIR | path expand)
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
