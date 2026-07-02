# `my` — "filtered to me" lenses on packaging data.
#
# Each subcommand reduces a global view (excuses, SRUs, PPAs, ...) to the
# slice that belongs to a Launchpad user (default $env.LAUNCHPAD_NAME,
# overridable with `-u`).

use packaging/tests/fetch.nu [fetch-excuses]
use packaging/tests/excuses-format.nu [
    classify-role,
    format-role,
    format-verdict,
    summarize-issues,
    build-autopkgtest-rows,
]
use packaging/sru.nu [fetch-sru-entries, build-sru-rows, print-sru-legend]
use packaging/launchpad.nu [uploader-data, lp-ppa-entries, lp-ppa-detail, lp-display-name]
use packaging/sponsorships.nu [fetch-sponsorships]
use packaging/watchlist.nu [load-watchlist, save-watchlist]
use completions.nu [release-completions]
use formatting.nu [osc8-link, lp-bug-link, lp-source-link, with-spinner, bool-glyph, fmt-mib, fmt-relative, fmt-date-relative]
use ubuntu-versions.nu [DEVEL_RELEASE, LATEST_STABLE_RELEASE]

# Resolve the user: explicit `--user` wins, else $env.LAUNCHPAD_NAME.
def resolve-user [user: string]: nothing -> string {
    let me = if ($user | is-empty) { $env.LAUNCHPAD_NAME? | default "" } else { $user }
    if ($me | is-empty) {
        error make { msg: "No user — pass --user or set $env.LAUNCHPAD_NAME" }
    }
    $me
}

# Bare `my` — print subcommand help.
export def main []: nothing -> nothing {
    print "my <subcommand> — packaging views filtered to a Launchpad user."
    print ""
    print "  my excuses    Proposed-migration excuses for packages you uploaded/sponsored"
    print "  my srus       SRUs you signed or created (subset of `sru-list`)"
    print "  my ppas       PPAs you own on Launchpad"
    print "  my sponsorships  Sponsored uploads where you are the sponsoree (-g: sponsor)"
    print "  my watchlist  Manage the personal package watchlist"
    print ""
    print "Each subcommand accepts -u/--user to override $env.LAUNCHPAD_NAME."
    print "Watchlist packages are always included in `my excuses` and `my srus`"
    print "unless --user is explicitly passed."
    print "Run `my <subcommand> --help` for full flags."
}

# Show proposed-migration excuses for every package YOU uploaded, sponsored,
# or had sponsored, plus any packages on your watchlist. Cross-references the
# excuses YAML with LP publication history (cached) to identify your packages
# by `package_signer_link` / `package_creator_link` matching
# $env.LAUNCHPAD_NAME (or --user). Watchlist packages are included with role
# "watched" without an LP lookup; watchlist is ignored when --user is given.
#
# Default output: summary table (source, version, role, verdict, issues).
# --detailed: also render the full per-package excuses output for each match.
# --raw: structured records with `role` and `uploader_data` columns added.
export def "my excuses" [
    --series (-s): string@release-completions = $DEVEL_RELEASE  # Ubuntu series
    --user (-u): string = ""                # LP username (default: $env.LAUNCHPAD_NAME)
    --detailed (-D)                         # Also render full per-package excuses output
    --why (-w)                              # Refine REGRESSION cells with log-derived failure mode (only with --detailed)
    --failing (-f)                          # Only rows with a real test regression (implies -D and -w)
    --limit (-n): int = 0                   # Cap on excuses sources to query (0 = all). Useful for testing.
    --raw (-r)                              # Return structured records
]: nothing -> any {
    let detailed = ($detailed or $failing)
    let why = ($why or $failing)
    let me = (resolve-user $user)

    # Watchlist only applies when using the default identity.
    let watchlist = if ($user | is-empty) { load-watchlist } else { [] }

    # Syncs have creator as the Debian uploader and no signer, so they aren't caught
    # fall back to the sponsorship miner
    let sponsored_pairs = (with-spinner $"Fetching sponsorships for ($me)..." {
        let rows = (fetch-sponsorships (lp-display-name $me))
        if ($rows | is-empty) { [] } else { $rows | select package version }
    })

    let excuses = with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series }

    let date = $excuses | get generated-date
    let all_sources = $excuses | get sources
    let sources = if $limit > 0 { $all_sources | first $limit } else { $all_sources }
    let n = ($sources | length)

    let candidates = (with-spinner $"Querying LP uploader data for ($n) sources..." {
        $sources | par-each --threads 16 {|src|
            if ($src.source in $watchlist) {
                return ($src | insert role "watched" | insert uploader_data {})
            }
            let v = ($src | get -o new-version | default "-")
            if $v == "-" { return null }
            let ud = (uploader-data $src.source $v)
            # Publication-based classification first (signer/creator).
            let pub_role = if ($ud | is-empty) { null } else {
                classify-role $ud.signer $ud.creator $me
            }
            # Fall back to the sponsorship miner — catches sponsored syncs the
            # publication record can't attribute to the user.
            let is_sponsored = ($sponsored_pairs | any {|s| $s.package == $src.source and $s.version == $v })
            let role = if ($pub_role | is-not-empty) {
                $pub_role
            } else if $is_sponsored {
                "sponsored-by"
            } else {
                null
            }
            if ($role | is-empty) { return null }
            $src | insert role $role | insert uploader_data ($ud | default {})
        } | where { $in != null }
    })

    if ($candidates | is-empty) {
        print -e $"(ansi yellow)No matching packages for ($me) in ($series).(ansi reset)"
        return
    }

    if $raw {
        return $candidates
    }

    let summary = ($candidates | each {|c|
        let v = ($c | get -o new-version)
        {
            source: (lp-source-link $c.source)
            "new-version": (lp-source-link $c.source --version $v)
            role: (format-role $c.role)
            verdict: (format-verdict ($c | get migration-policy-verdict) --compact)
            issues: (summarize-issues $c)
        }
    })

    print -e $"(ansi attr_bold)my excuses(ansi reset) — (ansi cyan)($candidates | length)(ansi reset) packages for (ansi cyan)($me)(ansi reset) in (ansi yellow)($series)(ansi reset) - as of (ansi cyan)(fmt-date-relative $date)(ansi reset)"

    if not $detailed {
        return $summary
    }

    print -e ($summary | table --expand)
    print -e ""

    let global_arches = ($candidates | each {|c|
        let at = ($c | get -o policy_info.autopkgtest | default {})
        if ($at | is-empty) { [] } else {
            $at | reject -o verdict | values | each { columns } | flatten | uniq
        }
    } | flatten | uniq | sort)

    let unified = ($candidates | each {|c|
        let at = ($c | get -o policy_info.autopkgtest | default {})
        let rows = (build-autopkgtest-rows $at false $why $global_arches $failing)
        $rows | each {|r| { "blocked-package": (lp-source-link $c.source) } | merge $r }
    } | flatten)

    $unified
}

# Pending SRUs for which you are the signer or creator, plus any packages on
# your watchlist. A user is "responsible" if they appear in `uploaders`
# (comma-separated list in the report) or match `creator`. Pass `-u` to query
# for someone else; watchlist is ignored when --user is given.
export def "my srus" [
    series?: string@release-completions  # Ubuntu series (default: latest stable)
    --all-series (-A)                    # Show across all series
    --user (-u): string = ""             # LP username (default: $env.LAUNCHPAD_NAME)
]: nothing -> table {
    let me = (resolve-user $user)

    # Watchlist only applies when using the default identity.
    let watchlist = if ($user | is-empty) { load-watchlist } else { [] }

    let s = ($series | default $LATEST_STABLE_RELEASE)
    let entries = (fetch-sru-entries $s $all_series)
    let mine = ($entries | where {|e|
        let uploaders = (
            ($e | get -o uploaders | default "")
            | split row ","
            | each { str trim }
            | where { $in | is-not-empty }
        )
        let creator = ($e | get -o creator | default "")
        ($me in $uploaders) or ($creator == $me) or ($e.pkg in $watchlist)
    })
    if ($mine | is-empty) {
        let scope = if $all_series { "any series" } else { $s }
        print -e $"(ansi yellow)No SRUs for ($me) in ($scope).(ansi reset)"
        return []
    }
    let rows = (build-sru-rows $mine $all_series)
    print -e $"(ansi attr_bold)my srus(ansi reset) — (ansi cyan)($rows | length)(ansi reset) SRUs for (ansi cyan)($me)(ansi reset)"
    print-sru-legend $s
    $rows
}

# Manage the personal package watchlist.
# Packages on the watchlist are included in `my excuses` and `my srus`
# regardless of uploader (unless --user is passed to those commands).
#
# Bare `my watchlist` lists the current watchlist.
export def "my watchlist" []: nothing -> list<string> {
    let wl = load-watchlist
    if ($wl | is-empty) {
        print -e $"(ansi yellow)Watchlist is empty. Use `my watchlist add <pkg>` to add packages.(ansi reset)"
    }
    $wl
}

# Add one or more source packages to the watchlist.
export def "my watchlist add" [
    ...packages: string  # Source package name(s) to add
]: nothing -> nothing {
    if ($packages | is-empty) {
        error make { msg: "Provide at least one package name." }
    }
    let wl = load-watchlist
    let added = ($packages | where { $in not-in $wl })
    if ($added | is-empty) {
        print -e $"(ansi yellow)All packages already on watchlist.(ansi reset)"
        return
    }
    save-watchlist ($wl | append $added)
    print -e $"(ansi green)Added:(ansi reset) ($added | str join ', ')"
}

# Remove one or more source packages from the watchlist.
export def "my watchlist rm" [
    ...packages: string  # Source package name(s) to remove
]: nothing -> nothing {
    if ($packages | is-empty) {
        error make { msg: "Provide at least one package name." }
    }
    let wl = load-watchlist
    let remaining = ($wl | where { $in not-in $packages })
    let removed = ($wl | where { $in in $packages })
    if ($removed | is-empty) {
        print -e $"(ansi yellow)None of those packages were on the watchlist.(ansi reset)"
        return
    }
    save-watchlist $remaining
    print -e $"(ansi red)Removed:(ansi reset) ($removed | str join ', ')"
}

# Walk the Launchpad pagination chain for a person's `ppas` collection.
# (Pagination + caching live in `packaging/launchpad.nu` so the same data
# powers both `my ppas` and `ppa-completions` without circular imports.)

# Free-field projection of a raw LP archive entry into a display row.
def ppa-project [e: record]: nothing -> record {
    let name = ($e | get -o name | default "")
    let web = ($e | get -o web_link | default "")
    {
        name: (osc8-link $web $name)
        displayname: ($e | get -o displayname | default "")
        pub: (bool-glyph ($e | get -o publish | default false))
        priv: (bool-glyph ($e | get -o private | default false))
        quota: (fmt-mib ($e | get -o authorized_size | default 0))
    }
}

# Builds glyph string for a detail record.
def builds-summary [d: record]: nothing -> string {
    let f = ($d | get -o builds_failed | default 0)
    let p = ($d | get -o builds_pending | default 0)
    let s = ($d | get -o builds_succeeded | default 0)
    let parts = [
        (if $f > 0 { $"(ansi red)($f)✗(ansi reset)" } else { null })
        (if $p > 0 { $"(ansi yellow)($p)…(ansi reset)" } else { null })
        (if $s > 0 { $"(ansi green)($s)✓(ansi reset)" } else { null })
    ] | where { $in != null }
    if ($parts | is-empty) { "—" } else { $parts | str join " " }
}

# List PPAs owned by you (or `-u <user>`) on Launchpad.
# Default columns: name, displayname, pub, priv, quota.
# `--details (-d)` enriches each row with sources, last_upload, series,
# and a build summary (one extra HTTP round per PPA, cached 5min).
# `--raw (-r)` returns the full LP entry records.
export def "my ppas" [
    --user (-u): string = ""  # LP username (default: $env.LAUNCHPAD_NAME)
    --raw (-r)                # Return the raw LP entry records
    --details (-d)            # Add sources/last_upload/series/builds (slow first call)
]: nothing -> any {
    let me = (resolve-user $user)
    let entries = (with-spinner $"Fetching PPAs for ($me)..." { lp-ppa-entries $me })
    if ($entries | is-empty) {
        print -e $"(ansi yellow)No PPAs for ($me).(ansi reset)"
        return []
    }
    if $raw { return $entries }
    let suffix = if $details { " (with details)" } else { "" }
    print -e $"(ansi attr_bold)my ppas(ansi reset) — (ansi cyan)($entries | length)(ansi reset) PPAs for (ansi cyan)($me)(ansi reset)($suffix)"
    let base = ($entries | each {|e| ppa-project $e })
    if not $details { return $base }
    let details_list = (with-spinner $"Fetching details for ($entries | length) PPAs..." {
        $entries | par-each --keep-order {|e| lp-ppa-detail $me ($e | get -o name | default "") }
    })
    $base | zip $details_list | each {|pair|
        let row = $pair.0
        let d = $pair.1
        $row | merge {
            sources: ($d | get -o sources | default 0)
            last_upload: (fmt-relative ($d | get -o last_upload | default ""))
            series: (($d | get -o series | default []) | str join ",")
            builds: (builds-summary $d)
        }
    }
}

# Sponsored uploads recorded by the UDD Ubuntu Sponsorship Miner.
# Default: uploads sponsored FOR you (you are the sponsoree).
# --given (-g): uploads YOU sponsored for others (you are the sponsor).
#
# The miner matches on real names, not LP usernames, so the resolved user
# ($env.LAUNCHPAD_NAME or --user) is mapped to its LP `display_name` before
# querying.
#
# Default columns: date, the other party (sponsor, or sponsoree with -g),
# package (LP link), version, series, bugs. The `action` column is shown only
# when at least one row has one. --raw returns the full parsed records.
export def "my sponsorships" [
    --user (-u): string = ""  # LP username (default: $env.LAUNCHPAD_NAME)
    --given (-g)              # Uploads you sponsored for others (default: for you)
    --raw (-r)                # Return the full parsed records
]: nothing -> any {
    let me = (resolve-user $user)
    let name = (lp-display-name $me)
    let dir = if $given { "sponsored by" } else { "sponsored for" }
    let rows = (with-spinner $"Fetching uploads ($dir) ($name)..." {
        fetch-sponsorships $name --given=$given
    })
    if ($rows | is-empty) {
        print -e $"(ansi yellow)No uploads ($dir) ($name).(ansi reset)"
        return []
    }
    if $raw { return $rows }

    let party_col = if $given { "sponsoree" } else { "sponsor" }
    let show_action = ($rows | any {|r| ($r.action | str trim) | is-not-empty })

    print -e $"(ansi attr_bold)my sponsorships(ansi reset) — (ansi cyan)($rows | length)(ansi reset) uploads ($dir) (ansi cyan)($name)(ansi reset)"

    $rows | each {|r|
        let base = {
            date: $r.date
            $party_col: ($r | get $party_col)
            package: (lp-source-link $r.package)
            version: (lp-source-link $r.package --version $r.version)
            series: $r.series
            bugs: ($r.bugs | each {|b| lp-bug-link $b } | str join " ")
        }
        if $show_action { $base | insert action $r.action } else { $base }
    }
}
