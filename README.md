# nubuntu-utils

Ubuntu packaging workflow commands powered by [Nushell](https://www.nushell.sh/).
Works from any shell (bash, zsh, fish) via snap, with full native pipeline support for Nushell users.

## Installation

### Install dependencies

```bash
# APT packages
sudo apt install devscripts ubuntu-dev-tools dput-ng quilt autopkgtest git gh libnotify-bin

# Snaps
sudo snap install ppa-dev-tools --edge
sudo snap install git-ubuntu --edge --classic
sudo snap install lxd --channel=latest/candidate
```

### Install the snap

```bash
sudo snap install nubuntu-utils --classic
```

### Set up command aliases (non-Nushell users)

By default, commands are namespaced (e.g. `nubuntu-utils.excuses`). To use short names like `excuses`, `p`, `pkg`, etc., run the interactive alias manager:

```bash
nubuntu-utils.aliases
```

This lets you pick which commands to expose as short aliases (requires sudo).

### Configure environment

Add to your `~/.bashrc` (or equivalent):

```bash
export LAUNCHPAD_NAME="your-lp-username"
export DEBFULLNAME="Your Name"
export DEBEMAIL="you@example.com"
export DEBSIGN_KEYID="YOUR_GPG_KEY_ID"
```

### (Nushell users) Source the commands directly

Instead of using the snap wrappers, source the modules natively for full pipeline support:

```nu
# In your config.nu:
source /snap/nubuntu-utils/current/nubuntu-utils/env.nu
use /snap/nubuntu-utils/current/nubuntu-utils/ *
```

This gives you structured table output, filtering, and all Nushell features:

```nu
excuses libsdl3 | where package =~ "freerdp"
```

## Required Environment Variables

| Variable | Description | Example |
|---|---|---|
| `LAUNCHPAD_NAME` | Your Launchpad username (used for PPA paths and git remotes) | `your-lp-username` |
| `DEBFULLNAME` | Your full name for debian/changelog entries | `Your Name` |
| `DEBEMAIL` | Your email for debian/changelog entries | `you@example.com` |
| `DEBSIGN_KEYID` | GPG key ID for signing packages | `YOUR_GPG_KEY_ID` |
| `SALSA_TOKEN` | Salsa (Debian GitLab) personal access token for `salsa` fork creation (scope: `api`) | `salsa-token` |

## Optional Environment Variables

| Variable | Default | Description |
|---|---|---|
| `NUBUNTU_PKGS_DIR` | `~/pkgs` | Directory where packages are cloned |
| `NUBUNTU_CACHE_DIR` | `~/.cache/nubuntu-utils` | Cache directory (cookie, team mapping, etc.) |
| `NUBUNTU_STATE_DIR` | `~/.local/state/nubuntu-utils` | Persistent state directory |
| `QUILT_PATCHES` | `debian/patches` | Quilt patches directory |
| `EDITOR` | — | Editor used by `qedit` and other interactive commands |

## Commands

### PPA Lifecycle (`p` subcommands)

| Command | Description |
|---|---|
| `p` | Show available PPA subcommands |
| `p build` | Clean, fetch orig tarball, build source package, and upload to a fresh PPA |
| `p up` | Create PPA, dput, wait for build, auto-submit tests, notify, show status |
| `p reap` | Destroy all PPAs whose name matches a package substring |
| `p destroy` | Destroy a single PPA by name |
| `p test` | Submit autopkgtest trigger requests for a PPA (local or named) |
| `p tests` | Display autopkgtest result summaries for a named PPA |
| `p name` | Print the deterministic PPA name for the current package |
| `p sync` | Branch from debian/sid and test a sync via PPA build |

### Package Workspace

| Command | Description |
|---|---|
| `pkg` | Clone a package (or cd into it if already cloned) |
| `salsa` | Clone a Debian salsa fork (auto-discovers upstream, forks if needed, clones into `<pkg>/salsa/`) |
| `dch-bump` | Bump changelog version and commit with update-maintainer |
| `poc` | Check which team(s) own a package |
| `revdeps` | List reverse dependencies of a package |

### Building

| Command | Description |
|---|---|
| `cpbd` | Clear parent build directory of old artifacts |
| `tarme` | Fetch the orig tarball for the current package |
| `getdeps` | Install build dependencies via mk-build-deps |
| `test-urls` | Generate autopkgtest request URLs for the current PPA upload |
| `buildin` | Build binary packages in a clean LXD container |

### Testing & Migration

| Command | Description |
|---|---|
| `excuses` | Show proposed-migration status with a colorized autopkgtest table |
| `excuses-clusters` | Show the largest co-migration transition clusters blocking proposed |
| `archive-tests` | Show autopkgtest results for an archive package (single-series table or cross-series matrix) |
| `retry-regressions` | Retry autopkgtest regressions blocking (or blocked by) a package |
| `migration-reference` | Submit `migration-reference/0` autopkgtests for a package |
| `sru-list` | Show pending SRUs for a series with colored/clickable bug status |
| `merges` | Show outstanding archive merges (merge-o-matic) as a table; omit the component for a combined board. |
| `testin` | Run autopkgtests in a local LXD container |
| `testurl` | Display clickable autopkgtest request URLs for the current package |

### Personal lenses (`my` subcommands)

`my <thing>` filters a global packaging view to a Launchpad user
(default `$env.LAUNCHPAD_NAME`, overridable per-subcommand with `-u`).
Packages on your watchlist are included in `my excuses` and `my srus`
as if you owned them; the watchlist is ignored when `--user` is given.

| Command | Description |
|---|---|
| `my` | Show available `my` subcommands |
| `my excuses` | Proposed-migration excuses for packages you uploaded/sponsored/watched |
| `my srus` | SRUs you signed, created, or watched (filtered `sru-list`) |
| `my ppas` | PPAs you own on Launchpad (pass `-d` for sources/uploads/builds) |
| `my sponsorships` | Sponsored uploads where you're the sponsoree (`-g` for ones you sponsored) |
| `my watchlist` | List the personal package watchlist |
| `my watchlist add` | Add source packages to the watchlist |
| `my watchlist rm` | Remove source packages from the watchlist |

### Patches (`q` subcommands)

| Command | Description |
|---|---|
| `q` | Show available quilt subcommands |
| `q push` | Apply all patches (with --fuzz=0) |
| `q pop` | Unapply all patches |
| `q ref` | Refresh current patch with git-style headers |
| `q add` | Register a file for the current patch |
| `q header` | Edit DEP-3 patch header interactively |
| `q series` | Show the patch series |
| `q top` | Show the topmost applied patch |
| `q new` | Create a new auto-numbered quilt patch |
| `q edit` | Register file, open in editor, refresh (add→edit→refresh cycle) |
| `q shunt` | Transplant a patch from another branch into this series (auto-numbered, fuzz-0 apply check; `--file` for a loose patch) |
| `q diff` | Generate an upstream-ready patch diff from the packaging branch |

### Dependency Analysis

| Command | Description |
|---|---|
| `dep-components` | Show which archive components a package's dependencies live in |

### Git / Launchpad

| Command | Description |
|---|---|
| `dr` | Show available deltarebase subcommands |
| `dr auto` | Start (or restart) a `git ubuntu deltarebase auto` |
| `dr continue` | Continue a paused deltarebase |
| `dr abort` | Abort an in-progress deltarebase |
| `lppush` | Push to your Launchpad fork (`lppush -f` for force — uses `--force-with-lease`; `lppush -m` also pushes merge tags). |
| `withgit` | Run an external command with `GITHUB_TOKEN` exposed |
| `withgit-do` | Run a nushell closure with `GITHUB_TOKEN` exposed |

### LXD Containers

| Command | Description |
|---|---|
| `spawn` | Launch an LXD container/VM and enter a shell |
| `ephemeral` | Spawn a temporary container/VM that self-destructs on exit |
| `lxc-reap` | Stop and delete a single container |
| `lxc-reap-all` | Reap all orphaned ephemeral containers |
| `images` | List images from a given LXD remote as a table; optionally filter by alias (e.g., `images ubuntu-daily: resolute`) |
