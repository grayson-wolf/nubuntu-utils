# Module index for packaging commands — curated PUBLIC API only.
#
# Re-exports just the user-facing commands. Helper-only modules (watchlist,
# cache, meta, launchpad) and the non-command helpers in build.nu are imported
# directly by their consumers, not surfaced into the user namespace. The tests
# barrel is itself curated, so re-export it wholesale.

export use build.nu [cpbd, tarme, getdeps, test-urls, testurl]
export use changelog.nu [dch-bump]
export use navigation.nu [pkg, poc]
export use salsa.nu
export use deps.nu [dep-components, revdeps]
export use sru.nu [sru-list]
export use merges.nu
export use tests/ *
