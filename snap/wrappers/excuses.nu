use nubuntu-utils/ *

def main [
    package?: string
    --series(-s): string = "stonking"
    --raw(-r)
    --all(-a)
] {
    if $raw {
        excuses $package -s $series --raw
    } else {
        excuses $package -s $series --all=$all
    }
}
