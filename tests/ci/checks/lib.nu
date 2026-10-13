# Shared helpers for the CI check scripts (native mode).
#
# A native check sources the toolkit at top level (nu `use` needs a literal
# path and cannot run conditionally), then asserts on returned records:
#
#   source-env ../../../env.nu
#   use ../../../mod.nu *
#   use lib.nu *
#   ...call commands directly, `fail` on violation...

export def fail [msg: string] {
    error make { msg: $msg }
}

# True when an error's rendered text looks like a transient upstream/network
# failure (connection reset/refused, timeout, HTTP blip) rather than a code
# regression.
export def is-environmental [err: string]: nothing -> bool {
    $err =~ '(?i)timed out|I/O error|error sending request|HTTP \d{3} (fetching|posting)|rate-limited|connection (reset|refused)|dns'
}

# Run a live-data fetch, SKIPping the whole check (exit 0) when the upstream
# blips
export def fetch-or-skip [name: string, work: closure]: nothing -> any {
    let result = (try { { ok: true, value: (do $work) } } catch {|e| { ok: false, err: $e.rendered } })
    if not $result.ok {
        if (is-environmental $result.err) {
            let head = ($result.err | str substring 0..120 | str replace --all "\n" " ")
            print $"($name) SKIP: upstream fetch failed \(($head)) — environmental, not a regression"
            exit 0
        }
        fail $"($name): non-environmental error: ($result.err | str substring 0..400)"
    }
    $result.value
}
