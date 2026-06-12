# On-disk cache helpers for nubuntu-utils.
# Pure filesystem; no HTTP, no LP knowledge. Single owner of cache paths.

# Cache root with safe fallback to ~/.cache/nubuntu-utils.
def cache-root []: nothing -> string {
    let root = ($env.NUBUNTU_CACHE_DIR? | default ("~/.cache/nubuntu-utils" | path expand))
    if not ($root | path exists) { mkdir $root }
    $root
}

# Resolve (and ensure) a kind subdirectory: <root>/<kind>/.
def cache-dir [kind: string]: nothing -> string {
    let dir = ([(cache-root) $kind] | path join)
    if not ($dir | path exists) { mkdir $dir }
    $dir
}

# Resolve a cache file path under a kind subdir: <root>/<kind>/<key>.
export def cache-file [kind: string, key: string]: nothing -> string {
    [(cache-dir $kind) $key] | path join
}

# Resolve a flat cache file: <root>/<name>. For genuine singletons only
# (e.g. package-team-mapping.nuon, autopkgtest.cookie).
export def cache-file-flat [name: string]: nothing -> string {
    [(cache-root) $name] | path join
}

# Filesystem-safe key sanitizer for arbitrary string keys.
export def cache-key [key: string]: nothing -> string {
    $key | str replace --all ":" "_" | str replace --all "/" "_" | str replace --all "~" "_"
}

# Freshness check. Returns false on missing or older-than-ttl.
export def cache-fresh [path: string, ttl: duration]: nothing -> bool {
    if not ($path | path exists) { return false }
    let age = ((date now) - (ls $path | get 0.modified))
    $age < $ttl
}

# Open if fresh, else null. Swallows read errors as null.
export def cache-load [path: string, ttl: duration]: nothing -> any {
    if not (cache-fresh $path $ttl) { return null }
    try { open $path } catch { null }
}

# Save value to cache; wraps in try so write errors don't propagate.
export def cache-save [path: string, value: any]: nothing -> nothing {
    try { $value | save -f $path }
}
