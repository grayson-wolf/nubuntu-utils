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
# Automatically uses a VM if any test requires isolation-machine.
# VMs get a fixed resource allocation (unlike containers, which share the
# host), so --memory/--cpus tune the VM to avoid OOM during the build.
export def testin [
    distro: string@release-completions = $DEVEL_RELEASE # The distro to test in
    --memory (-m): string = "8GiB"                       # VM memory limit (VM backend only)
    --cpus (-c): int = 4                                 # VM CPU count (VM backend only)
    --disk (-d): string = "40GiB"                        # VM root disk size (VM backend only)
]: nothing -> nothing {
    sudo -v
    let needs_vm = (
        ("debian/tests/control" | path exists)
        and (open debian/tests/control | str contains "isolation-machine")
    )
    let vm_flag = if $needs_vm { ["--vm"] } else { [] }
    let image_suffix = if $needs_vm { "/vm" } else { "" }
    let backend = if $needs_vm { "VM" } else { "container" }
    let launch_args = if $needs_vm {
        ["-c" $"limits.memory=($memory)" "-c" $"limits.cpu=($cpus)" "-d" $"root,size=($disk)"]
    } else { [] }
    gum spin --show-error --title $"Building LXD ($backend) image for ($distro)..." -- sudo autopkgtest-build-lxd ...$vm_flag $"ubuntu-daily:($distro)"
    sudo autopkgtest . --shell-fail -- lxd $"autopkgtest/ubuntu/($distro)/amd64($image_suffix)" ...$launch_args
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
