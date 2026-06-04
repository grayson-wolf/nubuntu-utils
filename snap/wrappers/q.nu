use nubuntu-utils/ *

# Dispatch q subcommands
def main [...args: string] {
    if ($args | is-empty) {
        q
        return
    }
    let cmd = $"q ($args | str join ' ')"
    nu --include-path ($env.SNAP? | default ".") -c $"use nubuntu-utils/ *; ($cmd)"
}
