# nubuntu-utils environment defaults
# Source this file BEFORE `use nubuntu-utils/ *` to set required variables.
# Any variable already set in your environment will NOT be overwritten.

# Required: Your Launchpad username (used for PPA paths and git remotes)
# $env.LAUNCHPAD_NAME = "your-lp-username"

# Optional: Directory where packages are cloned (default: ~/pkgs)
$env.NUBUNTU_PKGS_DIR = ($env.NUBUNTU_PKGS_DIR? | default "~/pkgs")

# Optional: Cache directory for nubuntu-utils data (default: ~/.cache/nubuntu-utils)
$env.NUBUNTU_CACHE_DIR = ($env.NUBUNTU_CACHE_DIR? | default ("~/.cache/nubuntu-utils" | path expand))
if not ($env.NUBUNTU_CACHE_DIR | path exists) { mkdir $env.NUBUNTU_CACHE_DIR }

# Optional: Quilt patches directory (default: debian/patches)
$env.QUILT_PATCHES = ($env.QUILT_PATCHES? | default "debian/patches")
