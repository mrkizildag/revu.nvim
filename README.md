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
| `:RevuNext` / `:RevuPrev` | Jump to the next / previous file header |
| `:RevuSplit` / `:RevuUnified` | Switch view mode |
| `:RevuHide` | Hide the review, keeping it to return to |
| `:RevuClose` | Close the review and discard it |

Every changed file lands in **one scrolling buffer**, opened in the window you are already
in. Inside it:

| Key | Does |
| --- | --- |
| `<Tab>` / `za` | Fold the file section under the cursor |
| `zR` / `zM` | Expand / collapse every file |
| `gm` | Toggle unified / split (old │ new) |
| `]f` / `[f` | Next / previous file |
| `<CR>` / `gf` | Open the real file at this line |
| `q` | Hide the review (`:RevuClose` discards it) |

Split mode renders the *same* parsed diff into two aligned columns, old on the left and new
on the right. Both sides get exactly the same number of rows — a deletion pads the new side,
an addition pads the old — so `scrollbind` cannot drift no matter how the files differ in
size. Switching modes keeps the cursor on the same source line.

Folding uses real vim folds, so every row still exists when a file is collapsed and stored
positions stay valid — `zo`, `zc`, `zj`, `zk` and friends all work, and a closed file draws
its own pill border rather than `+-- 42 lines`.

The review buffer stays alive when you leave it, so `<CR>` into a file, read around, and
`<C-o>` brings you back to the row you left. `:Revu` again returns to the same review
rather than rebuilding it.

`+` and `-` are drawn in the **sign column**, the way gitsigns marks hunks. The gutter is
outside the text area, so the cursor never travels through them, an empty added line stays
genuinely empty, and yanking gives back real code rather than diff punctuation. Set
`prefix = { add = "+ ", delete = "- ", context = "  " }` to draw them inline instead.

## Planned

- Split (`old | new`) and unified diff views, toggleable like GitHub's
- Line-anchored comments rendered inline as cards
- `.revu/comments.json` as the source of truth, `.revu/comments.md` regenerated for the agent
- A keybind to copy the markdown path to the clipboard
- Comments re-anchor by content after the agent edits, rather than pointing at stale lines

## Requirements

Neovim >= 0.10 (`vim.system`). Developed on 0.12.

## Development

```bash
make          # format check, lint, tests -- the same three CI runs
make test
make lint     # luacheck
make format   # stylua, in place
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), cloned into `.tests/` by
the Makefile. `-u` is needed on the parent nvim process as well as the child test runners —
without it plenary is missing from the parent's `rtp` and `PlenaryBustedDirectory` is an
unknown command, which hangs instead of failing.

`stylua` is pinned to the same version in CI as the one you run locally; a newer one can
reformat code the older accepts and fail CI on a diff you cannot reproduce.
