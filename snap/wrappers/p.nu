use nubuntu-utils/ *

# Dispatch p subcommands
def main [...args: string] {
    if ($args | is-empty) {
        p
        return
    }
    let cmd = $"p ($args | str join ' ')"
    nu --include-path ($env.SNAP? | default ".") -c $"use nubuntu-utils/ *; ($cmd)"
}
