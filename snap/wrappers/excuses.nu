use nubuntu-utils/ *
use nubuntu-utils/ubuntu-versions.nu [DEVEL_RELEASE]

def main [
    package?: string
    --series(-s): string
    --raw(-r)
    --all(-a)
    --why(-w)
] {
    let s = ($series | default $DEVEL_RELEASE)
    if $raw {
        excuses $package -s $s --raw
    } else {
        excuses $package -s $s --all=$all --why=$why
    }
}
