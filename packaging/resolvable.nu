# Build-dependency resolvability analysis against the archive pockets.

use ../ubuntu-versions.nu [DEVEL_RELEASE]
use ../formatting.nu [with-spinner, lp-source-link]
use ../completions.nu [pkg-completions]
use deb822.nu [fetch-index, parse-bin-stanza, parse-src-stanza, stanza-raw, files-contain, provider-of, version-satisfies]

const COMPONENTS = [main universe]


# ---- pocket view ------------------------------------------------------------

# A lazily-resolving view over the two pockets. Each field is the LIST of cached
# index file paths for that pocket (one per component)
def pocket-view [series: string]: nothing -> record {
    {
        series: $series
        bin_rel: ($COMPONENTS | each {|c| fetch-index $series "release" $c "Packages" })
        bin_prop: ($COMPONENTS | each {|c| fetch-index $series "proposed" $c "Packages" })
        src_rel: ($COMPONENTS | each {|c| fetch-index $series "release" $c "Sources" })
        src_prop: ($COMPONENTS | each {|c| fetch-index $series "proposed" $c "Sources" })
    }
}

# Newest binary stanza across both pockets (proposed wins when present).
def binary-best [view: record, name: string]: nothing -> record {
    let prop = (stanza-raw $view.bin_prop $name)
    if ($prop | is-not-empty) { return (parse-bin-stanza $prop) }
    let rel = (stanza-raw $view.bin_rel $name)
    if ($rel | is-not-empty) { return (parse-bin-stanza $rel) }
    {}
}

# Source package that provides a binary. Returns the name unchanged if unknown.
def dep-source [view: record, name: string]: nothing -> string {
    let b = (binary-best $view $name)
    if ($b | is-empty) { return $name }
    if ($b.source | is-empty) { $name } else { $b.source }
}

def binary-exists [view: record, name: string]: nothing -> bool {
    (stanza-raw $view.bin_prop $name | is-not-empty) or (stanza-raw $view.bin_rel $name | is-not-empty)
}

# Best source stanza (proposed wins) for a source package name.
def source-best [view: record, src: string]: nothing -> record {
    let prop = (stanza-raw $view.src_prop $src)
    if ($prop | is-not-empty) { return (parse-src-stanza $prop) }
    let rel = (stanza-raw $view.src_rel $src)
    if ($rel | is-not-empty) { return (parse-src-stanza $rel) }
    {}
}

# Does a source package have an entry in -proposed?
def source-in-proposed [view: record, src: string]: nothing -> bool {
    stanza-raw $view.src_prop $src | is-not-empty
}

# ---- classification ---------------------------------------------------------
# memoize here because nu records are immutable and we can't capture a `mut` inside an `each` closure.

# Memoized binary-best: returns {best, memo}
def binary-best-memo [view: record, name: string, memo: record]: nothing -> record {
    let hit = ($memo | get -o $name)
    if $hit != null { return { best: $hit, memo: $memo } }
    let best = (binary-best $view $name)
    { best: $best, memo: ($memo | upsert $name $best) }
}

# Memoized relation check.
# A relation atom is BROKEN when, resolving every package newest-first (release + -proposed), nothing satisfies it anymore:
def relation-ok-memo [view: record, rel: string, memo: record]: nothing -> record {
    let m = ($rel | parse -r '^(?<name>\S+)(?:\s*\((?<op><<|<=|=|>=|>>)\s*(?<ver>[^)]+)\))?$')
    if ($m | is-empty) { return { ok: true, memo: $memo } }
    let name = ($m | get 0.name)

    if (binary-exists $view $name) {
        # This is a real binary package
        let ver = ($m | get 0.ver? | default "")
        if ($ver | is-empty) { return { ok: true, memo: $memo } }   # unversioned: any version

        # Versioned: only broken if the BEST version comes from proposed and
        # violates the constraint (a release-pocket relation would already hold).
        let prop_raw = (stanza-raw $view.bin_prop $name)
        if ($prop_raw | is-empty) { return { ok: true, memo: $memo } }
        let r = (binary-best-memo $view $name $memo)
        return { ok: (version-satisfies $r.best.version ($m | get 0.op? | default "") $ver), memo: $r.memo }
    }

    # Virtual atom provided by some real package's Provides.
    # It breaks when the providing package is bumped in -proposed to a version whose stanza no longer Provides
    # this exact atom (the release binary that did provide it is then superseded in apt's newest-first resolution).

    # check if the package never existed in release, if it didn't we don't care
    let rel_has = (files-contain $view.bin_rel $rel)
    if not $rel_has { return { ok: true, memo: $memo } }

    # check if a proposed provider still has it, if it does, things are fine
    let prop_has = (files-contain $view.bin_prop $rel)
    if $prop_has { return { ok: true, memo: $memo } }

    # in release but not proposed, so check if the provider is still in proposed.
    # If not, this isn't our signal, it's just a virtual that was dropped entirely.
    let provider = (provider-of $view.bin_rel $rel)
    if ($provider | is-empty) { return { ok: true, memo: $memo } }

    let bumped = ((stanza-raw $view.bin_prop $provider) | is-not-empty)
    { ok: (not $bumped), memo: $memo }
}

# Classify one build-dep, threading the stanza memo. Returns {row, memo}.
def classify-dep-memo [view: record, name: string, memo: record]: nothing -> record {
    if not (binary-exists $view $name) {
        return { row: { name: $name, status: "missing", version: "", source: $name, broken: [] }, memo: $memo }
    }
    let r0 = (binary-best-memo $view $name $memo)
    let best = $r0.best
    mut memo = $r0.memo
    let src = (if ($best.source | is-empty) { $name } else { $best.source })
    mut broken = []
    for rel in $best.depends {
        let rr = (relation-ok-memo $view $rel $memo)
        $memo = $rr.memo
        if not $rr.ok {
            $broken = ($broken | append ($rel | str replace -r '\s*\(.*\)$' ''))
        }
    }
    let status = if ($broken | is-empty) { "fine"
        } else if (source-in-proposed $view $src) { "retrigger"
        } else { "ncr" }
    { row: { name: $name, status: $status, version: $best.version, source: $src, broken: $broken }, memo: $memo }
}

# The build-deps of a source package (best source stanza), names only.
def source-build-deps [view: record, src: string]: nothing -> list<string> {
    let best = (source-best $view $src)
    if ($best | is-empty) { return [] }
    $best.build_deps | where { $in =~ '^lib' or ($in | str ends-with "-dev") } | uniq
}

# Own binaries of a source package — excluded from its build-dep walk.
def own-binaries [view: record, src: string]: nothing -> list<string> {
    let best = (source-best $view $src)
    if ($best | is-empty) { return [] }
    $best.binaries
}

# ---- topological levels -----------------------------------------------------

# topologically sort the rebuild/ncr chain to get a stratified view of what needs action when
def assign-levels [view: record, rows: list, memo: record]: nothing -> list {
    let actionable = ($rows | where status in ["ncr", "retrigger"])
    if ($actionable | is-empty) { return ($rows | each {|r| $r | upsert level 0 | upsert build_blockers [] }) }
    let sources = ($actionable | get source | uniq)

    # edges: source -> set of actionable sources it build-depends on
    # (thread the stanza memo so resolved binaries aren't re-scanned).
    mut edges = {}
    mut memo = $memo
    for s in $sources {
        let deps = (source-build-deps $view $s)
        mut dep_srcs = []
        for d in $deps {
            let r = (binary-best-memo $view $d $memo)
            $memo = $r.memo
            let b = $r.best
            let dsrc = (if ($b | is-empty) { "" } else if ($b.source | is-empty) { $d } else { $b.source })
            if ($dsrc != "") and ($dsrc != $s) and ($dsrc not-in $dep_srcs) {
                $dep_srcs = ($dep_srcs | append $dsrc)
            }
        }
        $edges = ($edges | upsert $s ($dep_srcs | where { $in in $sources }))
    }

    # level via longest-path (Bellman-Ford style relaxation over the sources).
    # `level` is rebound each pass (immutable inside the `each` closures).
    mut level = ($sources | reduce --fold {} {|s, acc| $acc | upsert $s 1 })
    mut changed = true
    mut guard = 0
    while $changed and $guard < 64 {
        $changed = false
        $guard += 1
        let snapshot = $level          # immutable copy for the closures below
        for s in $sources {
            let waits = ($edges | get -o $s | default [])
            let cur = ($snapshot | get $s)
            let wait_levels = ($waits | each {|w| $snapshot | get -o $w | default 1 })
            let want = (1 + ([0] | append $wait_levels | math max))
            if $want > $cur {
                $level = ($level | upsert $s $want)
                $changed = true
            }
        }
    }

    let final_level = $level   # immutable copy for the closure below
    let final_edges = $edges
    $rows | each {|r|
        if $r.status in ["ncr", "retrigger"] {
            # build_blockers: the actionable sources this row build-depends on
            # (the build-time reason it can't build yet), for the stale column.
            $r
            | upsert level ($final_level | get -o $r.source | default 1)
            | upsert build_blockers ($final_edges | get -o $r.source | default [])
        } else {
            $r | upsert level 0 | upsert build_blockers []
        }
    }
}

# ---- public command ---------------------------------------------------------

# Which of a source package's build-deps stop resolving once -proposed is on?
export def main [
    package: string@pkg-completions   # Source package to analyze
    --recursive (-r)                  # Also analyze the build-deps of broken deps
    --series: string = $DEVEL_RELEASE # Series to check (default: devel)
    --raw                             # Return structured rows (no color/links)
]: nothing -> table {
    let view = (with-spinner $"Fetching ($series) archive indexes..." { pocket-view $series })

    if (source-best $view $package | is-empty) {
        error make { msg: $"No source package '($package)' found in ($series) / ($series)-proposed" }
    }

    let own = (own-binaries $view $package)
    let seed = (source-build-deps $view $package | where { $in not-in $own })

    let results = (with-spinner $"Classifying build-deps of ($package)..." {
        # Memo of name -> parsed binary stanza, threaded through the walk to
        # avoid re-scanning the 70MB index for every relation of every dep.
        mut memo = {}
        mut rows = []
        mut queue = $seed
        mut seen = []
        while ($queue | is-not-empty) {
            let dep = ($queue | first)
            $queue = ($queue | skip 1)
            if $dep in $seen { continue }
            $seen = ($seen | append $dep)

            let res = (classify-dep-memo $view $dep $memo)
            $memo = $res.memo
            let r = $res.row
            $rows = ($rows | append $r)

            if $recursive and ($r.status in ["ncr", "retrigger"]) {
                let sub_own = (own-binaries $view $r.source)
                let sub = (source-build-deps $view $r.source
                    | where { $in not-in $sub_own and $in not-in $seen })
                $queue = ($queue | append $sub)
            }
        }
        assign-levels $view $rows $memo
    })

    if $raw { return $results }

    # Display: one row per actionable source (dev/prof collapse to one), grouped
    # by topological level (fine rows hidden), then the fine count as a footer.
    let colors = { ncr: "red", retrigger: "yellow", fine: "green", missing: "dark_gray" }
    let actionable = ($results
        | where status in ["ncr", "retrigger"]
        | uniq-by source
        | sort-by level source)
    let n_fine = ($results | where status == "fine" | length)

    if ($actionable | is-empty) {
        print $"(ansi green)All ($n_fine) build-deps resolve cleanly with ($series)-proposed enabled.(ansi reset)"
        return []
    }

    mut out = []
    let max_level = ($actionable | get level | math max)
    # Map each actionable source name -> its row, for coloring stale deps that
    # are themselves in the actionable set.
    let action_by_src = ($actionable | reduce --fold {} {|r, acc| $acc | upsert $r.source $r })
    for lvl in 1..=$max_level {
        let group = ($actionable | where level == $lvl)
        for g in $group {
            let c = ($colors | get $g.status)
            let build_cells = ($g.build_blockers | each {|s|
                let arow = ($action_by_src | get -o $s)
                let cc = (if $arow != null { $colors | get $arow.status } else { "dark_gray" })
                $"(ansi $cc)($s)(ansi reset)"
            } | str join " ")
            let runtime_cells = ($g.broken | each {|b|
                let base = ($b | str replace -r '^((?:lib)?[a-z0-9+.-]+?)-[0-9.]+-[0-9a-f]{5}$' '$1')
                let bsrc = (dep-source $view $base)
                let arow = ($action_by_src | get -o $bsrc)
                if $arow != null {
                    let cc = ($colors | get $arow.status)
                    $"(ansi $cc)($base)(ansi reset)"
                } else if (source-in-proposed $view $bsrc) {
                    $"(ansi green)($base)(ansi reset)"
                } else {
                    $"(ansi dark_gray)($base)(ansi reset)"
                }
            } | uniq | str join " ")
            $out = ($out | append {
                level: $lvl
                source: (lp-source-link $g.source)
                version: $g.version
                status: $"(ansi $c)($g.status)(ansi reset)"
                stale_build_dep: $build_cells
                stale_runtime_dep: $runtime_cells
            })
        }
    }
    print $"(ansi dark_gray)(($n_fine)) build-deps resolve cleanly(ansi reset)"
    $out
}
