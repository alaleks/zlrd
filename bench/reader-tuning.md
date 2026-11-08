# Reader worker and chunk tuning — 2026-11-08

Decision: retain the current ceiling of 8 workers and 1 MiB chunks. These measurements do not justify a workload-specific worker policy. The existing CPU-count and available-chunk limits still apply.

Measured on the local macOS arm64 host with Zig 0.17.1, ReleaseFast, using `zlrd-lite`. Input was approximately 128 MiB of JSONL: a repeated block of 4,096 records with timestamp, level, message, service, status and trace fields. Messages were `request N handled` for N from 0 through 4095. Input and output used local files; output was not discarded to `/dev/null`. Three runs per configuration, median wall time including process startup; runs predominantly used the filesystem cache. Files were not fsynced. Build time and SHA-256 verification were excluded from timing.

Temporary source copies varied `parallel_max_workers` and `parallel_chunk_bytes`; the 1-worker configuration falls back to serial scanning. All output hashes matched the serial baseline for each mode.

Modes: plain (`--color never`), literal (`--color never --search 'request&4095'`), regex (`--color never --search 'request.*4095'`), styled (`--color always`).

| Worker ceiling | Chunk MiB | Plain ms | Literal ms | Regex ms | Styled ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 79.3 | 31.5 | 649.2 | 323.1 |
| 2 | 1 | 48.4 | 18.5 | 329.3 | 187.4 |
| 2 | 4 | 49.1 | 18.4 | 329.9 | 188.8 |
| 2 | 8 | 48.3 | 19.8 | 367.9 | 196.6 |
| 4 | 1 | 38.5 | 12.6 | 182.0 | 106.1 |
| 4 | 4 | 79.9 | 15.0 | 184.2 | 112.6 |
| 4 | 8 | 34.9 | 15.1 | 180.6 | 119.5 |
| 8 | 1 | 32.7 | 11.0 | 133.4 | 90.8 |
| 8 | 4 | 32.4 | 13.0 | 129.6 | 103.5 |
| 8 | 8 | 35.9 | 13.2 | 126.4 | 113.6 |

At 8 workers, larger chunks improved regex by only about 2–5%, while literal search and styled output regressed. They also reserve larger per-worker buffers. Reducing the worker ceiling slowed every measured mode at 1 MiB.

Limits: one host and synthetic JSONL workload, sequential configuration order, three samples, no cold-cache or disk-saturation measurements. Plain-text input, JSON output conversion, large multi-GiB files, other CPUs, and the 4 MiB parallel-entry threshold were not tuned. Differences of a few milliseconds are not evidence for a universal policy. These results support retaining the defaults, not claiming a new speedup.
