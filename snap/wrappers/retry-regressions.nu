use nubuntu-utils/ *
use nubuntu-utils/ubuntu-versions.nu [DEVEL_RELEASE]

def main [
    package?: string
    --series(-s): string
    --all-proposed(-p)
    --no-select(-n)
    --rev(-r)
] {
    let s = ($series | default $DEVEL_RELEASE)
    retry-regressions $package -s $s --all-proposed=$all_proposed --no-select=$no_select --rev=$rev
}
