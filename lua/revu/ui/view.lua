-- The review buffer: every changed file in one scrolling buffer, each behind a header row
-- that folds its section shut.
--
-- Opens in the window you are already in rather than a new tab. The previous buffer is
-- remembered and restored on close, so review is a mode you enter and leave rather than a
-- place you navigate to.

local diff = require("revu.diff")
local git = require("revu.git")
local render = require("revu.ui.render")
local syntax = require("revu.ui.syntax")

local M = {}

local NS = vim.api.nvim_create_namespace("revu_diff")
local SYNTAX_NS = vim.api.nvim_create_namespace("revu_syntax")

---@type table<integer, { rev: string, root: string, files: revu.File[], collapsed: table<string, boolean>, render: revu.Render, prev_buf: integer|nil }>
local sessions = {}

---@return table|nil session, integer|nil bufnr
local function current()
  local buf = vim.api.nvim_get_current_buf()
  return sessions[buf], buf
end

---@param buf integer
local function draw(buf)
  local s = sessions[buf]
  -- Size to the TEXT area, not the window: `textoff` is exactly the columns taken by the
  -- sign, number and fold columns, and a pill sized to the full window overflows by that
  -- much and wraps off the right edge.
  local win = vim.fn.bufwinid(buf)
  local width = vim.o.columns
  if win ~= -1 then
    local info = vim.fn.getwininfo(win)[1]
    width = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
  end
  local r = render.review(s.files, s.collapsed, width)
  s.render = r

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for _, m in ipairs(r.marks) do
    -- Header pills colour several ranges on one line: border, dimmed directory, filename,
    -- then the counts in green and red.
    for _, seg in ipairs(m.segments or {}) do
      vim.api.nvim_buf_set_extmark(buf, NS, m.row, seg.col, {
        end_col = seg.end_col,
        hl_group = seg.hl,
      })
    end

    vim.api.nvim_buf_set_extmark(buf, NS, m.row, 0, {
      line_hl_group = m.line_hl,
      sign_text = m.sign_text,
      sign_hl_group = m.sign_hl,
      -- Inline, so +/- shows but is not selectable and buffer columns still match source.
      virt_text = m.prefix_text and { { m.prefix_text, m.prefix_hl } } or nil,
      virt_text_pos = m.prefix_text and "inline" or nil,
    })
  end

  for _, v in ipairs(r.virt) do
    vim.api.nvim_buf_set_extmark(buf, NS, v.row, 0, {
      virt_lines = { { { v.text, v.hl } } },
      virt_lines_above = true,
    })
  end

  -- Separate namespace so a redraw can rebuild syntax without disturbing the diff marks.
  syntax.apply(buf, SYNTAX_NS, r.rows)
end

---Keep the cursor off pill borders.
---
---Done on CursorMoved rather than by remapping motions: one handler covers j, k, }, G,
---search and the mouse, where remapping would have to cover each of them and still miss
---whatever it forgot. The direction of travel decides which way to skip, so moving down
---onto a border continues down and moving up continues up.
---@param buf integer
local function skip_borders(buf)
  local s = sessions[buf]
  local win = vim.fn.bufwinid(buf)
  if not s or win == -1 then
    return
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  if render.is_landable(s.render.rows[row]) then
    s.last_row = row
    return
  end

  local dir = (s.last_row and row < s.last_row) and -1 or 1
  local target = render.next_landable(s.render.rows, row, dir)
  if target then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    s.last_row = target
  end
end

---@param buf integer
local function set_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "revu: " .. desc, nowait = true })
  end

  map("<Tab>", M.toggle, "toggle file section")
  map("za", M.toggle, "toggle file section")
  map("]f", function()
    M.jump_file(1)
  end, "next file")
  map("[f", function()
    M.jump_file(-1)
  end, "previous file")
  map("<CR>", M.open_file, "open the real file here")
  map("gf", M.open_file, "open the real file here")
  map("q", M.hide, "hide the review (:RevuClose to discard it)")
end

---An existing session for the same repo and revision, if one is still alive.
---@param root string
---@param rev string
---@return integer|nil bufnr
local function existing(root, rev)
  for buf, s in pairs(sessions) do
    if vim.api.nvim_buf_is_valid(buf) then
      if s.root == root and s.rev == rev then
        return buf
      end
    else
      sessions[buf] = nil
    end
  end
  return nil
end

---Open a review of `rev` in the current window.
---@param rev string|nil
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.open(rev, cwd)
  local config = require("revu.config")
  cwd = cwd or vim.uv.cwd()
  rev = rev or config.options.rev

  local root, root_err = git.root(cwd)
  if not root then
    return false, root_err or "not a git repository"
  end

  local raw, diff_err = git.diff(rev, root, { untracked = config.options.untracked })
  if not raw then
    return false, diff_err
  end

  local files = diff.parse(raw)
  if #files == 0 then
    -- A clean working tree is the common case right after committing, and the useful next
    -- question is almost always "what did I just do on this branch?" -- so say how to ask
    -- it rather than leaving a dead end.
    local hint = ""
    if git.compares_worktree(rev) then
      local base = git.default_base(root)
      if base then
        local ahead = git.diff(("%s...HEAD"):format(base), root, { untracked = false })
        if ahead and ahead ~= "" then
          hint = (" — the working tree is clean; try `:Revu %s...HEAD` to review the branch"):format(
            base
          )
        end
      end
    end
    return false, ("no changes against %s%s"):format(rev, hint)
  end

  local prev_buf = vim.api.nvim_get_current_buf()

  -- Same repo and revision as a review that is merely hidden: show that one again rather
  -- than building a second, so its cursor and fold state survive.
  local alive = existing(root, rev)
  if alive and alive ~= prev_buf then
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), alive)
    local row = sessions[alive].last_row
    if row then
      pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { row, 0 })
    end
    return true, nil
  end

  local buf = vim.api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  -- `hide`, not `wipe`. Wiping destroyed the review the instant anything replaced it in
  -- the window, so <C-o> jumped back to a buffer that no longer existed and landed on an
  -- empty one. :RevuClose deletes it explicitly instead.
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "revu"

  sessions[buf] = {
    rev = rev,
    root = root,
    files = files,
    collapsed = {},
    prev_buf = vim.api.nvim_buf_is_valid(prev_buf) and prev_buf or nil,
  }

  -- Window first, then draw. The pill is sized to the window's text area, and until the
  -- buffer is actually displayed there is no window to measure -- an earlier draw fell back
  -- to `columns` and overflowed by the width of the sign column.
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  vim.wo.number = false
  vim.wo.signcolumn = "yes"
  vim.wo.wrap = false
  vim.wo.cursorline = true

  draw(buf)
  set_keymaps(buf)

  -- Start on the first pill's content row rather than its top border.
  local first = render.header_row(sessions[buf].render, 1)
  if first then
    pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { first, 0 })
    sessions[buf].last_row = first
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("revu-cursor-" .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      skip_borders(buf)
    end,
  })

  -- Pills are sized to the window, so they have to be rebuilt when it changes.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = vim.api.nvim_create_augroup("revu-resize-" .. buf, { clear = true }),
    callback = function()
      if not sessions[buf] or not vim.api.nvim_buf_is_valid(buf) then
        return true -- delete the autocmd
      end
      local win = vim.fn.bufwinid(buf)
      local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
      draw(buf)
      if cursor then
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
      end
    end,
  })

  return true, nil
end

---Fold or unfold the file section the cursor is in.
function M.toggle()
  local s, buf = current()
  if not s then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = s.render.rows[row]
  if not entry or not entry.path then
    return
  end

  s.collapsed[entry.path] = not s.collapsed[entry.path]
  draw(buf)

  -- Land back on the header of the file just toggled, so repeated toggles stay put rather
  -- than drifting as the section above changes height.
  local header = render.header_row(s.render, entry.file_index)
  if header then
    vim.api.nvim_win_set_cursor(0, { header, 0 })
  end
end

---Move to the next or previous file header.
---@param delta integer
function M.jump_file(delta)
  local s = current()
  if not s then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local here = s.render.rows[row]
  local index = here and here.file_index or 1
  local target = index + delta

  if target < 1 then
    target = #s.files
  elseif target > #s.files then
    target = 1
  end

  local header = render.header_row(s.render, target)
  if header then
    vim.api.nvim_win_set_cursor(0, { header, 0 })
  end
end

---Open the real file at the line under the cursor, replacing the review.
function M.open_file()
  local s = current()
  if not s then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = s.render.rows[row]
  if not entry or not entry.path then
    return
  end

  local line = render.source_line(s.render, row)
  local path = s.root .. "/" .. entry.path

  if vim.uv.fs_stat(path) then
    -- `m'` records the current position in the jumplist; :edit does not do this on its
    -- own, and without it <C-o> has nothing in the review to come back to.
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(path))
    if line then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
      vim.cmd("normal! zz")
    end
  else
    vim.notify(
      ("revu: %s does not exist in the working tree"):format(entry.path),
      vim.log.levels.WARN
    )
  end
end

---@return boolean
function M.is_open()
  return current() ~= nil
end

---Put back the previous buffer but keep the review alive, so <C-o> and :Revu can return
---to it with its cursor and fold state intact.
function M.hide()
  local s = current()
  if not s then
    return
  end

  local win = vim.api.nvim_get_current_win()
  s.last_row = vim.api.nvim_win_get_cursor(win)[1]
  vim.cmd("normal! m'")

  if s.prev_buf and vim.api.nvim_buf_is_valid(s.prev_buf) then
    vim.api.nvim_win_set_buf(win, s.prev_buf)
  else
    vim.cmd("enew")
  end
end

---Close the review for good: restore the previous buffer and delete this one.
function M.close()
  local s, buf = current()
  if not s then
    -- May be called while the review is hidden, in which case there is no current session
    -- to work from; tear down every session instead.
    for b in pairs(sessions) do
      sessions[b] = nil
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    return
  end

  sessions[buf] = nil
  if s.prev_buf and vim.api.nvim_buf_is_valid(s.prev_buf) then
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), s.prev_buf)
  else
    vim.cmd("enew")
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Current session, for tests and modules built on this.
---@return table|nil
function M.session()
  return (current())
end

return M
