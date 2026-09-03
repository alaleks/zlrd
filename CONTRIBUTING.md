# Contributing to zlrd

Bug reports and pull requests are welcome.

## Before your first pull request

Sign the [Contributor License Agreement](CLA.md). A bot comments on your first
pull request with the one line to reply with; it takes a few seconds and is
asked only once.

## Building and testing

Requires Zig **0.16.0** or later. No other toolchain, no package manager.

```bash
zig build                 # both binaries into zig-out/bin
zig build test            # the whole suite — must be green
zig fmt src/              # formatting is not negotiable
```

Cross-compile the release matrix before you push. A host-only build hides
platform regressions that CI will find hours later — dead code that only
Linux reaches, and ABI mismatches that only Windows reaches:

```bash
for t in x86_64-linux-musl aarch64-linux-musl x86_64-windows-gnu \
         x86_64-macos aarch64-macos; do
  zig build -Dtarget=$t -Doptimize=ReleaseFast || echo "FAILED: $t"
done
```

## House style

The rules that actually get pull requests sent back:

- **Standard library only.** No C dependencies, no vendored code, no package
  manager. Every format the reader understands — gzip, LZ4, the systemd
  journal, protobuf — is implemented here against `std`. This is the Project's
  main constraint and it is not up for negotiation in a pull request.
- **No hidden allocations.** The read path allocates once at start-up and then
  reuses buffers. If a new feature needs memory per line, it needs a different
  design.
- **Explicit error handling.** No `catch unreachable` on anything a malformed
  file can reach.
- **Comments explain why, not what.** The code says what it does. A comment
  earns its place by recording the reason a non-obvious choice was made —
  usually the bug that made the obvious version wrong. Read a few in
  `src/reader/jsonx.zig` for the register.
- **Tests live next to the code** they cover, in the same file, and every new
  behaviour ships with one.
- **One feature, one directory** under `src/`.

## Commits

One short subject line, `type(scope): summary`, present tense. The detail
belongs in a comment at the code it explains, where it stays accurate.

## Reporting a bug

Include the input that triggers it. For a reader bug that means the log line
itself — the exact bytes, escapes and all. For an agent bug, the command line
you ran. A line that "looks like" the real one usually reproduces something
different from the line that actually broke.
