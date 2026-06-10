<p align="center">
  <img src=".github/logo.svg" alt="zlrd" width="180"/>
</p>

<h1 align="center">zlrd</h1>

<p align="center">
  A fast log viewer for the terminal — a focused alternative to <code>tail</code>, <code>grep</code>, and ad-hoc log pipelines.
</p>

<p align="center">
  <a href="https://github.com/alaleks/zlrd/releases"><img src="https://img.shields.io/github/v/release/alaleks/zlrd?color=blue&label=release" alt="Release"></a>
  <a href="https://github.com/alaleks/zlrd/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/alaleks/zlrd/release.yml?label=build" alt="Build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/alaleks/zlrd?color=lightgrey" alt="License"></a>
</p>

---

## Overview

`zlrd` is a single-binary CLI for reading, filtering, and analyzing log files.
It streams files line-by-line with minimal memory use, recognizes common log
formats (JSON, bracketed plain text, logfmt), and offers filtering by level,
date, time range, and regex search. Built in Zig with SIMD-accelerated parsing.

## Features

- **Streaming reader** — line-by-line, constant memory, scales to multi-GB files
- **Format detection** — JSON, `[LEVEL]` bracketed, and `level=` logfmt
- **Level filtering** — `trace`, `debug`, `info`, `warn`, `error`, `fatal`, `panic`
- **Date and time filtering** — single date, date range, time-of-day window
- **Regex and literal search** — case-insensitive, with `|` (OR) and `&` (AND)
- **Tail mode** — follow live writes (`tail -f` equivalent)
- **Aggregation** — group identical or normalized lines with occurrence counts
- **JSONL output** — pipe to `jq` and other tools
- **Compressed input** — read `.log.gz` directly
- **Multi-file** — process several files in a single invocation

## Installation

### macOS — Homebrew

```bash
brew install alaleks/tap/zlrd
```

### Linux — apt (Debian, Ubuntu)

```bash
curl -fsSL https://packages.buildkite.com/aleksandr-aleksandrov/zlrd/setup.deb.sh | sudo bash
sudo apt install zlrd
```

### Pre-built binaries

Download the archive for your platform from
[Releases](https://github.com/alaleks/zlrd/releases/latest), then extract
and place `zlrd` on your `PATH`.

| Platform              | Archive                          |
| --------------------- | -------------------------------- |
| macOS Apple Silicon   | `zlrd-aarch64-macos.tar.gz`      |
| macOS Intel           | `zlrd-x86_64-macos.tar.gz`       |
| Linux x86_64          | `zlrd-x86_64-linux.tar.gz`       |
| Windows x86_64        | `zlrd-x86_64-windows.zip`        |

Each release also ships a `checksums.txt` with SHA-256 hashes for verification.

One-line install for Unix-like systems:

```bash
# macOS Apple Silicon
curl -fsSL https://github.com/alaleks/zlrd/releases/latest/download/zlrd-aarch64-macos.tar.gz \
  | tar xz && sudo mv zlrd /usr/local/bin/

# Linux x86_64
curl -fsSL https://github.com/alaleks/zlrd/releases/latest/download/zlrd-x86_64-linux.tar.gz \
  | tar xz && sudo mv zlrd /usr/local/bin/
```

### From source

Requires Zig 0.16.0 or later.

```bash
git clone https://github.com/alaleks/zlrd.git
cd zlrd
zig build -Doptimize=ReleaseFast
sudo install zig-out/bin/zlrd /usr/local/bin/
```

## Usage

```
zlrd [options] <file...>

  -f, --file <path>          Log file (repeatable)
  -s, --search <text>        Search string (literal or regex)
                             Operators: `|` = OR, `&` = AND
  -l, --level <levels>       Level filter (comma-separated, repeatable)
                             Values: trace, debug, info, warn, error, fatal, panic
  -d, --date <date>          Date filter: YYYY-MM-DD  or  YYYY-MM-DD..YYYY-MM-DD
      --from <time>          Time range start (HH:MM or HH:MM:SS)
      --to   <time>          Time range end   (HH:MM or HH:MM:SS)
      --output <mode>        Output mode: json (JSONL for pipelines)
  -t, --tail                 Follow file in real time
  -n, --num-lines <num>      Paginate: show N lines per page
  -a, --aggregate            Group identical matched lines
  -m, --aggregate-mode <mode> exact | level-message | json-message | normalized
  -v, --version              Print version and exit
  -h, --help                 Show help
```

If no file is given, `zlrd` reads every `*.log` and `*.log.gz` in the current
directory.

## Examples

```bash
# Stream a file with default formatting
zlrd app.log

# Filter by level
zlrd -l error,warn app.log

# Search with OR / AND operators
zlrd -s "connection|timeout" app.log
zlrd -s "error&database" app.log

# Date range
zlrd -d 2024-01-01..2024-01-31 app.log

# Time window inside one day (incident drill-down)
zlrd -d 2024-01-20 --from 09:00 --to 09:30 app.log

# Real-time follow
zlrd -t -l error app.log

# Aggregate normalized log lines (strips IDs, timestamps, digits)
zlrd -a -m normalized app.log

# Pipe to jq
zlrd --output json app.log | jq 'select(.level == "error")'

# Multiple files with combined filters
zlrd -l error -d 2024-01-20 -s "timeout" app.log gateway.log

# Grouped short flags (GNU-style)
zlrd -tl error app.log
```

## Supported log formats

`zlrd` auto-detects the format from the line shape.

**JSON**

```
{"time":"2024-01-20T12:00:00Z","level":"error","message":"connection refused"}
```

**Bracketed plain text**

```
2024-01-20 12:00:00 [ERROR] connection refused
```

**logfmt**

```
time=2024-01-20T12:00:00Z level=error msg="connection refused"
```

Recognized level keys: `level`, `severity`, `lvl`.
Recognized timestamp keys: `time`, `timestamp`, `date`.

## Aggregation modes

| Mode             | Groups by                                     | Use case                          |
| ---------------- | --------------------------------------------- | --------------------------------- |
| `exact`          | full line                                     | Count identical lines             |
| `level-message`  | level + extracted message                     | Same message, any timestamp       |
| `json-message`   | JSON `message`/`msg` field only               | Compare message text across runs  |
| `normalized`     | lowercased, digits → `#`, dates → `<date>`    | Find recurring error patterns     |

## Roadmap

- [x] Streaming reader with JSON, bracketed, and logfmt detection
- [x] Level, date, and time-range filtering
- [x] Regex search with `|` and `&` operators
- [x] Aggregation modes
- [x] gzip input
- [x] JSONL output for pipelines
- [x] Pre-built binaries for macOS, Linux, Windows
- [x] Homebrew tap and apt repository
- [ ] Agent mode: background watcher, HTTP metrics endpoint, alerting
- [ ] Sidecar mode: gRPC streaming to a central collector
- [ ] eBPF probes for kernel-level OOM, segfault, and panic detection

## Contributing

Bug reports and pull requests are welcome.

- Run `zig build test` before submitting; all tests must pass.
- Run `zig fmt src/` to keep formatting consistent.
- Follow the existing style: no hidden allocations, explicit error handling,
  small focused functions.

## License

[MIT](LICENSE)
