#!/usr/bin/env bash
# Builds the two logs the demo tape reads.
#
#   sample.log — ~20 lines, sized so a full screen of output fits in frame.
#                All three formats, one message carrying a nested JSON payload.
#   app.log    — 4000 lines, only used for the aggregation frame, where the
#                point is that many lines collapse into few.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import json, random

random.seed(11)
svcs = ["api", "auth", "billing", "cache"]


def jsonl(i, lv, msg, extra=None):
    rec = {"level": lv, "time": "2026-08-26T10:%02d:%02dZ" % (i, i * 3 % 60),
           "service": random.choice(svcs), "msg": msg,
           "status": 200 + (i % 5), "latency_ms": round(random.random() * 300, 1)}
    if extra:
        rec.update(extra)
    return json.dumps(rec, separators=(",", ":"))


def bracket(i, lv):
    return "2026-08-26 10:%02d:%02d [%s] %s: connection pool size=%d idle=%d" % (
        i, i * 3 % 60, lv.upper(), random.choice(svcs), i % 50, i % 13)


def logfmt(i, lv):
    return ('time=2026-08-26T10:%02d:%02dZ level=%s service=%s '
            'msg="payload processed" bytes=%d' % (i, i * 3 % 60, lv,
                                                  random.choice(svcs), i * 977 % 99999))


# Hand-ordered so every frame of the recording has something to show: the
# formats interleave, and the embedded-JSON line lands where `-s upstream`
# will surface it.
body = json.dumps({"code": 503, "detail": "upstream refused connection",
                   "retry_after": 30, "endpoint": "/v2/charge", "shard": 3},
                  separators=(",", ":"))
sample = [
    jsonl(1, "info", "request handled"),
    bracket(2, "info"),
    logfmt(3, "debug"),
    jsonl(4, "warn", "retry scheduled"),
    bracket(5, "error"),
    jsonl(6, "info", "upstream replied", {"body": body}),
    logfmt(7, "error"),
    jsonl(8, "info", "request handled"),
    bracket(9, "warn"),
    logfmt(10, "info"),
    jsonl(11, "error", "charge failed"),
    bracket(12, "info"),
]
open("sample.log", "w").write("\n".join(sample) + "\n")

lines = []
for i in range(4000):
    lv = random.choice(["debug", "info", "info", "info", "warn", "error"])
    if i % 3 == 0:
        lines.append(jsonl(i % 60, lv, "request handled"))
    elif i % 3 == 1:
        lines.append(bracket(i % 60, lv))
    else:
        lines.append(logfmt(i % 60, lv))
open("app.log", "w").write("\n".join(lines) + "\n")

# repeat.log — 60k lines drawn from six distinct messages. The aggregation
# frame needs the collapse to be visible in one screen, which means few
# groups and large counts, not a realistic distribution.
shapes = [
    jsonl(14, "error", "charge declined by processor"),
    jsonl(21, "warn", "connection pool exhausted"),
    jsonl(7, "info", "request handled"),
    bracket(33, "error"),
    logfmt(45, "info"),
    bracket(52, "debug"),
]
weights = [9, 17, 51, 6, 14, 3]
rep = []
for shape, w in zip(shapes, weights):
    rep.extend([shape] * (w * 100))
random.shuffle(rep)
open("repeat.log", "w").write("\n".join(rep) + "\n")
PY
for f in sample.log app.log repeat.log; do echo "wrote $f ($(wc -l < $f | tr -d ' ') lines)"; done
