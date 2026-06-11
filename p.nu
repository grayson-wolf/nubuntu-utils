# PPA workflow subcommands — all PPA lifecycle operations under `p`.

use packaging/meta.nu [pkg-name, pkg-top-release, pkg-version, target-release]
use packaging/build.nu [cpbd, tarme, gen-ppa-name, test-urls]
use packaging/tests/ [autopkgtest-cookie, autopkgtest-cookie-path, submit-autopkgtest, select-and-submit, ppa-test-urls, fetch-ppa-test-runs, fetch-ppa-running, fetch-ppa-waiting, render-tests-tables]
use completions.nu [ppa-completions]
use packaging/launchpad.nu [normalize-ppa-name]
use ubuntu-versions.nu [DEVEL_RELEASE]
use formatting.nu [with-spinner]
use my.nu ["my ppas"]

# PPA workflow commands. Run bare `p` to see available subcommands.
export def main []: nothing -> nothing {
    print "PPA workflow commands. Available subcommands:\n"
    print "  p build    — Clean, fetch orig, build source, upload to fresh PPA"
    print "  p up       — Create PPA, dput, wait, autotest, notify, show status"
    print "  p list     — List PPAs you own on Launchpad (alias of `my ppas`)"
    print "  p reap     — Destroy all PPAs matching a package substring"
    print "  p destroy  — Destroy a single PPA by name"
    print "  p test     — Submit autopkgtest requests (local or named PPA)"
    print "  p tests    — Show autopkgtest results (local or named PPA)"
    print "  p name     — Print the generated PPA name"
    print "  p sync     — Test a Debian sync via PPA build"
    print $"\nRun `p <subcommand> --help` for details."
}

# List PPAs you own on Launchpad. Thin wrapper over `my ppas` so the PPA
# lifecycle commands share a discovery surface.
export def list [
    --user (-u): string = ""  # LP username (default: $env.LAUNCHPAD_NAME)
    --raw (-r)                # Return the raw LP entry records
]: nothing -> any {
    my ppas --user $user --raw=$raw
}

# Print the deterministic PPA name generated from the current package, release, and .changes hash.
export def name []: nothing -> string {
    gen-ppa-name
}

# Clean, fetch orig tarball, build source package, and upload to a freshly created PPA.
export def --wrapped build [
    --proposed (-p) # Use the proposed pocket
    --security (-s) # Use the security pocket
    --backports (-b) # Use the backports pocket
    --no-deps (-d) # Skip build dependency checks (passes -d to debuild)
    ...debuild_flags: string # Extra flags to pass to debuild
]: nothing -> nothing {
    cpbd
    tarme

    let d_flag = if $no_deps { [-d] } else { [] }
    debuild -S -sa ...$d_flag ...$debuild_flags

    up (gen-ppa-name) --proposed=$proposed --security=$security --backports=$backports
}

# Create a named PPA, dput the .changes, wait for build, auto-submit autopkgtests, notify, and show test status.
export def up [
    ppa_name: string # The name of the PPA to create and upload to
    --proposed (-p) # Use the proposed pocket
    --security (-s) # Use the security pocket
    --backports (-b) # Use the backports pocket
]: nothing -> nothing {
    let ppa_path = (normalize-ppa-name $ppa_name)
    let pocket_args = if $proposed { [--pocket proposed]
        } else if $security { [--pocket security]
        } else if $backports { [--pocket backports]
        } else { [] }
    ppa create $ppa_name ...$pocket_args
    dput $"ppa:($ppa_path)" ../*.changes
    ppa wait $ppa_path

    # Auto-submit autopkgtest requests via cookie
    let cookie = autopkgtest-cookie-path
    let notify_text = if ($cookie | path exists) {
        let urls = (test-urls)
        let results = ($urls | par-each {|entry|
            submit-autopkgtest $entry.url $cookie
        })
        let all_ok = ($results | all { $in == "200" })
        if $all_ok {
            $"The upload to PPA ($ppa_path) is done building and tests have been requested."
        } else {
            $"The upload to PPA ($ppa_path) is done building. Some test requests failed — check terminal output."
        }
    } else {
        $"The upload to PPA ($ppa_path) is done building. No autopkgtest cookie found — tests not auto-submitted."
    }

    (
      zenity --warning --title "PPA Build Complete"
      --text $notify_text
      --icon "dialog-info"
    )
    tests $ppa_path
}

# Destroy every PPA whose name contains the given package substring (or the current package if omitted).
export def reap [
    name?: string # The package substring to match (defaults to current package)
]: nothing -> list<string> {
    let pkg = $name | default (pkg-name)

    ppa list | lines | where {|x| $x =~ $pkg } | each {|entry|
        ppa destroy $entry | ignore
        $entry
    }
}

# Destroy a single PPA by name, auto-prefixing your Launchpad username if needed.
export def destroy [
    ppa_name: string@ppa-completions # PPA name (e.g., "rsync-noble-abc123" or "graysonwolf/rsync-noble-abc123")
]: nothing -> nothing {
    ppa destroy (normalize-ppa-name $ppa_name)
}

# Submit autopkgtest trigger requests for a PPA.
# Without --ppa, derives URLs from the current package directory.
# With --ppa, fetches URLs from any named PPA and offers interactive selection.
export def test [
    --proposed (-p)                          # Submit only the all-proposed variants
    --ppa: string@ppa-completions            # Named PPA to test (skips local derivation)
    --no-select                              # Skip interactive selection, submit all
]: nothing -> nothing {
    let cookie = autopkgtest-cookie

    if ($ppa | is-not-empty) {
        let ppa_name = normalize-ppa-name $ppa
        let urls = if $proposed {
            ppa-test-urls $ppa_name --proposed | where { $in =~ "all-proposed" }
        } else {
            ppa-test-urls $ppa_name
        }

        if ($urls | is-empty) {
            print $"No test URLs found for PPA ($ppa_name)."
            return
        }

        select-and-submit $urls $cookie --no-select=$no_select --header $"Select tests for PPA ($ppa_name):"
    } else {
        let urls = if $proposed { test-urls --proposed | where proposed == true } else { test-urls }

        if ($urls | is-empty) {
            print "No test URLs generated."
            return
        }

        let header = if $proposed { "Select proposed tests to submit:" } else { "Select tests to submit:" }
        select-and-submit ($urls | get url) $cookie --no-select=$no_select --header $header
    }
}

# Display autopkgtest result summaries and retrigger URLs for a named PPA.
# If no PPA name is given, derives it from the current package directory (like `p name`).
# Columns: arch, kind (base/proposed), time, then one column per subtest.
# Default returns the display table (pipeline-filterable on arch / kind / time).
# Use --raw for structured records (with `subtests` list column).
# Use --history to show all recent runs (not just the latest per arch).
# Currently running and queued jobs are shown alongside finished runs (one
# row per arch with overall=Running/Queued); use --no-pending to skip the
# extra running.json/queues.json fetches.
export def tests [
    ppa_name?: string@ppa-completions   # PPA name (auto-detected if omitted)
    --series (-s): string = ""              # Ubuntu series (default: cwd target if PPA auto-derived, else devel)
    --arches (-a): list<string> = []        # Architectures (default: all available)
    --history (-H)                          # Show all recent runs (not just the latest per arch)
    --limit (-l): int = 10                  # Max runs per arch in history mode
    --raw (-r)                              # Return structured records with full subtest data
    --no-pending (-N)                       # Skip running/queued lookups
]: nothing -> any {
    let resolved = if ($ppa_name | is-empty) {
        normalize-ppa-name (gen-ppa-name)
    } else {
        normalize-ppa-name $ppa_name
    }
    let split = ($resolved | split row "/")
    if ($split | length) < 2 {
        error make { msg: $"Could not parse PPA name '($resolved)' into owner/name" }
    }
    let owner = ($split | get 0)
    let ppa = ($split | get 1)

    let series_resolved = if ($series | is-empty) {
        if ($ppa_name | is-empty) { (target-release) } else { $DEVEL_RELEASE }
    } else { $series }

    let max_per_arch = if $history { $limit } else { 4 }
    # Running/queued runs are appended with kind="running"/"queued" so the
    # render-tests-tables (source, arch, kind) dedup keeps them as separate
    # rows rather than overwriting prior finished runs.
    let runs = with-spinner $"Fetching tests for ($owner)/($ppa) in ($series_resolved)..." {
        let finished = (fetch-ppa-test-runs $series_resolved $owner $ppa $max_per_arch $arches)
        let pending = if $no_pending {
            []
        } else {
            let running = (fetch-ppa-running $series_resolved $owner $ppa $arches | each {|r| $r | update kind "running" })
            let waiting = (fetch-ppa-waiting $series_resolved $owner $ppa $arches | each {|r| $r | update kind "queued" })
            $running ++ $waiting
        }
        $finished ++ $pending
    }
    if ($runs | is-empty) {
        print -e $"(ansi yellow)No test results found for ($owner)/($ppa) in ($series_resolved).(ansi reset)"
        return
    }

    if $raw {
        let prepared = if $history {
            $runs | sort-by time --reverse
        } else {
            $runs
            | sort-by time --reverse
            | group-by --to-table { |r| $"($r.source)|($r.arch)|($r.kind)" }
            | each {|g| $g.items | first }
        }
        return $prepared
    }

    $runs | render-tests-tables {|pkg|
        $"(ansi cyan)($pkg)(ansi reset) in (ansi yellow)($series_resolved)(ansi reset) — ($owner)/($ppa)"
    } (not $history)
}

# Branch from pkg/debian/sid, bump changelog for PPA requirements, and run `p build` to test a Debian sync.
export def sync [
    --release (-r): string = $DEVEL_RELEASE # Target Ubuntu release name
]: nothing -> nothing {
    git checkout pkg/debian/sid
    git checkout -b $"test-sync-($release)"

    # Bump version with ~ppa1 suffix and retarget to Ubuntu release
    dch --local ~ppa --distribution $release "no change changelog update for PPA build"
    update-maintainer

    git add -A
    git commit -m "changes for test ppa build"

    build -d
}
