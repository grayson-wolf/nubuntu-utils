# Shared formatting utilities (OSC8 hyperlinks, LP bug links)

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

# Convert a (possibly fractional) number of days into a Nushell duration.
export def days-to-duration [days: number]: nothing -> duration {
    $days * 86400 * 1_000_000_000 | math floor | into int | into duration
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
    let result = ($inp | do $work)
    job kill $jid
    "\r\e[K" | save --append --raw /dev/tty
    $result
}
