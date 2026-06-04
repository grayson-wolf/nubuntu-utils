use nubuntu-utils/ *

def --env main [
    package: string
    --refetch(-r)
] {
    pkg $package --refetch=$refetch
}
