# Package navigation: find/clone packages and inspect their ownership.

use ../completions.nu [pkg-completions]
use ../formatting.nu [with-spinner]
use cache.nu *
use build.nu [tarme]
use source-packages.nu [is-known-source-package]
use http.nu [static-reports-get]

const TEAM_MAPPING_PATH = "package-team-mapping.json"

# Make a directory and immediately enter it.
def --env mkcd [path: string]: nothing -> nothing {
    mkdir $path
    cd $path
}

# Get or go to a package
# If the package exists locally, cd into it. Otherwise, fetch it with git-ubuntu.
# Use -r to force-remove and refetch the package.
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
        match (with-spinner $"Validating ($package)..." { is-known-source-package $package }) {
            false => { error make { msg: $"($package) is not a known source package in Ubuntu or Debian." } }
            null => { print -e $"(ansi yellow)Could not verify ($package) \(offline?\); proceeding anyway.(ansi reset)" }
            true => {}
        }

        mkcd ($pkgs_root | path join $package)
        gum spin --title $"Cloning ($package)..." -- git ubuntu clone $package
        cd $package
        git ubuntu remote add $env.LAUNCHPAD_NAME
        try { git branch debian/sid pkg/debian/sid }
        tarme
    }
}

# True when the mapping has the expected shape
def is-team-mapping [data]: nothing -> bool {
    ($data | describe | str starts-with "record")
}

def fetch-team-mapping []: nothing -> any {
    static-reports-get $TEAM_MAPPING_PATH {|d| if (is-team-mapping $d) { $d } else { null } }
}

# Package Ownership Check
# Check who a package belongs to, returning all owners as a list.
# Caches the team mapping JSON for one day to avoid repeated downloads.
export def poc [
  package: string # The package to check
]: nothing -> list<string> {
  let cache_file = (cache-file-flat "package-team-mapping.nuon")
  let cached = (cache-load $cache_file 1day)
  let data = if (is-team-mapping $cached) { $cached } else {
      let json = with-spinner "Fetching package-team mapping..." { fetch-team-mapping }
      if (is-team-mapping $json) { cache-save $cache_file $json }
      $json
  }

  if not (is-team-mapping $data) {
    error make { msg: "No valid package-team mapping available: tried static-reports.ubuntu.com and static-reports.staging.ubuntu.com" }
  }

  $data | columns | where {|k| $package in ($data | get $k) }
}
