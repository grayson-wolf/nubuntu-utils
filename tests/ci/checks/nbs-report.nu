# nbs-report — current report parses to structured rows; -H gives history.
source-env ../../../env.nu
use ../../../mod.nu *
use lib.nu *

let report = (nbs-report --raw)
if ($report.packages | is-empty) { fail "nbs-report: no NBS packages" }
if ($report.rdeps | is-empty) { fail "nbs-report: no reverse deps" }
if ($report.generated | describe) != "datetime" { fail "nbs-report: generated is not a datetime" }

let rows = (nbs-report)
if ($rows | is-empty) { fail "nbs-report: empty current table" }
if not (($rows | columns) == ["package", "rdeps", "nbs rdeps", "main/restr", "via"]) {
    fail "nbs-report: unexpected current columns"
}

let pkg_rows = (nbs-report ksh)
if ($pkg_rows | is-empty) { fail "nbs-report: empty drill-down for ksh" }
if not (($pkg_rows | columns) == ["reverse dep", "component", "arches", "via"]) {
    fail "nbs-report: unexpected drill-down columns"
}

let deps = (nbs-report -d)
if ($deps | is-empty) { fail "nbs-report: empty dependents table" }
if not (($deps | columns) == ["package", "component", "nbs deps"]) {
    fail "nbs-report: unexpected dependents columns"
}

let daily = (nbs-report -H --days 7)
if ($daily | is-empty) { fail "nbs-report: empty history table" }
if ($daily | length) > 7 { fail "nbs-report: --days 7 returned more than 7 rows" }
if not (($daily | columns) == ["date", "removable", "total", "Δ total"]) {
    fail "nbs-report: unexpected history columns"
}

let samples = (nbs-report -H --raw)
if ($samples | is-empty) { fail "nbs-report: no samples" }
if (($samples | last).time | describe) != "datetime" { fail "nbs-report: raw time is not a datetime" }

print $"nbs-report OK: ($report.packages | length) NBS packages, ($report.rdeps | length) rdeps, ($report.dependents | length) dependents, ($samples | length) samples"
