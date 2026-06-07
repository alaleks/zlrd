<p align="center">
  <img src=".github/logo.svg" alt="ZLRD Logo" width="200"/>
</p>

# zlrd — high-performance log viewer CLI (tail/grep alternative)

Fast and memory-efficient **log reader and analyzer** written in Zig.
Designed for working with large log files with support for filtering, search, and real-time streaming.

**zlrd is a modern CLI alternative to `tail`, `grep`, and basic log viewers.**

---

## ✨ Features

* ⚡ Stream large files line-by-line with minimal memory usage
* 🔍 Full-text search (case-insensitive)
* 📊 Filter by log levels (trace, debug, info, warn, error, fatal, panic)
* 📅 Filter logs by date or date range
* 🔄 Real-time mode (`tail -f` equivalent)
* 📦 Supports JSON and plain text logs
* 🧩 Works with multiple files
* 🗜️ Supports compressed logs (gzip)

---

## 🚀 Install

Requires **Zig 0.16.0 or later**

```bash
git clone https://github.com/alaleks/zlrd.git
cd zlrd
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zlrd /usr/local/bin/
```

---

## 🧪 Usage

```bash
zlrd [options] <file...>

Options:
  -f, --file <path>        Log file (repeatable)
  -s, --search <text>      Search string (case-insensitive)
  -l, --level <levels>     Filter by level (case-insensitive)
                           Values: trace,debug,info,warn,error,fatal,panic
                           Comma-separated: -l error,warn
                           Repeatable:     -l error -l fatal
  -d, --date <date>        Date filter: YYYY-MM-DD or YYYY-MM-DD..YYYY-MM-DD
      --from <time>        Time range start (HH:MM or HH:MM:SS)
      --to <time>          Time range end (HH:MM or HH:MM:SS)
      --output json        Output as JSONL for pipeline processing
  -t, --tail               Follow file in real time
  -n, --num-lines <num>    Show last N lines
  -v, --version            Print version and exit
  -h, --help               Show this help
```

---

## 📌 Examples

```bash
# Basic viewing
zlrd app.log
zlrd app.log error.log

# Filter by level
zlrd -l error app.log
zlrd -l error,warn app.log
zlrd -l error -l fatal app.log

# Search (like grep)
zlrd -s "connection|timeout" app.log
zlrd -s "goroutine" app.log
zlrd -s "error&connection" app.log

# Date filter
zlrd -d 2024-01-20 app.log
zlrd -d 2024-01-01..2024-01-31 app.log

# Time range filter (incident drill-down)
zlrd --from 14:00 --to 15:30 app.log
zlrd -d 2024-01-20 --from 09:00 --to 09:15 app.log

# Tail mode (real-time)
zlrd -t app.log
zlrd -t -l error -s "timeout" app.log

# Combine filters
zlrd -l error -d 2024-01-20 -s timeout app.log

# Last N lines
zlrd -n 100 app.log

# Short flags (GNU-style)
zlrd -tl error app.log
```

---

## 🧾 Supported Log Formats

zlrd automatically detects log format:

* **JSON logs**

  ```json
  {"level":"error","message":"..."}
  ```

* **Plain text logs**

  ```
  [ERROR] something failed
  level=error msg="..."
  severity=error ...
  ```

---

## 🤖 Agent Mode (planned)

Run zlrd as a background monitoring agent:

```bash
zlrd --agent --agent-port 9090 /var/log/app/*.log
```

- **Stateless watcher** — periodic scan, JSON metrics, threshold alerts
- **Sidecar** — gRPC streaming to central collector for multi-node clusters
- **eBPF probes** — kernel-level OOM/segfault/panic detection with near-zero overhead
- HTTP endpoints: `/metrics` (Prometheus), `/health`, `/events`
- Webhook alerts: Slack, Discord, Telegram

---

## 🗺️ Roadmap

* [x] Compressed logs (gzip)
* [x] Aggregates log rows
* [x] Regex-based filtering — `-s` with pattern matching for grep parity
* [x] Time-range filtering — `--from 14:00 --to 15:30` for incident drill-down
* [x] `--output json` — pipeline-friendly output (`zlrd ... | jq`)
* [ ] Homebrew tap + apt/yum packages — `brew install zlrd`
* [ ] Agent mode (`--agent`) — background monitoring, alerting, HTTP metrics
* [ ] Sidecar agent — gRPC streaming to central collector, multi-node
* [ ] eBPF agent — kernel-level probes (OOM, segfault, panic) with zero overhead

---

## 🤝 Contributing

* Follow Zig style guidelines
* Add tests for new features
* Keep the code simple and efficient

---

## 🏷️ Keywords

log viewer, log analyzer, cli tool, tail alternative, grep alternative, zig cli, log parser, log monitoring, developer tools

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
