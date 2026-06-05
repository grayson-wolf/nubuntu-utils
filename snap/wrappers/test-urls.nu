use nubuntu-utils/ *

def main [--proposed (-p)] {
    if $proposed {
        test-urls --proposed
    } else {
        test-urls
    }
}
