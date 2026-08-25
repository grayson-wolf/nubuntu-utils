# q — push/pop round trip on a synthetic quilt package.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let fixture = "/tmp/nubuntu-ci-qfix"
rm -rf $fixture
mkdir $"($fixture)/debian/patches"
"hello\n" | save $"($fixture)/file.txt"
"--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-hello\n+goodbye\n" | save $"($fixture)/debian/patches/fix.patch"
"fix.patch\n" | save $"($fixture)/debian/patches/series"

cd $fixture
q push
if (open file.txt | str trim) != "goodbye" { fail "q push: patch not applied" }
q pop
if (open file.txt | str trim) != "hello" { fail "q pop: patch not reversed" }
print "q OK: push applied the patch, pop reversed it"
