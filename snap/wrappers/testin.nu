use nubuntu-utils/ *

def main [distro?: string] {
    if ($distro | is-empty) {
        testin
    } else {
        testin $distro
    }
}
