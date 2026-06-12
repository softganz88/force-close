# Demo recording

Regenerates `docs/tui-demo.gif` (the TUI demo shown in the main README).

```bash
.demo/record-tui.sh   # records a real TUI session → .demo/tui.cast
.demo/build-gif.sh    # trims the cast and renders → docs/tui-demo.gif
```

Requires `asciinema`, [`agg`](https://github.com/asciinema/agg), `tmux`, `zenity`,
`wmctrl`, and an X11 display.

## Safety

`record-tui.sh` only ever terminates a throwaway `zenity` window it spawns
itself, titled with a unique per-run marker. Before sending the terminate
keystroke it reads the live TUI frame to find that window's row, and before
sending `y` it captures the confirm prompt and **aborts unless the prompt names
the marker**. It never blind-confirms and never targets a real application. The
session runs in its own `tmux` instance, isolated from your shell.

The target is spawned as a plain background job (not `setsid`): a `setsid`
process becomes its own session leader (`pid == sid`), which force-close's
session-leader guard correctly refuses to terminate.
