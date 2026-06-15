# Personal package watchlist — persistent list of source packages that are
# treated as "yours" by `my excuses` and `my srus` regardless of uploader.
# Stored as NUON at $env.NUBUNTU_STATE_DIR/watch.nuon.

export def watchlist-path []: nothing -> string {
    $"($env.NUBUNTU_STATE_DIR)/watch.nuon"
}

# Load the watchlist. Returns an empty list if the file does not yet exist.
export def load-watchlist []: nothing -> list<string> {
    let path = watchlist-path
    if not ($path | path exists) { return [] }
    open $path
}

# Persist the watchlist (overwrites the file).
export def save-watchlist [list: list<string>]: nothing -> nothing {
    $list | save --force (watchlist-path)
}
