<p align="center">
  <img src=".github/logo.svg" alt="ZLRD Logo" width="200"/>
</p>

# zlrd

**zlrd** is a high-performance log reader and parser written in **Zig**.

Designed for fast, predictable, streaming processing of large log files with minimal memory overhead. `zlrd` works well both for offline log analysis and real-time log inspection (`tail -f` style).

> ⚠️ **Early Development**: This project is not stable yet. Use at your own risk.

## Features

**Performance**
- Streaming I/O with no memory buffering of entire files
- Zero garbage collection overhead
- Explicit memory management for predictable resource usage
- Faster than traditional pagers like `less` for log analysis workloads

**Large File Support**
- Processes logs line-by-line without loading files into memory
- Handles partially written lines correctly
- Works efficiently with multi-gigabyte log files

**Flexible Filtering**
- By log level: `Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal`, `Panic`
- By search string (case-insensitive)
- By date and date ranges
- Combine multiple filters for precise queries

**Real-Time Monitoring**
- Follow log files in real time (`--tail` mode)
- Process multiple files simultaneously
- Graceful handling of log rotation

**Log Format Support**
- JSON logs: `{"level":"error","message":"connection failed"}`
- Plain-text logs: `[ERROR] connection failed, level=..., severity=..., lvl=...`
- Auto-detection of log format

**Developer-Friendly**
- Colored output for better readability
- Terminal-friendly formatting
- Simple, predictable CLI interface
- No background services or hidden threads
- Minimal dependencies

## Installation

### From Source

Requirements: Zig 0.51.2 or later

```bash
git clone https://github.com/yourusername/zlrd.git
cd zlrd
zig build -Doptimize=ReleaseFast
```

The binary will be available at `zig-out/bin/zlrd`.

### Adding to PATH

```bash
# Linux/macOS
sudo cp zig-out/bin/zlrd /usr/local/bin/

# Or add to your shell profile
export PATH="$PATH:/path/to/zlrd/zig-out/bin"
```

## Usage

```
zlrd [options] <file...>

Options:
  -f, --file <path>        Add log file (can be repeated)
  -s, --search <text>      Search string (case-insensitive)
  -l, --level <levels>     Filter by log levels
                           Levels: Trace,Debug,Info,Warn,Error,Fatal,Panic
                           Multiple: -l Error,Warn -l Fatal
  -d, --date <date>        Date filter (YYYY-MM-DD)
  -t, --tail               Follow log files in real time
  -n, --num-lines <num>    Number of lines to display
  -h, --help               Show this help message
```

### Examples

**View a log file**
```bash
zlrd application.log
```

**Filter by log level**
```bash
# Show only errors and warnings
zlrd -l Error,Warn application.log

# Show critical issues
zlrd -l Error -l Fatal -l Panic application.log
```

**Search for specific text**
```bash
zlrd -s "connection failed" application.log
```

**Filter by date**
```bash
zlrd -d 2024-01-20 application.log
```

**Tail mode (follow in real-time)**
```bash
zlrd -t application.log

# Tail with filters
zlrd -t -l Error -s "database" application.log
```

**Process multiple files**
```bash
zlrd -f app.log error.log -l Error
```

**Show last N lines**
```bash
zlrd -n 100 application.log
```

**Combine filters**
```bash
# Errors from today containing "timeout"
zlrd -l Error -d 2024-01-20 -s timeout application.log
```

## Performance

`zlrd` is optimized for speed and low memory usage:

- Processes logs in a single pass with streaming I/O
- Memory usage stays constant regardless of file size
- No allocations in hot paths
- Efficient string matching and date parsing

## Architecture

`zlrd` follows Zig's philosophy of simplicity and transparency:

- Single-threaded by design
- No hidden allocations or background tasks
- Explicit error handling
- Clear separation between parsing, filtering, and output

## Roadmap

- [ ] Support for compressed logs (gzip, bzip2)
- [ ] Custom log format configuration
- [ ] Regex pattern matching
- [ ] Time range filtering
- [ ] Performance profiling mode
- [ ] Plugin system for custom parsers

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

When contributing:
- Follow Zig's style guide
- Add tests for new features
- Update documentation as needed
- Keep the codebase simple and maintainable

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Built with [Zig](https://ziglang.org/) - a general-purpose programming language designed for robustness, optimality, and maintainability.
