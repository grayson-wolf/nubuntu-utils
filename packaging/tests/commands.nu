# Miscellaneous test commands: running tests locally and displaying request URLs.

use ../build.nu [test-urls]
use ../../completions.nu [release-completions]
use ../../formatting.nu [osc8-link]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]

# Extract autopkgtest request URLs from `ppa tests --show-url` output.
export def ppa-test-urls [
    ppa_name: string
    --proposed (-p)
]: nothing -> list<string> {
    let raw = (ppa tests $ppa_name --show-url | lines)
    let urls = ($raw
        | where { $in =~ "request.cgi" }
        | each {|line| $line | str trim | split row " " | where { $in starts-with "https://" } | first }
    )
    if $proposed {
        $urls
    } else {
        $urls | where { $in !~ "all-proposed" }
    }
}

# Run autopkgtests in a specific distro's lxd image.
# Defaults to the current development release.
export def testin [
  distro: string@release-completions = $DEVEL_RELEASE # The distro to test in
]: nothing -> nothing {
  sudo autopkgtest-build-lxd $"ubuntu-daily:($distro)"
  sudo autopkgtest . --shell-fail -- lxd $"autopkgtest/ubuntu/($distro)/amd64"
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
