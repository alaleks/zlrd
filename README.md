<p align="center">
  <img src=".github/logo.svg" alt="ZLRD Logo" width="200"/>
</p>

# zlrd

High-performance log reader written in Zig. Streams large files line-by-line with minimal memory usage.

## Install

Requires Zig 0.15.2 or later.

```bash
git clone https://github.com/alaleks/zlrd.git
cd zlrd
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zlrd /usr/local/bin/
```

## Usage

```
zlrd [options] <file...>

Options:
  -f, --file <path>        Log file (repeatable)
  -s, --search <text>      Search string (case-insensitive)
  -l, --level <levels>     Filter by level (case-insensitive)
                           Values: trace,debug,info,warn,error,fatal,panic
                           Comma-separated: -l error,warn
                           Repeatable:     -l error -l fatal
  -d, --date <date>        Date filter: YYYY-MM-DD or YYYY-MM-DD..YYYY-MM-DD
  -t, --tail               Follow file in real time
  -n, --num-lines <num>    Show last N lines
  -v, --version            Print version and exit
  -h, --help               Show this help
```

## Examples

```bash
# Basic viewing
zlrd app.log
zlrd app.log error.log

# Filter by level
zlrd -l error app.log
zlrd -l error,warn app.log
zlrd -l error -l fatal app.log

# Search
zlrd -s "connection failed" app.log

# Date filter
zlrd -d 2024-01-20 app.log
zlrd -d 2024-01-01..2024-01-31 app.log

# Tail mode
zlrd -t app.log
zlrd -t -l error -s "timeout" app.log

# Combine filters
zlrd -l error -d 2024-01-20 -s timeout app.log

# Last N lines
zlrd -n 100 app.log

# Short flags can be grouped (GNU-style)
zlrd -tl error app.log
```

## Log formats

zlrd auto-detects the format:

- **JSON** — `{"level":"error","message":"..."}`
- **Plain text** — `[ERROR] ...`, `level=error ...`, `severity=error ...`

## Roadmap

- [ ] Compressed logs (gzip, bzip2)
- [ ] Custom log format configuration
- [ ] Regex pattern matching
- [ ] Time range filtering

## Contributing

Follow Zig's style guide. Add tests for new features. Keep it simple.

## License

MIT — see [LICENSE](LICENSE) for details.
