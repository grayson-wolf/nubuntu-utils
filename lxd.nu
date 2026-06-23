# LXD container/VM commands

use completions.nu [release-completions, lxd-size-completions]

# Build the lxc/autopkgtest resource-limit args for a VM launch.
# These -c/-d flags are accepted both by `lxc launch` directly and by
# autopkgtest's lxd backend, so spawn/ephemeral and testin all translate
# their typed --memory/--cpus/--disk flags through this one helper.
# Internal helper — not re-exported by the barrel.
export def vm-limit-args [
    memory: string # VM memory limit (e.g. 8GiB)
    cpus: int      # VM CPU count
    disk: string   # VM root disk size (e.g. 40GiB)
]: nothing -> list<string> {
    ["-c" $"limits.memory=($memory)" "-c" $"limits.cpu=($cpus)" "-d" $"root,size=($disk)"]
}

# Spawn an LXD container/VM and immediately enter a shell for it.
# Pass --vm for a virtual machine; --memory/--cpus/--disk size it (VM only).
export def spawn [
    image: string                  # The image to use for the container/VM
    name: string                   # the name of the container/VM
    --vm                           # Launch a virtual machine instead of a container
    --memory (-m): string@lxd-size-completions = "8GiB" # VM memory limit (VM only)
    --cpus (-c): int = 4           # VM CPU count (VM only)
    --disk (-d): string@lxd-size-completions = "40GiB"  # VM root disk size (VM only)
]: nothing -> nothing {
    let vm_args = if $vm {
        ["--vm" ...(vm-limit-args $memory $cpus $disk)]
    } else { [] }
    gum spin --show-error --title $"Launching ($name)..." -- lxc launch $image $name ...$vm_args

    # If launching a VM, wait for the internal agent to be ready
    if $vm {
        let wait_script = $"while ! lxc exec ($name) -- true 2>/dev/null; do sleep 0.25; done"
        gum spin --title "Waiting for LXD VM Agent to start..." -- sh -c $wait_script
    }

    lxc shell $name
}

# Gracefully stop and delete an lxc container.
export def lxc-reap [
    container_name: string # the name of the container to reap.
]: nothing -> nothing {
    gum spin --title $"Stopping ($container_name)" -- lxc stop $container_name
    gum spin --title $"Despawning ($container_name)" -- lxc delete $container_name
}

# Ephemeral Spawn
# Spawns an LXD container/VM and enters a shell for it.
# Upon exiting the shell, the container is stopped and deleted.
# Pass --vm for a virtual machine; --memory/--cpus/--disk size it (VM only).
export def ephemeral [
    distro: string@release-completions # The image version to use (uses ubuntu-daily)
    --minimal                          # Use ubuntu-daily-minimal instead of ubuntu-daily
    --vm                               # Launch a virtual machine instead of a container
    --memory (-m): string@lxd-size-completions = "8GiB" # VM memory limit (VM only)
    --cpus (-c): int = 4               # VM CPU count (VM only)
    --disk (-d): string@lxd-size-completions = "40GiB"  # VM root disk size (VM only)
]: nothing -> nothing {
    let image_name = if $minimal {
        $"ubuntu-daily-minimal:($distro)"
    } else {
        $"ubuntu-daily:($distro)"
    }

    # Unix timestamp mod 10000, to avoid clashes
    let t = date now | into int | ($in // 1_000_000_000) mod 10000
    let container_name = $"ephemeral-($distro)-($t)"

    spawn $image_name $container_name --vm=$vm --memory $memory --cpus $cpus --disk $disk
    lxc-reap $container_name
}

# Reap all orphaned ephemeral containers.
# Targets only containers whose names start with "ephemeral-" to avoid
# accidentally destroying user-created containers.
export def lxc-reap-all []: nothing -> nothing {
    let containers = (lxc list -f json
        | from json
        | where { $in.name | str starts-with "ephemeral-" }
        | get name)

    if ($containers | is-empty) {
        print "No ephemeral containers to clean up."
        return
    }

    for name in $containers {
        print $"Reaping ($name)..."
        lxc stop $name --force | ignore
        lxc delete $name | ignore
    }
    print $"Cleaned up ($containers | length) container\(s\)."
}

# List all images at a given source into a nushell table.
# Pass an optional alias substring to filter results (e.g., `images ubuntu-daily: resolute`).
export def images [
    source: string                          # The LXD remote to list (e.g., ubuntu-daily:)
    alias?: string@release-completions      # Optional alias substring to filter by
]: nothing -> table {
    let imgs = (lxc image list $source -f json | from json | update aliases { default [] })
    if ($alias | is-empty) {
        $imgs
    } else {
        $imgs | where {|row| $row.aliases | any {|a| ($a.name | str downcase) =~ ($alias | str downcase) } }
    }
}
