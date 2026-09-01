# revu.nvim

In-editor diff review with comments an AI agent can read.

Review a diff without leaving Neovim, annotate lines the way you would on a GitHub PR, and
hand the result to Claude Code or Codex as a file it can act on.

> **Status: in progress.** The diff model, comment store, re-anchoring and the unified diff
> view are in. Comments are not rendered in the view yet. Tracking issue:
> [#1](https://github.com/mrkizildag/revu.nvim/issues/1).

## Usage

```lua
{ "mrkizildag/revu.nvim", opts = {} }
```

| Command | Does |
| --- | --- |
| `:Revu [rev]` | Review changes against `rev` (default `HEAD`; try `main...HEAD`) |
| `:RevuNext` / `:RevuPrev` | Cycle changed files |
| `:RevuClose` | Close the review tab |

## Planned

- Split (`old | new`) and unified diff views, toggleable like GitHub's
- Line-anchored comments rendered inline as cards
- `.revu/comments.json` as the source of truth, `.revu/comments.md` regenerated for the agent
- A keybind to copy the markdown path to the clipboard
- Comments re-anchor by content after the agent edits, rather than pointing at stale lines

## Requirements

Neovim >= 0.10 (`vim.system`). Developed on 0.12.

## Development

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), resolved from a local
lazy.nvim install:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
```

`-u` is needed on the parent process too, not just the child test runners — without it
plenary is missing from the parent's `rtp` and `PlenaryBustedDirectory` is an unknown
command, which hangs instead of failing.
