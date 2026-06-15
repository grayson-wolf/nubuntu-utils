# nubuntu-utils — Ubuntu packaging workflow commands for Nushell
#
# This barrel is the curated PUBLIC surface: the actual user-facing commands
# plus the deprecation shims, and nothing else. Internal helpers remain
# `export def` in their own modules so siblings (and the personal config's
# commands/) can import them directly by path, but they are deliberately NOT
# re-exported here — keeping `use nubuntu-utils *` clean. See AGENTS.md
# "Curated barrels" for the convention.
#
# Helper-only modules (completions, ubuntu-versions) are intentionally absent.
export use git.nu [withgit, lppush, dr, "dr auto", "dr continue", "dr abort"]
export use lxd.nu *
export use packaging/ *
export use p.nu
export use q.nu
export use my.nu *
export use deprecated.nu *
