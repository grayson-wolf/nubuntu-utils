# Shared helpers for the CI check scripts (native mode).
#
# A native check sources the toolkit at top level (nu `use` needs a literal
# path and cannot run conditionally), then asserts on returned records:
#
#   source-env ../../env.nu
#   use ../../mod.nu *
#   use ../lib.nu *
#   ...call commands directly, `fail` on violation...

export def fail [msg: string] {
    error make { msg: $msg }
}
