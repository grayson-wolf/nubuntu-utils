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

# Run `work` while displaying a gum spinner with `title`. Spinner runs as a
# bash-backgrounded subprocess with explicit /dev/tty redirection so the
# animation reaches the controlling terminal regardless of how nu's stderr is
# routed. Falls back to a plain stderr message when gum or a TTY is missing.
export def with-spinner [title: string, work: closure]: any -> any {
    let inp = $in
    let use_spinner = ((which gum | is-not-empty) and (is-terminal --stderr) and ("/dev/tty" | path exists))
    if not $use_spinner {
        print -e $title
        return ($inp | do $work)
    }
    let safe_title = ($title | str replace --all "'" "'\"'\"'")
    let pid = (
        ^bash -c $"gum spin --title '($safe_title)' --spinner dot -- sleep 86400 </dev/tty >/dev/tty 2>/dev/tty & echo $!"
        | str trim
        | into int
    )
    let result = ($inp | do $work)
    ^kill $pid out+err> /dev/null
    $result
}

