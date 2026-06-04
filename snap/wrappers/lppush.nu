use nubuntu-utils/ *

def main [
    --force(-f)
    --merge-tags(-m)
    ...refs: string
] {
    lppush --force=$force --merge-tags=$merge_tags ...$refs
}
