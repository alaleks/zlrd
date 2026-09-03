# Demo recording for the README, driven by VHS (github.com/charmbracelet/vhs).
#
#   brew install vhs
#   cd demo && ./make-fixture.sh && vhs demo.tape
#
# Run it from this directory. `Output` below is resolved against the working
# directory, not against the tape, so recording from anywhere else drops the
# GIF outside the repository — which is exactly how the committed one drifted
# out of date without anybody noticing.
#
# The tape is committed rather than only the GIF so the demo can be
# regenerated when the output changes, instead of quietly drifting out of date
# the way a hand-recorded one does.
#
# Every frame reads a fixture sized to fit one screen. Piping to `head` would
# be the obvious way to bound the output, but it also takes stdout away from
# the terminal, and zlrd then correctly drops colour and JSON expansion — the
# two things the recording exists to show.

Output ../.github/demo.gif

Set FontSize 18
Set Width 1200
Set Height 780
Set Padding 24
Set Theme "Builtin Dark"
Set TypingSpeed 40ms

Hide
Type "clear"
Enter
Show

# ── 1. What a log looks like with no help ────────────────────────────────
# The contrast with the next frame is the whole pitch, so lead with the raw
# file. Three formats in one file is the normal case, not a contrived one.
Type "cat sample.log"
Enter
Sleep 3s

Type "clear"
Enter
Sleep 400ms

# ── 2. The same twelve lines, read by zlrd ───────────────────────────────
# Levels highlighted, JSON inside the message expanded into its own block.
Type "zlrd sample.log"
Enter
Sleep 5s

Type "clear"
Enter
Sleep 400ms

# ── 3. Filtering by level across all three formats ───────────────────────
# grep would find only the JSON error here; the bracketed and logfmt ones
# are invisible to it. Seeing all three in the output is the point.
Type "zlrd -l error sample.log"
Enter
Sleep 4s

Type "clear"
Enter
Sleep 400ms

# ── 4. Ten thousand lines collapsed into what actually happened ──────────
Type "zlrd -a -m normalized repeat.log"
Enter
Sleep 5s
