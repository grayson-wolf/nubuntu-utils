use nubuntu-utils/ *

def main [container_name: string] {
    lxc-reap $container_name
}
