# Building source packages and managing build artifacts

use meta.nu [target-release, pkg-upstream-version, pkg-version, pkg-name]
use launchpad.nu [normalize-ppa-name]
use ../completions.nu [release-completions]
use ../ubuntu-versions.nu [ARCHES]

# Clear Parent Build Directory
# wipes debbuilds from the parent directory
export def cpbd []: nothing -> nothing {
    let patterns = [
        "../*.debian.tar.xz"
        "../*.dsc"
        "../*_source.build"
        "../*_source.buildinfo"
        "../*_source.changes"
        "../*_source.ppa.upload"
        "../*amd*.build"
    ]
    $patterns | each { glob $in } | flatten | each { rm -f $in } | ignore
}

# Fetch the orig tarball for the current package if not already present.
# Tries git-ubuntu export-orig first, falls back to origtargz.
export def tarme []: nothing -> nothing {
  let pkg_name = pkg-name
  let version = pkg-upstream-version

  # Check if any orig tarball already exists in parent directory (including component tarballs)
  let existing = (glob $"../($pkg_name)_($version).orig*.tar.*")
  if not ($existing | is-empty) {
    print $"Orig tarball for ($pkg_name) ($version) already exists."
    return
  }

  # Try git-ubuntu export-orig first
  try {
    gum spin --title $"Fetching orig tarball for ($pkg_name) ($version) with git-ubuntu..." -- git ubuntu export-orig
  } catch {
    gum spin --title $"Fetching orig tarball for ($pkg_name) ($version) with origtargz..." -- origtargz
  }
}

# Install build dependencies for the current package
# Uses mk-build-deps to create a meta-package and installs it via apt.
# Cleans up the generated .deb, .buildinfo, and .changes files afterward.
export def getdeps []: nothing -> nothing {
    let pkg_name = pkg-name
    sudo mk-build-deps --install --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y"
    glob $"($pkg_name)-build-deps_*.deb" | each { rm -f $in }
    glob $"($pkg_name)-build-deps_*.buildinfo" | each { rm -f $in }
    glob $"($pkg_name)-build-deps_*.changes" | each { rm -f $in }
}

# PPA Name Generator
# Generates a PPA name based on the package directory name, release, and the hash of the most recent .changes file.
export def gen-ppa-name []: nothing -> string {
    let pkg_name = pkg-name
    let changes_hash = sha256sum ../*.changes | str substring 0..7
    $"($pkg_name)-(target-release)-($changes_hash)" | str downcase
}

# Generate autopkgtest request URLs for the current package's PPA upload.
# Returns a table of {arch, url, proposed} records.
export def test-urls [
    --proposed (-p) # Include all-proposed variants
]: nothing -> table<arch: string, url: string, proposed: bool> {
    let pkg_name = pkg-name
    let version = pkg-version
    let release_name = target-release
    let ppa = gen-ppa-name

    # Parse architectures from debian/control
    let arches = (open debian/control
        | lines
        | where { str starts-with "Architecture:" }
        | each { split row ":" | get 1 | str trim | split row " " }
        | flatten
        | uniq)

    # Expand "any"/"all" to common Ubuntu architectures
    let arches = if "any" in $arches or "all" in $arches {
        $ARCHES
    } else {
        $arches
    }

    let trigger = $"($pkg_name)/($version)" | url encode
    let ppa_param = (normalize-ppa-name $ppa) | url encode

    mut urls = []
    for arch in $arches {
        let base_url = $"https://autopkgtest.ubuntu.com/request.cgi?release=($release_name)&package=($pkg_name)&arch=($arch)&trigger=($trigger)&ppa=($ppa_param)&"
        $urls = ($urls | append { arch: $arch, url: $base_url, proposed: false })
        if $proposed {
            $urls = ($urls | append { arch: $arch, url: $"($base_url)all-proposed=1", proposed: true })
        }
    }
    $urls
}

# Build binary packages in a clean LXD container for a given distro.
# Ensures the LXD image exists, builds the source, then runs autopkgtest
# in build-only mode. Results land in the parent directory alongside the source.
export def buildin [
    distro: string@release-completions # The distro to build in (e.g., noble, resolute, stonking)
]: nothing -> nothing {
    sudo autopkgtest-build-lxd $"ubuntu-daily:($distro)"
    cpbd
    tarme
    debuild -S -sa -d
    sudo autopkgtest ../*.dsc --copy $"(pwd)/.." -- lxd $"autopkgtest/ubuntu/($distro)/amd64"
}
