# `my` — "filtered to me" lenses on packaging data.
#
# Each subcommand reduces a global view (excuses, SRUs, PPAs, ...) to the
# slice that belongs to a Launchpad user (default $env.LAUNCHPAD_NAME,
# overridable with `-u`).

use packaging/tests/migration.nu [
    fetch-excuses,
    classify-role,
    format-role,
    format-verdict-compact,
    summarize-issues,
    build-autopkgtest-rows,
]
use packaging/sru.nu [fetch-sru-entries, build-sru-rows, print-sru-legend]
use packaging/launchpad.nu [uploader-data, lp-ppa-entries, lp-ppa-detail]
use completions.nu [release-completions]
use formatting.nu [osc8-link, with-spinner, bool-glyph, fmt-mib, fmt-relative]
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
    print ""
    print "Each subcommand accepts -u/--user to override $env.LAUNCHPAD_NAME."
    print "Run `my <subcommand> --help` for full flags."
}

# Show proposed-migration excuses for every package YOU uploaded, sponsored,
# or had sponsored. Cross-references the excuses YAML with LP publication
# history (cached) to identify your packages by `package_signer_link` /
# `package_creator_link` matching $env.LAUNCHPAD_NAME (or --user).
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

    let all_sources = (with-spinner $"Fetching excuses for ($series)..." { fetch-excuses $series })
    let sources = if $limit > 0 { $all_sources | first $limit } else { $all_sources }
    let n = ($sources | length)

    let candidates = (with-spinner $"Querying LP uploader data for ($n) sources..." {
        $sources | par-each --threads 16 {|src|
            let v = ($src | get -o new-version | default "-")
            if $v == "-" { return null }
            let ud = (uploader-data $src.source $v)
            if ($ud | is-empty) { return null }
            let role = (classify-role $ud.signer $ud.creator $me)
            if ($role | is-empty) { return null }
            $src | insert role $role | insert uploader_data $ud
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
        {
            source: $c.source
            "new-version": ($c | get -o new-version)
            role: (format-role $c.role)
            verdict: (format-verdict-compact ($c | get migration-policy-verdict))
            issues: (summarize-issues $c)
        }
    })

    print -e $"(ansi attr_bold)my excuses(ansi reset) — (ansi cyan)($candidates | length)(ansi reset) packages for (ansi cyan)($me)(ansi reset) in (ansi yellow)($series)(ansi reset)"

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
        $rows | each {|r| { "blocked-package": $c.source } | merge $r }
    } | flatten)

    $unified
}

# Pending SRUs for which you are the signer or creator.
# A user is "responsible" if they appear in `uploaders` (comma-separated list
# in the report) or match `creator`. Pass `-u` to query for someone else.
export def "my srus" [
    series?: string@release-completions  # Ubuntu series (default: latest stable)
    --all-series (-A)                    # Show across all series
    --user (-u): string = ""             # LP username (default: $env.LAUNCHPAD_NAME)
]: nothing -> table {
    let me = (resolve-user $user)
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
        ($me in $uploaders) or ($creator == $me)
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
