# Package navigation: find/clone packages and inspect their ownership.

use ../completions.nu [pkg-completions]
use ../formatting.nu [with-spinner]
use cache.nu *
use build.nu [tarme]

# Make a directory and immediately enter it.
def --env mkcd [path: string]: nothing -> nothing {
    mkdir $path
    cd $path
}

# Check whether a package name exists in the Ubuntu or Debian archive via rmadison.
# Returns true if found in either archive, false otherwise.
def pkg-valid [package: string]: nothing -> bool {
    let ubuntu = (rmadison $package | complete)
    if not ($ubuntu.stdout | str trim | is-empty) { return true }
    let debian = (rmadison -u debian $package | complete)
    not ($debian.stdout | str trim | is-empty)
}

# Get or go to a package
# If the package exists locally, cd into it. Otherwise, fetch it with git-ubuntu.
# Use -r to force-remove and refetch the package.
# Validates the package name against the archive before any filesystem changes.
# On fresh clones, creates a local `debian/sid` branch tracking `pkg/debian/sid`.
export def --env pkg [
    package: string@pkg-completions # the name of the package to fetch or go to
    --refetch (-r) # Force-remove and refetch the package
]: nothing -> nothing {
    let pkgs_root = ($env.NUBUNTU_PKGS_DIR | path expand)
    let pkg_dir = ($pkgs_root | path join $package $package)
    let pkg_parent_dir = ($pkgs_root | path join $package)

    if ($pkg_parent_dir | path exists) and $refetch {
        gum confirm $"This will delete ($pkg_parent_dir) and discard any local changes. Continue?"
        cd ~
        rm -rf $pkg_parent_dir
    }

    if ($pkg_dir | path exists) {
        cd $pkg_dir
    } else {
        let valid = with-spinner $"Validating ($package)..." { pkg-valid $package }
        if not $valid {
            error make { msg: $"($package) is not a known source package in Ubuntu or Debian." }
        }

        mkcd ($pkgs_root | path join $package)
        gum spin --title $"Cloning ($package)..." -- git ubuntu clone $package
        cd $package
        git ubuntu remote add $env.LAUNCHPAD_NAME
        try { git branch debian/sid pkg/debian/sid }
        tarme
    }
}

# Package Ownership Check
# Check who a package belongs to, returning all owners as a list.
# Caches the team mapping JSON for one day to avoid repeated downloads.
export def poc [
  package: string # The package to check
]: nothing -> list<string> {
  let cache_file = (cache-file-flat "package-team-mapping.nuon")
  let cached = (cache-load $cache_file 1day)
  let data = if $cached != null { $cached } else {
      let json = with-spinner "Fetching package-team mapping..." {
          http get https://static-reports.ubuntu.com/package-team-mapping.json
      }
      cache-save $cache_file $json
      $json
  }

  $data | columns | where {|k| $package in ($data | get $k) }
}
