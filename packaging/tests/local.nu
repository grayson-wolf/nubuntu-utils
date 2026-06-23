# Local LXD container/VM build + test commands.
# Both build a fresh LXD image for a series and run autopkgtest against it:
# `buildin` builds the source and runs autopkgtest in build-only mode;
# `testin` runs the package's own autopkgtests (picking a VM when isolation is
# required).

use ../build.nu [cpbd, tarme]
use ../../completions.nu [release-completions, lxd-size-completions]
use ../../lxd.nu [vm-limit-args]
use ../../ubuntu-versions.nu [DEVEL_RELEASE]

# Build binary packages in a clean LXD container for a given distro.
# Ensures the LXD image exists, builds the source, then runs autopkgtest
# in build-only mode. Results land in the parent directory alongside the source.
export def buildin [
    distro: string@release-completions # The distro to build in (e.g., noble, resolute, stonking)
]: nothing -> nothing {
    sudo -v
    gum spin --show-error --title $"Building LXD image for ($distro)..." -- sudo autopkgtest-build-lxd $"ubuntu-daily:($distro)"
    cpbd
    tarme
    gum spin --show-error --title $"Building source for ($distro)..." -- debuild -S -sa -d
    gum spin --show-error --title $"Running autopkgtest for ($distro)..." -- sudo autopkgtest ../*.dsc --copy $"(pwd)/.." -- lxd $"autopkgtest/ubuntu/($distro)/amd64"
}

# Run autopkgtests in a specific distro's lxd image.
# Defaults to the current development release.
# Automatically uses a VM if any test requires isolation-machine; --vm forces
# the VM backend even when no test demands it.
# VMs get a fixed resource allocation (unlike containers, which share the
# host), so --memory/--cpus/--disk tune the VM to avoid OOM during the build.
export def testin [
    distro: string@release-completions = $DEVEL_RELEASE # The distro to test in
    --vm                                                 # Force the VM backend (auto-enabled for isolation-machine tests)
    --memory (-m): string@lxd-size-completions = "8GiB"  # VM memory limit (VM backend only)
    --cpus (-c): int = 4                                 # VM CPU count (VM backend only)
    --disk (-d): string@lxd-size-completions = "40GiB"   # VM root disk size (VM backend only)
]: nothing -> nothing {
    sudo -v
    let needs_vm = (
        $vm
        or (
            ("debian/tests/control" | path exists)
            and (open debian/tests/control | str contains "isolation-machine")
        )
    )
    let vm_flag = if $needs_vm { ["--vm"] } else { [] }
    let image_suffix = if $needs_vm { "/vm" } else { "" }
    let backend = if $needs_vm { "VM" } else { "container" }
    let launch_args = if $needs_vm { (vm-limit-args $memory $cpus $disk) } else { [] }
    gum spin --show-error --title $"Building LXD ($backend) image for ($distro)..." -- sudo autopkgtest-build-lxd ...$vm_flag $"ubuntu-daily:($distro)"
    sudo autopkgtest . --shell-fail -- lxd $"autopkgtest/ubuntu/($distro)/amd64($image_suffix)" ...$launch_args
}
