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
