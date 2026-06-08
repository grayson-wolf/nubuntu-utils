# Ubuntu version name/number registry
#
# Provides a canonical list of all Ubuntu releases, lookup helpers,
# and a supported-releases subset. Append new releases to the table below.

# Every Ubuntu release, in order. Append new entries at the bottom.
export const ALL_RELEASES = [
    { version: "4.10",  name: "warty" }
    { version: "5.04",  name: "hoary" }
    { version: "5.10",  name: "breezy" }
    { version: "6.06",  name: "dapper" }
    { version: "6.10",  name: "edgy" }
    { version: "7.04",  name: "feisty" }
    { version: "7.10",  name: "gutsy" }
    { version: "8.04",  name: "hardy" }
    { version: "8.10",  name: "intrepid" }
    { version: "9.04",  name: "jaunty" }
    { version: "9.10",  name: "karmic" }
    { version: "10.04", name: "lucid" }
    { version: "10.10", name: "maverick" }
    { version: "11.04", name: "natty" }
    { version: "11.10", name: "oneiric" }
    { version: "12.04", name: "precise" }
    { version: "12.10", name: "quantal" }
    { version: "13.04", name: "raring" }
    { version: "13.10", name: "saucy" }
    { version: "14.04", name: "trusty" }
    { version: "14.10", name: "utopic" }
    { version: "15.04", name: "vivid" }
    { version: "15.10", name: "wily" }
    { version: "16.04", name: "xenial" }
    { version: "16.10", name: "yakkety" }
    { version: "17.04", name: "zesty" }
    { version: "17.10", name: "artful" }
    { version: "18.04", name: "bionic" }
    { version: "18.10", name: "cosmic" }
    { version: "19.04", name: "disco" }
    { version: "19.10", name: "eoan" }
    { version: "20.04", name: "focal" }
    { version: "20.10", name: "groovy" }
    { version: "21.04", name: "hirsute" }
    { version: "21.10", name: "impish" }
    { version: "22.04", name: "jammy" }
    { version: "22.10", name: "kinetic" }
    { version: "23.04", name: "lunar" }
    { version: "23.10", name: "mantic" }
    { version: "24.04", name: "noble" }
    { version: "24.10", name: "oracular" }
    { version: "25.04", name: "plucky" }
    { version: "25.10", name: "questing" }
    { version: "26.04", name: "resolute" }
    { version: "26.10", name: "stonking" }
]

# Releases currently in standard or ESM support.
export const SUPPORTED_RELEASES = [
    "focal"     # 20.04 LTS — ESM until 2030
    "jammy"     # 22.04 LTS — standard until 2027
    "noble"     # 24.04 LTS — standard until 2029
    "questing"  # 25.10     — standard until 2026-07
    "resolute"  # 26.04 LTS — standard until 2031
    "stonking"  # 26.10     — current devel
]

# Architectures to request autopkgtests for when a package is Architecture: any/all.
export const ARCHES = ["amd64" "arm64" "armhf" "i386" "ppc64el" "riscv64" "s390x"]

# The current development release.
export const DEVEL_RELEASE = "stonking"

# The latest stable (non-devel) release.
export const LATEST_STABLE_RELEASE = "resolute"

# The latest LTS release.
export const LATEST_LTS_RELEASE = "resolute"

# Look up a release name from its version number (e.g., "24.04" → "noble")
export def version-to-name [version: string]: nothing -> string {
    let match = $ALL_RELEASES | where { $in.version == $version }
    if ($match | is-empty) {
        error make { msg: $"Unknown Ubuntu version: ($version)" }
    }
    $match | first | get name
}

# Look up a version number from its release name (e.g., "noble" → "24.04")
export def name-to-version [name: string]: nothing -> string {
    let match = $ALL_RELEASES | where { $in.name == $name }
    if ($match | is-empty) {
        error make { msg: $"Unknown Ubuntu release name: ($name)" }
    }
    $match | first | get version
}

# Check if a release name is currently supported
export def is-supported [name: string]: nothing -> bool {
    $name in $SUPPORTED_RELEASES
}
