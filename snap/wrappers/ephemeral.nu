use nubuntu-utils/ *

def main [
    distro: string
    --minimal(-m)
    ...launch_flags: string
] {
    ephemeral $distro --minimal=$minimal ...$launch_flags
}
