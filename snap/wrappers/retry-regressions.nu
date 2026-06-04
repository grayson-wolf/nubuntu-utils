use nubuntu-utils/ *

def main [
    package?: string
    --series(-s): string = "stonking"
    --all-proposed(-p)
    --no-select(-n)
    --rev(-r)
] {
    retry-regressions $package -s $series --all-proposed=$all_proposed --no-select=$no_select --rev=$rev
}
