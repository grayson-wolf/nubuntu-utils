# Building source packages and managing build artifacts

use meta.nu [target-release, pkg-upstream-version, pkg-version, pkg-name]
use launchpad.nu [normalize-ppa-name]
use ../formatting.nu [osc8-link]
use ../ubuntu-versions.nu [ARCHES]
use tests/log-parsing.nu [request-url]

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
    sudo -v
    gum spin --show-error --title $"Installing build dependencies for ($pkg_name)..." -- sudo mk-build-deps --install --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y"
    glob $"($pkg_name)-build-deps_*.deb" | each { rm -f $in }
    glob $"($pkg_name)-build-deps_*.buildinfo" | each { rm -f $in }
    glob $"($pkg_name)-build-deps_*.changes" | each { rm -f $in }
}

# PPA Name Generator
# Generates a PPA name based on the package directory name, release, and the hash of the most recent .changes file.
export def gen-ppa-name []: nothing -> string {
    let pkg_name = pkg-name
    let changes_hash = sha256sum ../*.changes | str substring 0..7
    $"($pkg_name)-(target-release)-($changes_hash)" | str lowercase
}

# Generate autopkgtest request URLs for the current package's PPA upload.
# Returns a table of {arch, url, proposed} records.
export def test-urls [
    --proposed (-p)           # Include all-proposed variants
    --against: string         # Run this package's test suite against the upload
]: nothing -> table<arch: string, url: string, proposed: bool> {
    let pkg_name = pkg-name
    let version = pkg-version
    let release_name = target-release
    let ppa = gen-ppa-name
    let test_pkg = if ($against | is-not-empty) { $against } else { $pkg_name }

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

    let ppa_param = (normalize-ppa-name $ppa)

    mut urls = []
    for arch in $arches {
        let params = {
            release: $release_name
            package: $test_pkg
            arch: $arch
            trigger: $"($pkg_name)/($version)"
            ppa: $ppa_param
        }
        $urls = ($urls | append { arch: $arch, url: (request-url $params), proposed: false })
        if $proposed {
            $urls = ($urls | append { arch: $arch, url: (request-url ($params | insert all-proposed "1")), proposed: true })
        }
    }
    $urls
}

# Extract autopkgtest request URLs from `ppa tests --show-url` output.
export def ppa-test-urls [
    ppa_name: string
    --proposed (-p)
    --against: string         # Run this package's test suite instead of the upload's own
]: nothing -> list<string> {
    let raw = (ppa tests $ppa_name --show-url | lines)
    let urls = ($raw
        | where { $in =~ "request.cgi" }
        | each {|line| $line | str trim | split row " " | where { $in starts-with "https://" } | first }
    )
    let urls = if $proposed {
        $urls
    } else {
        $urls | where { $in !~ "all-proposed" }
    }
    if ($against | is-empty) {
        $urls
    } else {
        $urls | each {|url|
            let params = ($url | url parse | get params | reduce --fold {} {|p, acc| $acc | upsert $p.key $p.value })
            request-url ($params | upsert package $against)
        }
    }
}

# Display autopkgtest request URLs for the current package's PPA upload across all architectures.
# Shows clickable hyperlinks for both base and proposed variants.
export def testurl []: nothing -> nothing {
    let urls = test-urls --proposed

    # Group by arch and display with hyperlinks
    let arches = ($urls | get arch | uniq)
    for arch in $arches {
        let base = ($urls | where { $in.arch == $arch and not $in.proposed } | first | get url)
        let proposed = ($urls | where { $in.arch == $arch and $in.proposed } | first | get url)
        let b_link = (osc8-link $base "[B]")
        let p_link = (osc8-link $proposed "[P]")
        print $"($arch): ($b_link) ($p_link)\n($base)\n"
    }
}
