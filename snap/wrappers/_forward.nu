# Generic forwarder for nubuntu-utils snap commands.
#
# `bin/launch <cmd> <args...>` routes here for any command that does not have a
# bespoke wrapper. We re-parse the arguments inside a fresh Nushell so that the
# underlying command's real signature (flags, defaults, completions) is the only
# source of truth — eliminating per-wrapper signature drift.
#
# Note: arguments are joined on spaces and re-parsed, so arguments containing
# embedded spaces are not supported (no nubuntu-utils command needs them).
def --wrapped main [cmd: string, ...args: string]: nothing -> any {
    let argstr = ($args | str join ' ')
    nu --include-path ($env.SNAP? | default ".") -c $"use nubuntu-utils/ *; ($cmd) ($argstr)"
}
