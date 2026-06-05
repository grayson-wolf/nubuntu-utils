use nubuntu-utils/ *

def main [...args: string] {
    if ($args | is-empty) {
        sru-list
    } else if ($args | any {|a| $a == "--all-series" or $a == "-A"}) {
        sru-list --all-series
    } else {
        sru-list ($args | first)
    }
}
