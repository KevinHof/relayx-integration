# Writes data/validation/f3_tier_sample.csv from section q16 of sql/provisional/f3_cosing_bridge.sql
# (F3 part 2b validation sample: 60 T1, 40 T2, 20 T3 CAS mappings, seed 20261022).
#
# Invocation (PowerShell, repository root):
#   1. Run the F3 report and keep its TSV output (UTF-8):
#        $env:PYTHONPATH = 'src'; $env:PYTHONIOENCODING = 'utf-8'
#        cmd /c "<relayx python.exe> -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql
#                --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients
#                --timeout 3600 > f3_out.tsv"
#   2. Convert section q16 to CSV:
#        <relayx python.exe> -I scripts/f3/q16_to_csv.py f3_out.tsv data/validation/f3_tier_sample.csv
#   Prints the row count, rows per tier and the number of rows with non-ASCII characters.
#
# Scratch tool, copied unchanged from the session scratchpad (2026-10-22); kept until the part 2b
# addendum replaces it.
import collections, csv, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8-sig").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("## q16."))
rows = []
for l in lines[start + 1:]:
    if not l.strip():
        break
    rows.append(l.split("\t"))
header, body = rows[0], rows[1:]
assert all(len(r) == len(header) for r in body), "column count mismatch"
with open(dst, "w", encoding="utf-8", newline="") as f:
    csv.writer(f).writerows([header] + body)
print(len(body), collections.Counter(r[1] for r in body),
      "non-ascii rows:", sum(any(ord(ch) > 127 for ch in "".join(r)) for r in body))
