# nubuntu-utils environment defaults
# Source this file BEFORE `use nubuntu-utils/ *` to set required variables.
# Any variable already set in your environment will NOT be overwritten.

# Required: Your Launchpad username (used for PPA paths and git remotes)
# $env.LAUNCHPAD_NAME = "your-lp-username"

# Optional: Directory where packages are cloned (default: ~/pkgs)
$env.NUBUNTU_PKGS_DIR = ($env.NUBUNTU_PKGS_DIR? | default "~/pkgs")

# Optional: Path to autopkgtest.ubuntu.com session cookie (default: ~/.cache/autopkgtest.cookie)
$env.NUBUNTU_COOKIE_PATH = ($env.NUBUNTU_COOKIE_PATH? | default "~/.cache/autopkgtest.cookie")

# Optional: Quilt patches directory (default: debian/patches)
$env.QUILT_PATCHES = ($env.QUILT_PATCHES? | default "debian/patches")
