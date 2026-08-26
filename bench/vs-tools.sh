#!/usr/bin/env bash
# Compares zlrd against the tools people actually reach for.
#
# The tools do not all do the same work, so runs are grouped by task, every
# command is shown as it is run, and the number of lines each one produced is
# printed next to its time. That last column is the point: a tool that errors
# out or silently matches nothing looks infinitely fast otherwise, and three
# of the first numbers this script ever produced were exactly that — jq
# aborting on line 2, Apple's zcat refusing a .gz, and less passing the whole
# file through because stdout was not a terminal.
#
# Output goes to a real file, never to /dev/null. GNU grep checks whether its
# stdout is /dev/null and, if so, stops at the first match like `-q` — the
# first version of this script measured that and reported grep at 32 GB/s.
# Writing to a file costs every tool the same and keeps them all honest.
#
# Usage: bench/vs-tools.sh [path/to/zlrd]
set -uo pipefail

ZLRD="${1:-./zig-out/bin/zlrd}"
[[ -x "$ZLRD" ]] || { echo "build first: zig build -Doptimize=ReleaseFast" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MIXED="$WORK/mixed.log"
JSONL="$WORK/pure.jsonl"
REPEAT="$WORK/repeat.log"
REPS=5

# A third JSON, a third bracketed plain text, a third logfmt — the mix a real
# service directory has. `pure.jsonl` is the same data restricted to the JSON
# third, so jq gets a task it can actually complete.
python3 - "$MIXED" "$JSONL" "$REPEAT" <<'PY'
import json, random, sys, io
random.seed(7)
levels = ["debug", "info", "info", "info", "warn", "error"]
svcs = ["api", "auth", "db", "cache", "worker"]
mixed, pure = io.StringIO(), io.StringIO()
for i in range(400_000):
    lv = random.choice(levels)
    if i % 3 == 0:
        rec = json.dumps({
            "level": lv, "time": "2026-08-26T%02d:%02d:%02dZ" % (i % 24, i % 60, (i * 7) % 60),
            "service": random.choice(svcs), "msg": "request handled",
            "status": 200 + (i % 5), "latency_ms": round(random.random() * 300, 2),
            "trace_id": "%032x" % random.getrandbits(128),
        }, separators=(",", ":"))  # compact, the way a logger writes it
        mixed.write(rec + "\n"); pure.write(rec + "\n")
    elif i % 3 == 1:
        mixed.write("2026-08-26 %02d:%02d:%02d [%s] %s: connection pool size=%d idle=%d\n"
                    % (i % 24, i % 60, (i * 7) % 60, lv.upper(), random.choice(svcs), i % 50, i % 13))
    else:
        mixed.write("time=2026-08-26T%02d:%02d:%02dZ level=%s service=%s msg=\"payload processed\" bytes=%d\n"
                    % (i % 24, i % 60, (i * 7) % 60, lv, random.choice(svcs), i * 13 % 99999))
# Aggregation only makes sense on logs that repeat, and real ones do: a
# service emits a few thousand distinct message shapes, not a fresh one per
# line. A high-cardinality fixture would also push past zlrd's 100k-group
# cap, and it would then look fast for the wrong reason — by dropping the
# groups it ran out of room for.
rep = io.StringIO()
templates = [
    "level=%s msg=\"%s\" service=%s" % (lv, m, sv)
    for lv in levels for sv in svcs
    for m in ("request handled", "cache miss", "pool exhausted", "retry scheduled",
              "upstream timeout", "token refreshed", "batch flushed", "lease renewed")
]
for i in range(400_000):
    rep.write(templates[i % len(templates)] + "\n")

open(sys.argv[1], "w").write(mixed.getvalue())
open(sys.argv[2], "w").write(pure.getvalue())
open(sys.argv[3], "w").write(rep.getvalue())
PY

gzip -kf "$MIXED"
MIXED_MB=$(python3 -c "import os;print(f'{os.path.getsize(\"$MIXED\")/1048576:.1f}')")
JSONL_MB=$(python3 -c "import os;print(f'{os.path.getsize(\"$JSONL\")/1048576:.1f}')")
REPEAT_MB=$(python3 -c "import os;print(f'{os.path.getsize(\"$REPEAT\")/1048576:.1f}')")
REPEAT_DISTINCT=$(sort -u "$REPEAT" | wc -l | tr -d ' ')

have() { command -v "$1" >/dev/null 2>&1; }
GZCAT=$(have gzcat && echo gzcat || echo "gzip -dc")

# Runs <cmd> REPS times, keeping the best wall time. Records the exit status
# and the line count of the first run so the caller can show whether the tool
# actually did the work.
LAST_MS=0; LAST_LINES=0; LAST_RC=0
measure() {
  local cmd="$1" t0 t1 ms best=999999
  eval "$cmd" > "$WORK/out" 2>"$WORK/err"
  LAST_RC=$?
  LAST_LINES=$(wc -l < "$WORK/out" | tr -d ' ')
  for _ in $(seq 1 $REPS); do
    t0=$(python3 -c 'import time;print(time.time())')
    eval "$cmd" > "$WORK/sink" 2>/dev/null
    t1=$(python3 -c 'import time;print(time.time())')
    ms=$(python3 -c "print(int(($t1-$t0)*1000))")
    (( ms < best )) && best=$ms
  done
  LAST_MS=$best
}

row() { # row <label> <cmd> <size_mb> [note]
  local label="$1" cmd="$2" mb="$3" note="${4:-}"
  measure "$cmd"
  local status="$note"
  if (( LAST_RC != 0 )); then
    status="FAILED (exit $LAST_RC) — $(head -1 "$WORK/err" | cut -c1-40)"
  fi
  python3 -c "
ms=$LAST_MS; mb=$mb; lines=$LAST_LINES
rate=f'{mb/(ms/1000):7.0f}' if ms>0 else '    n/a'
print(f'  {\"$label\":<14} {ms:6d} ms {rate} MB/s  {lines:>7} lines  {\"$status\"}')"
}

echo
echo "zlrd vs standard tools"
echo "  mixed fixture:  $MIXED_MB MB, 400k lines — JSON / bracketed / logfmt in equal parts"
echo "  json fixture:   $JSONL_MB MB, the JSON third on its own"
echo "  host:           $(uname -sm), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo "  best of $REPS runs, warm page cache, stdout to a file (see note above)"
echo "  'lines' is what each command actually emitted — equal counts mean equal work."
echo "  zlrd's human output adds a blank line between plain-text records and a"
echo "  level summary at the end, so it runs higher there; the level-filter"
echo "  rows below use --output json, which is one line per record like jq."
echo

echo "── 1. Substring search, print every match ──────────────────────────────"
have ggrep && row "GNU grep" "ggrep 'payload processed' '$MIXED'" "$MIXED_MB"
have rg    && row "ripgrep"  "rg -N 'payload processed' '$MIXED'" "$MIXED_MB"
have ugrep && row "ugrep"    "ugrep 'payload processed' '$MIXED'" "$MIXED_MB"
row "zlrd" "'$ZLRD' -s 'payload processed' '$MIXED'" "$MIXED_MB" "also detects the format"
echo "   Same bytes scanned, same matches found. zlrd also detects the format"
echo "   of each line it prints, which grep does not."
echo

echo "── 2. Filter by level, mixed formats ───────────────────────────────────"
have ggrep && row "GNU grep" "ggrep '\"level\":\"error\"' '$MIXED'" "$MIXED_MB" "matches the JSON third only"
have jq    && row "jq"       "jq -c 'select(.level==\"error\")' '$MIXED'" "$MIXED_MB" "cannot parse the file"
row "zlrd" "'$ZLRD' -l error --output json '$MIXED'" "$MIXED_MB" "all three formats"
echo "   The line counts are the story here, not the times: grep sees only the"
echo "   errors written as JSON, and jq stops at the first line that is not."
echo

echo "── 3. Filter by level, pure JSONL (a fair fight for jq) ────────────────"
echo "   Every tool here reads the same file and emits one JSON object per"
echo "   matching record, so the line counts should agree exactly."
have jq    && row "jq"       "jq -c 'select(.level==\"error\")' '$JSONL'" "$JSONL_MB"
have ggrep && row "GNU grep" "ggrep '\"level\":\"error\"' '$JSONL'" "$JSONL_MB" "substring, not a parse"
row "zlrd" "'$ZLRD' -l error --output json '$JSONL'" "$JSONL_MB"
echo

echo "── 4. Group identical messages ─────────────────────────────────────────"
echo "   Run on a $REPEAT_MB MB fixture of $REPEAT_DISTINCT distinct lines — logs repeat,"
echo "   and a high-cardinality file would push zlrd past its 100k-group cap,"
echo "   which would make it look fast by dropping work. All three should"
echo "   report the same number of groups."
row "sort|uniq -c" "sort '$REPEAT' | uniq -c | sort -rn" "$REPEAT_MB" "sorts the whole file"
row "awk"          "awk '{c[\$0]++} END{for(k in c) print c[k], k}' '$REPEAT'" "$REPEAT_MB" "hash table, same algorithm"
row "zlrd -a"      "'$ZLRD' -a --output json '$REPEAT'" "$REPEAT_MB" "hashes as it streams"
echo

echo "── 5. Compressed input ─────────────────────────────────────────────────"
have ggrep && row "gzcat|grep" "$GZCAT '$MIXED.gz' | ggrep 'payload processed'" "$MIXED_MB"
have rg    && row "ripgrep -z" "rg -N -z 'payload processed' '$MIXED.gz'" "$MIXED_MB"
row "zlrd" "'$ZLRD' -s 'payload processed' '$MIXED.gz'" "$MIXED_MB" "no external gunzip"
echo

echo "── 6. Read and render the whole file ───────────────────────────────────"
row "cat"   "cat '$MIXED'"   "$MIXED_MB" "no parsing"
row "wc -l" "wc -l '$MIXED'" "$MIXED_MB" "counts newlines"
row "zlrd"  "'$ZLRD' '$MIXED'" "$MIXED_MB" "parses and formats every line"
echo
