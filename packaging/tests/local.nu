# Local LXD container/VM build + test commands.
# `buildin` builds the source package inside a clean LXD container
# `testin` runs the package's own autopkgtests (picking a VM when isolation is
# required).

use ../build.nu [cpbd, tarme]
use ../../completions.nu [release-completions, lxd-size-completions, local-test-completions]
use ../../lxd.nu [vm-limit-args]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]
use ../meta.nu [pkg-name, pkg-version]
use ../../formatting.nu [with-spinner]

# Fetch a package's archive debian/tests/control for a series (via
# pull-lp-source) and report whether any test requires isolation-machine.
# Returns false when the control can't be fetched/parsed (fail open to the
# container default; --vm remains the explicit override).
def archive-control-needs-vm [pkg: string, series: string]: nothing -> bool {
    let tmp = (mktemp -d)
    let probe = with-spinner $"Fetching ($pkg) archive test control for ($series)..." {
        # pull-lp-source extracts the tree; we only need the debian tarball's
        # debian/tests/control. Run in $tmp to keep the cwd clean.
        let result = (do { cd $tmp; ^pull-lp-source $pkg $series } | complete)
        if $result.exit_code != 0 { return false }
        let control = (glob $"($tmp)/($pkg)-*/debian/tests/control" | first | default "")
        if ($control | is-empty) { return false }
        (open $control | str contains "isolation-machine")
    }
    rm -rf $tmp
    $probe
}

# Build a package in a clean LXD container for a given distro.
export def buildin [
    distro: string@release-completions # The distro to build in (e.g., noble, resolute, stonking)
    --binary (-b)                      # Also build binary packages
]: nothing -> nothing {
    let pkg = (pkg-name)
    let ver = (pkg-version)
    let container = $"($pkg)-buildin-($distro)"
    let parent = (pwd | path dirname)

    # Clean any previous container with the same name
    let existing = (lxc list --format json | from json | where name == $container)
    if ($existing | is-not-empty) {
        print $"Removing stale container ($container)..."
        lxc stop $container --force | ignore
        lxc delete $container | ignore
    }

    # Ensure the LXD image exists
    let image = $"autopkgtest/ubuntu/($distro)/amd64"
    let img_exists = (lxc image list --format json | from json | where { $in.aliases | any { $in.name == $image } })
    if ($img_exists | is-empty) {
        sudo -v
        gum spin --show-error --title $"Building LXD image for ($distro)..." -- sudo autopkgtest-build-lxd $"ubuntu-daily:($distro)"
    }

    # Launch container
    gum spin --show-error --title $"Launching ($container)..." -- lxc launch $image $container

    # Wait for network
    with-spinner "Waiting for container network..." {
        mut ready = false
        while not $ready {
            let result = (^lxc exec $container -- ip -4 addr show scope global | complete)
            $ready = ($result.exit_code == 0) and ($result.stdout | str contains "inet")
            if not $ready { sleep 1sec }
        }
    }

    # Refresh apt lists first — autopkgtest LXD images are baked at a point
    # in time and their package lists go stale (old .debs 404 once superseded
    # in the archive).
    gum spin --show-error --title "Updating apt lists in container..." -- lxc exec $container -- apt-get update -qq

    # Install build tooling
    gum spin --show-error --title "Installing build tools in container..." -- lxc exec $container -- apt-get install -y -qq build-essential debhelper devscripts equivs

    # Copy source tree into container (tar pipe). Exclude VCS internals and
    # gitignored/untracked artifacts
    with-spinner $"Copying ($pkg) source into container..." {
        let result = (^tar czf - -C $parent --exclude-vcs --exclude-vcs-ignores --exclude='.pc' $pkg | ^lxc exec $container -- tar xzf - -C /root/ | complete)
        if $result.exit_code != 0 {
            error make { msg: $"Failed to copy source into container: ($result.stderr)" }
        }
    }

    # Install build dependencies
    gum spin --show-error --title "Installing build dependencies..." -- lxc exec $container -- bash -c $"cd /root/($pkg) && apt-get build-dep -y -qq ."

    # Fetch orig tarball
    gum spin --show-error --title "Fetching orig tarball..." -- lxc exec $container -- bash -c $"cd /root/($pkg) && origtargz"

    # Remove any stale build-deps meta-package artifacts that would break dpkg-source
    lxc exec $container -- bash -c $"rm -f /root/($pkg)/($pkg)-build-deps_*" | ignore

    # Build package (unsigned — we sign locally after pulling artifacts).
    let build_cmd = if $binary {
        $"cd /root/($pkg) && debuild -d -us -uc"
    } else {
        $"cd /root/($pkg) && debuild -S -sa -d -us -uc"
    }
    gum spin --show-error --title $"Building ($pkg) for ($distro)..." -- lxc exec $container -- bash -c $build_cmd

    # The .changes/.buildinfo suffix differs by mode: source-only emits
    # <ver>_source.*; a full (binary) build emits <ver>_<arch>.*.
    let changes = if $binary { $"($pkg)_($ver)_amd64.changes" } else { $"($pkg)_($ver)_source.changes" }
    let buildinfo = if $binary { $"($pkg)_($ver)_amd64.buildinfo" } else { $"($pkg)_($ver)_source.buildinfo" }

    # Pull artifacts back (all land in /root/ — the parent of /root/$pkg)
    let upstream_ver = ($ver | str replace -r '^[0-9]+:' '' | str replace -r '-[^-]+$' '')
    let artifacts = [
        $"($pkg)_($ver).dsc"
        $"($pkg)_($ver).debian.tar.xz"
        $buildinfo
        $changes
    ]

    with-spinner "Pulling build artifacts..." {
        for f in $artifacts {
            ^lxc file pull $"($container)/root/($f)" $"($parent)/" | complete | ignore
        }

        # Binary build outputs (--binary): pull the built .deb(s) too.
        if $binary {
            let matches = (^lxc exec $container -- bash -c $"ls /root/($pkg)_($ver)_*.deb 2>/dev/null" | complete)
            if $matches.exit_code == 0 {
                for f in ($matches.stdout | lines | where { $in | is-not-empty }) {
                    ^lxc file pull $"($container)/root/($f)" $"($parent)/" | complete | ignore
                }
            }
        }

        # orig tarball: may be .tar.gz or .tar.xz, placed alongside the .dsc in /root/
        for ext in [gz xz bz2 lzma] {
            let f = $"/root/($pkg)_($upstream_ver).orig.tar.($ext)"
            let exists = (^lxc exec $container -- test -f $f | complete).exit_code == 0
            if $exists {
                ^lxc file pull $"($container)($f)" $"($parent)/" | complete | ignore
            }
        }
    }

    # Sign locally
    let key = ($env.DEBSIGN_KEYID? | default "")
    if ($key | is-empty) {
        print $"(ansi yellow)DEBSIGN_KEYID not set — skipping signing.(ansi reset)"
        print $"Artifacts in ($parent):"
        print $"  ($pkg)_($ver).dsc"
        print $"  ($changes)"
        print $"  ($buildinfo)"
        print $"  ($pkg)_($ver).debian.tar.xz"
    } else {
        # Signing must NOT run inside a spinner: debsign prompts on the real
        # terminal for the GPG pin (a YubiKey tap/PIN here), and a spinner
        # job writing \r frames to /dev/tty corrupts that prompt. (Same class
        # as the sudo and autopkgtest --shell-fail no-spinner exceptions.)
        print $"Signing package with key ($key)..."
        cd $parent
        let dsc_result = (^debsign $"-k($key)" $"($pkg)_($ver).dsc" | complete)
        if $dsc_result.exit_code != 0 {
            error make { msg: $"debsign failed on .dsc: ($dsc_result.stderr)" }
        }
        let changes_result = (^debsign $"-k($key)" $changes | complete)
        if $changes_result.exit_code != 0 {
            error make { msg: $"debsign failed on .changes: ($changes_result.stderr)" }
        }
        print $"Signed artifacts in ($parent):"
        print $"  ($pkg)_($ver).dsc"
        print $"  ($changes)"
        print $"  ($buildinfo)"
        print $"  ($pkg)_($ver).debian.tar.xz"
        if $binary {
            let debs = (glob $"($parent)/($pkg)_($ver)_*.deb")
            for deb in $debs { print $"  ($deb | path basename)" }
        }
    }

    # Cleanup container
    with-spinner $"Reaping ($container)..." {
        ^lxc stop $container --force | complete | ignore
        ^lxc delete $container | complete | ignore
    }
}

# Run autopkgtests in a specific distro's lxd image.
# Defaults to the current development release.
# Automatically uses a VM if any test requires isolation-machine; --vm forces
# the VM backend even when no test demands it.
# VMs get a fixed resource allocation (unlike containers, which share the
# host), so --memory/--cpus/--disk tune the VM to avoid OOM during the build.
export def testin [
    distro: string@release-completions = $DEVEL_RELEASE # The distro to test in
    --proposed (-p)                                      # Enable the proposed pocket in the testbed (apt-pocket=proposed)
    --against: string                                    # Run this package's archive test suite against the local build
    --test: string@local-test-completions                # Run only the named test (autopkgtest --test-name)
    --vm                                                 # Force the VM backend (auto-enabled for isolation-machine tests)
    --memory (-m): string@lxd-size-completions = "8GiB"  # VM memory limit (VM backend only)
    --cpus (-c): int = 4                                 # VM CPU count (VM backend only)
    --disk (-d): string@lxd-size-completions = "40GiB"   # VM root disk size (VM backend only)
]: nothing -> nothing {
    sudo -v

    # --against: the test suite is the *archive* source of another package
    # The binaries under test come from a binary build's .changes in the parent dir;
    # if there isn't one yet, build it now
    let test_args = if ($test | is-not-empty) { [$"--test-name=($test)"] } else { [] }
    let pkg_args = if ($against | is-not-empty) {
        let ver = (pkg-version)
        mut found = (glob $"../*_($ver)_amd64.changes" | first | default "")
        if ($found | is-empty) {
            print $"(ansi yellow)No binary build found for ($ver) — building one with buildin --binary first.(ansi reset)"
            buildin $distro --binary
            $found = (glob $"../*_($ver)_amd64.changes" | first | default "")
            if ($found | is-empty) {
                error make { msg: $"buildin --binary did not produce a ../*_($ver)_amd64.changes" }
            }
        }
        # testbinary (.changes) first, then the testsrc (bare archive source name)
        [($found | path expand) $against]
    } else { ["."] }

    # VM detection reads the relevant debian/tests/control: the package's own
    # by default, or the --against package's archive control (fetched via
    # pull-lp-source) when --against is set.
    let local_needs_vm = (
        ("debian/tests/control" | path exists)
        and (open debian/tests/control | str contains "isolation-machine")
    )
    let suite_needs_vm = if ($against | is-not-empty) {
        archive-control-needs-vm $against $distro
    } else { $local_needs_vm }
    let needs_vm = ($vm or $suite_needs_vm)
    let vm_flag = if $needs_vm { ["--vm"] } else { [] }
    let image_suffix = if $needs_vm { "/vm" } else { "" }
    let backend = if $needs_vm { "VM" } else { "container" }
    let launch_args = if $needs_vm { (vm-limit-args $memory $cpus $disk) } else { [] }
    let proposed_args = if $proposed { ["--apt-pocket=proposed"] } else { [] }
    gum spin --show-error --title $"Building LXD ($backend) image for ($distro)..." -- sudo autopkgtest-build-lxd ...$vm_flag $"ubuntu-daily:($distro)"
    sudo autopkgtest ...$pkg_args --shell-fail ...$test_args ...$proposed_args -- lxd $"autopkgtest/ubuntu/($distro)/amd64($image_suffix)" ...$launch_args
}
