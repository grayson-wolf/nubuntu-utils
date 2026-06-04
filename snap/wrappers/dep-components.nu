use nubuntu-utils/ *

def main [
    package: string
    --recursive(-r)
    --build(-b)
    --all(-a)
] {
    dep-components $package --recursive=$recursive --build=$build --all=$all
}
