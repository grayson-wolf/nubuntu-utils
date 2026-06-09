# Generic forwarder for nubuntu-utils snap commands.
#
# `bin/launch <cmd> <args...>` routes here for any command that does not have a
# bespoke wrapper. We re-parse the arguments inside a fresh Nushell so that the
# underlying command's real signature (flags, defaults, completions) is the only
# source of truth — eliminating per-wrapper signature drift.
#
# Quoting: flag-looking args (starting with `-`) pass through unchanged so they
# remain parsed as flags. Other args are nuon-encoded when they contain shell /
# nu metacharacters, so values with spaces / quotes / etc. round-trip cleanly.
# Known limitation: `--flag=value with spaces` is not supported — use the
# separate-arg form `--flag "value with spaces"` instead.
def --wrapped main [cmd: string, ...args: string]: nothing -> any {
    let argstr = ($args | each {|a|
        if ($a | str starts-with '-') {
            $a
        } else if ($a =~ '[ \t\n"''$`()|<>;&\\]') {
            $a | to nuon
        } else {
            $a
        }
    } | str join ' ')
    nu --include-path ($env.SNAP? | default ".") -c $"use nubuntu-utils/ *; ($cmd) ($argstr)"
}
