# zlrd

**zlrd** is a high-performance log reader and parser written in **Zig**.

It is designed for fast, predictable, streaming processing of large log files with minimal memory overhead.  
`zlrd` works well both for offline log analysis and real-time log inspection (`tail -f` style).

---

## Features

- ⚡ **High performance**
  - streaming I/O
  - no garbage collector
  - explicit memory management
- 📂 **Large file support**
  - processes logs line-by-line
  - does not load files into memory
  - handles partially written lines correctly
- 🔍 **Flexible filtering**
  - by log level (`Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal`, `Panic`)
  - by search string (case-insensitive)
  - by date and date ranges
- 🧵 **Tail mode**
  - follow log files in real time
- 🧾 **Log formats**
  - JSON logs  
    ```json
    {"level":"error","message":"connection failed"}
    ```
  - Plain-text logs  
    ```text
    [ERROR] connection failed
    ```
- 🎨 **Readable output**
  - colored log levels
  - terminal-friendly formatting
- 🧠 **Simple architecture**
  - no background services
  - no hidden threads
  - minimal dependencies

---
Attention: is not stable yet. Use at your own risk.
