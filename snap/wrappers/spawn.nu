use nubuntu-utils/ *

def main [
    image: string
    name: string
    ...rest: string
] {
    spawn $image $name ...$rest
}
