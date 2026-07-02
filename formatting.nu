# Shared formatting utilities: OSC8 hyperlinks, LP bug links, spinners
# (with-spinner), version-delta coloring, gum color-spec → ANSI mapping, and
# generic value formatters (bool glyphs, MiB sizes, relative times, durations).

# Wrap display text in an OSC8 clickable hyperlink.
# Returns display unchanged if url is empty.
export def osc8-link [url: string, display: string]: nothing -> string {
    if ($url | is-not-empty) {
        $"\e]8;;($url)\e\\($display)\e]8;;\e\\"
    } else {
        $display
    }
}

# Format a Launchpad bug number as a clickable link.
# Display is just the bug number (no "LP#" prefix — these are always Ubuntu/LP bugs).
# Accepts optional color (ansi code) to wrap the number.
export def lp-bug-link [id: int, --color: string]: nothing -> string {
    let label = ($id | into string)
    let display = if ($color | is-not-empty) {
        $"($color)($label)(ansi reset)"
    } else {
        $label
    }
    let url = $"https://bugs.launchpad.net/bugs/($id)"
    osc8-link $url $display
}

# Build the canonical Launchpad page URL for an Ubuntu source package.
# With a (non-empty) version, points at that specific upload page; otherwise
# the unversioned source overview. Version strings are used verbatim — LP
# accepts epochs/tildes literally (e.g. `1:10.3p1-4ubuntu1`).
export def lp-source-url [package: string, version?: string]: nothing -> string {
    let base = $"https://launchpad.net/ubuntu/+source/($package)"
    if ($version | is-empty) { $base } else { $"($base)/($version)" }
}

# Clickable link to an Ubuntu source package on Launchpad.
#   --version set : links to that specific upload; default label is the version
#   --version unset: links to the source overview; default label is the package
# Use --display to override the visible text (e.g. a colored version-delta
# string, or a combined "pkg/version" cell).
export def lp-source-link [
    package: string
    --version: string = ""
    --display: string = ""
]: nothing -> string {
    let url = (lp-source-url $package $version)
    let label = if ($display | is-not-empty) { $display
        } else if ($version | is-not-empty) { $version
        } else { $package }
    osc8-link $url $label
}

# Link a combined "package/version" identifier (e.g. an autopkgtest trigger
# like `nbd/1:3.26.1-6.1ubuntu2`) to its specific upload page, keeping the
# whole spec as the display text. No `/` → links to the unversioned source.
export def lp-source-spec-link [spec: string]: nothing -> string {
    let idx = ($spec | str index-of "/")
    if $idx < 0 {
        lp-source-link $spec
    } else {
        let pkg = ($spec | str substring 0..<$idx)
        let ver = ($spec | str substring ($idx + 1)..)
        lp-source-link $pkg --version $ver --display $spec
    }
}

# Convert a (possibly fractional) number of days into a Nushell duration,
# rounded to the nearest minute (so the display stays human-readable:
# "12hr 36min" rather than "12hr 36min 2sec 999ms 999µs 999ns").
export def days-to-duration [days: number]: nothing -> duration {
    let minutes = ($days * 1440 | math round | into int)
    $minutes * 60_000_000_000 | into duration
}

# Green ✓ / dim · glyph for a boolean. `--invert` swaps semantics.
export def bool-glyph [b: bool, --invert]: nothing -> string {
    let v = if $invert { not $b } else { $b }
    if $v { $"(ansi green)✓(ansi reset)" } else { $"(ansi dark_gray)·(ansi reset)" }
}

# Format MiB as a human size: 8192 -> "8 GiB", 500 -> "500 MiB".
export def fmt-mib [mib: int]: nothing -> string {
    if $mib >= 1024 { $"((($mib / 1024) | math round)) GiB" } else { $"($mib) MiB" }
}

# Format an ISO timestamp as relative ("21h ago", "3d ago", "2w ago"),
# or "YYYY-MM-DD" for ages >90 days. Empty input returns "".
export def fmt-relative [iso: string]: nothing -> string {
    if ($iso | is-empty) { return "" }
    let dt = (try { $iso | into datetime } catch { null })
    if $dt == null { return $iso }
    let age = ((date now) - $dt)
    if $age < 1day { $"((($age / 1hr) | math round))h ago" } else if $age < 30day { $"((($age / 1day) | math round))d ago" } else if $age < 90day { $"((($age / 7day) | math round))w ago" } else { ($dt | format date "%Y-%m-%d") }
}

# Convert a gum-style color spec to an ANSI SGR foreground escape.
# Accepts:
#   - "#rrggbb"   → 24-bit truecolor
#   - "0".."255"  → 256-color palette index
#   - any name accepted by nu's `ansi` builtin (e.g. magenta, cyan, purple_bold)
# Returns "" on empty input or unrecognized value.
def gum-color-to-ansi [v: string]: nothing -> string {
    if ($v | is-empty) { return "" }
    if (($v | str starts-with "#") and (($v | str length) == 7)) {
        let r = (try { $v | str substring 1..2 | into int --radix 16 } catch { -1 })
        let g = (try { $v | str substring 3..4 | into int --radix 16 } catch { -1 })
        let b = (try { $v | str substring 5..6 | into int --radix 16 } catch { -1 })
        if $r >= 0 and $g >= 0 and $b >= 0 {
            return $"\e[38;2;($r);($g);($b)m"
        }
    }
    let n = (try { $v | into int } catch { -1 })
    if $n >= 0 and $n <= 255 {
        return $"\e[38;5;($n)m"
    }
    try { ansi $v } catch { "" }
}

# Run `work` while displaying an animated braille spinner with `title`.
#
# The spinner runs as a `job spawn` coroutine inside this nu process and
# writes frames straight to /dev/tty. Because there is no external
# subprocess, the spinner cannot be orphaned: when nu exits (cleanly or via
# Ctrl-C) the job dies with it. On the happy path we `job kill` and erase
# the spinner line.
#
# Falls back to a plain stderr message when stderr is not a TTY or /dev/tty
# is unavailable.
#
# Colors are read in this priority order, matching gum's env-var theme so
# anyone with a tuned gum theme gets it for free:
#   spinner: NUBUNTU_SPINNER_COLOR → GUM_SPIN_SPINNER_FOREGROUND → "212" (pink)
#   title:   NUBUNTU_SPINNER_TITLE_COLOR → GUM_SPIN_TITLE_FOREGROUND → "" (none)
# Values use gum's syntax: "#rrggbb", "0".."255", or a nu `ansi` color name.
export def with-spinner [title: string, work: closure]: any -> any {
    let inp = $in
    let use_spinner = ((is-terminal --stderr) and ("/dev/tty" | path exists))
    if not $use_spinner {
        print -e $title
        return ($inp | do $work)
    }
    let spinner_raw = (
        $env.NUBUNTU_SPINNER_COLOR?
        | default ($env.GUM_SPIN_SPINNER_FOREGROUND? | default "212")
    )
    let title_raw = (
        $env.NUBUNTU_SPINNER_TITLE_COLOR?
        | default ($env.GUM_SPIN_TITLE_FOREGROUND? | default "")
    )
    let spinner_color = (gum-color-to-ansi $spinner_raw)
    let title_color = (gum-color-to-ansi $title_raw)
    let reset = "\e[0m"
    let frames = ["⣾ ", "⣽ ", "⣻ ", "⢿ ", "⡿ ", "⣟ ", "⣯ ", "⣷ "]
    let n = ($frames | length)
    let jid = (job spawn {
        mut i = 0
        loop {
            let frame = ($frames | get ($i mod $n))
            # \r returns cursor to col 0; \e[K clears to end of line.
            $"\r($spinner_color)($frame)($reset) ($title_color)($title)($reset)\e[K"
                | save --append --raw /dev/tty
            sleep 80ms
            $i = $i + 1
        }
    })
    let cleanup = {
        job kill $jid
        "\r\e[K" | save --append --raw /dev/tty
    }
    let result = try { $inp | do $work } catch {|err|
        do $cleanup
        error make $err
    }
    do $cleanup
    $result
}

# Color the differing tail of two version strings.
#
# Finds the longest common prefix, then colors everything from the first
# point of divergence to the end of each string. We deliberately do NOT
# also compute a common suffix: Debian versions often have a "noise tail"
# (`-1`, `+ds-1`, ~ppa1) that a suffix-match would latch onto, visually
# fragmenting the changed region. Reading left-to-right, "from here to the
# end is the new value" is the model.
#
# If the inputs are identical, both are returned unchanged.
# Colors are nu `ansi` color names; default red (old) / green (new).
export def version-delta [
    old: string
    new: string
    --old-color: string = "red"
    --new-color: string = "green"
]: nothing -> record<old: string, new: string> {
    if $old == $new {
        return { old: $old, new: $new }
    }
    let oc = ($old | split chars)
    let nc = ($new | split chars)
    let max_pref = ([($oc | length) ($nc | length)] | math min)

    mut p = 0
    while $p < $max_pref and ($oc | get $p) == ($nc | get $p) { $p = $p + 1 }

    let pref = ($oc | first $p | str join)
    let old_tail = ($oc | skip $p | str join)
    let new_tail = ($nc | skip $p | str join)

    let old_colored = if ($old_tail | is-empty) {
        $pref
    } else {
        $"($pref)(ansi $old_color)($old_tail)(ansi reset)"
    }
    let new_colored = if ($new_tail | is-empty) {
        $pref
    } else {
        $"($pref)(ansi $new_color)($new_tail)(ansi reset)"
    }
    { old: $old_colored, new: $new_colored }
}

# Format a date as human-readable plus relative duration (e.g "Thu, 2 Jul 2026 16:35:00 (1h ago))
export def fmt-date-relative [date: datetime] {
    let fdate = $date | format date "%a, %d %b %Y %H:%M:%S"
    let rel = ($date | date humanize)
    $"($fdate) \(($rel)\)"
}
