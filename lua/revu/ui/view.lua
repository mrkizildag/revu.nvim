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
local card = require("revu.ui.card")
local anchor_mod = require("revu.anchor")

local M = {}

local NS = vim.api.nvim_create_namespace("revu_diff")
local SYNTAX_NS = vim.api.nvim_create_namespace("revu_syntax")
local COMMENT_NS = vim.api.nvim_create_namespace("revu_comments")

---@type table<integer, { rev: string, root: string, files: revu.File[], collapsed: table<string, boolean>, render: revu.Render, prev_buf: integer|nil }>
local sessions = {}

---@return table|nil session, integer|nil bufnr
local function current()
  local buf = vim.api.nvim_get_current_buf()
  return sessions[buf], buf
end

---Paint one rendered side into a buffer.
---@param buf integer
---@param r revu.Render
local function paint(buf, r)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for _, m in ipairs(r.marks) do
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

  syntax.apply(buf, SYNTAX_NS, r.rows)
end

---Usable text width of the window showing `buf`, or a sensible default.
---@param buf integer
---@return integer
local function text_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return vim.o.columns
  end
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

---Row showing a given source line of a file, or nil.
---@param rows revu.RenderRow[]
---@param path string
---@param side "old"|"new"
---@param line integer
---@return integer|nil
local function row_for(rows, path, side, line)
  for i, row in ipairs(rows) do
    if row.path == path and row.kind ~= "header" then
      local at = (side == "old") and row.old_line or row.new_line
      if at == line then
        return i
      end
    end
  end
  return nil
end

---Draw every comment that still has a home, and collect the ones that do not.
---
---Resolution runs against the working tree, not the diff: a comment follows the code even
---after an agent has edited it, and an orphan is listed separately rather than drawn at a
---line we know is wrong.
---@param buf integer
---@param rows revu.RenderRow[]
---@param s table
local function draw_comments(buf, rows, s)
  vim.api.nvim_buf_clear_namespace(buf, COMMENT_NS, 0, -1)
  s.orphans = {}
  if not s.store then
    return
  end

  local width = text_width(buf)
  local by_row = {}

  local resolved = anchor_mod.resolve_all(s.store:list(), function(path)
    local full = s.root .. "/" .. path
    if not vim.uv.fs_stat(full) then
      return nil
    end
    return vim.fn.readfile(full)
  end)

  for _, a in ipairs(resolved) do
    if a.state == "orphaned" then
      table.insert(s.orphans, a.comment)
    else
      local moved = anchor_mod.applied(a)
      local row = row_for(rows, moved.path, moved.side, moved.line)
      if row then
        by_row[row] = by_row[row] or {}
        table.insert(by_row[row], moved)
      else
        -- Anchored fine, but that line is not part of this diff -- unchanged code, say.
        table.insert(s.orphans, moved)
      end
    end
  end

  for row, comments in pairs(by_row) do
    vim.api.nvim_buf_set_extmark(buf, COMMENT_NS, row - 1, 0, {
      virt_lines = card.stack(comments, width),
    })
  end
end

---@param buf integer
local function draw(buf)
  local s = sessions[buf]
  local r = render.review(s.files, text_width(buf))
  s.render = r
  s.levels = render.fold_levels(r.rows)
  paint(buf, r)
  draw_comments(buf, r.rows, s)
end

---`foldexpr` for the review window. Vim calls this per line with `v:lnum`.
---@return string
function M.foldexpr()
  local s = sessions[vim.api.nvim_get_current_buf()]
  return (s and s.levels and s.levels[vim.v.lnum]) or "0"
end

---`foldtext` for the review window: the pill's bottom border verbatim.
---
---Vim always shows one line for a closed fold, and the fold begins on that border, so a
---closed file reads exactly like a collapsed pill instead of "+-- 42 lines".
---@return string
function M.foldtext()
  return vim.fn.getline(vim.v.foldstart)
end

---Rewrite the chevron on each pill so it matches the fold state.
---
---Only the header text changes and the row count does not, so positions stay valid --
---which is the whole reason for using folds rather than removing rows.
---@param buf integer
local function refresh_chevrons(buf)
  local s = sessions[buf]
  local win = vim.fn.bufwinid(buf)
  if not s or win == -1 then
    return
  end

  local width = vim.api.nvim_win_get_width(win) - (vim.fn.getwininfo(win)[1] or {}).textoff
  vim.bo[buf].modifiable = true

  for i, row in ipairs(s.render.rows) do
    if row.kind == "header" and row.part == "body" then
      local closed = vim.fn.foldclosed(i + 1) ~= -1 -- the fold starts on the row below
      local lines = render.header_lines(s.files[row.file_index], closed, width)
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { lines[2].text })
      vim.api.nvim_buf_clear_namespace(buf, NS, i - 1, i)
      for _, seg in ipairs(lines[2].segments) do
        vim.api.nvim_buf_set_extmark(buf, NS, i - 1, seg.col, {
          end_col = seg.end_col,
          hl_group = seg.hl,
        })
      end
    end
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---Run a native fold command, then bring the chevrons back in step.
---@param cmd string
local function fold_cmd(cmd)
  local buf = vim.api.nvim_get_current_buf()
  if not sessions[buf] then
    return
  end
  pcall(vim.cmd, "normal! " .. cmd)
  refresh_chevrons(buf)
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
  map("zR", function()
    M.toggle_all(true)
  end, "expand every file")
  map("zM", function()
    M.toggle_all(false)
  end, "collapse every file")
  map("]f", function()
    M.jump_file(1)
  end, "next file")
  map("[f", function()
    M.jump_file(-1)
  end, "previous file")
  map("<CR>", M.open_file, "open the real file here")
  map("gf", M.open_file, "open the real file here")
  map("c", M.comment, "comment on this line")
  map("<leader>c", M.comment, "comment on this line")
  map("]c", function()
    M.jump_comment(1)
  end, "next comment")
  map("[c", function()
    M.jump_comment(-1)
  end, "previous comment")
  map("<leader>x", M.toggle_resolved, "toggle resolved")
  map("<leader>d", M.delete_comment, "delete comment")
  map("gm", function()
    M.set_mode()
  end, "toggle unified / split")
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
    buf = buf,
    mode = "unified",
    store = require("revu.store").new(root),
    orphans = {},
    rev = rev,
    root = root,
    files = files,
    prev_buf = vim.api.nvim_buf_is_valid(prev_buf) and prev_buf or nil,
  }

  -- Window first, then draw. The pill is sized to the window's text area, and until the
  -- buffer is actually displayed there is no window to measure -- an earlier draw fell back
  -- to `columns` and overflowed by the width of the sign column.
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  vim.wo.number = false
  -- No gutter: the inline prefix carries add/delete, and an empty sign column would push
  -- the pill two cells right of the markers it is supposed to line up with.
  vim.wo.signcolumn = require("revu.config").options.signs and "yes" or "no"
  vim.wo.wrap = false
  vim.wo.cursorline = true
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'revu.ui.view'.foldexpr()"
  vim.wo.foldtext = "v:lua.require'revu.ui.view'.foldtext()"
  vim.wo.foldlevel = 99
  vim.wo.foldenable = true
  vim.wo.fillchars = "fold: "

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

---Collapse a split back to one window and drop the side buffers.
---
---Both hide() and close() need this: leaving the extra window behind would strand it
---showing a buffer nobody owns.
---@param s table
local function teardown_split(s)
  if s.mode ~= "split" then
    return
  end

  local keep
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if b == s.bufs.old or b == s.bufs.new then
      if keep then
        pcall(vim.api.nvim_win_close, w, true)
      else
        keep = w
      end
    end
  end

  if keep and vim.api.nvim_win_is_valid(keep) then
    vim.api.nvim_set_current_win(keep)
    vim.api.nvim_win_set_buf(keep, s.buf)
  end

  for _, b in pairs(s.bufs or {}) do
    sessions[b] = nil
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  s.bufs = nil
  s.mode = "unified"
end

---Where the cursor is, in terms the other mode also understands.
---@return { path: string, line: integer|nil, side: "old"|"new" }|nil
local function anchor()
  local s = current()
  if not s then
    return nil
  end

  local buf = vim.api.nvim_get_current_buf()
  local rows = (s.mode == "split") and (buf == s.bufs.old and s.split.old.rows or s.split.new.rows)
    or s.render.rows

  local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row or not row.path then
    return nil
  end
  return {
    path = row.path,
    line = row.new_line or row.old_line,
    side = row.new_line and "new" or "old",
  }
end

---Row in `rows` showing the same source line, falling back to the file's pill.
---@param rows revu.RenderRow[]
---@param a { path: string, line: integer|nil, side: string }
---@return integer
local function locate(rows, a)
  local file_start
  for i, row in ipairs(rows) do
    if row.path == a.path then
      file_start = file_start or i
      local line = (a.side == "old") and row.old_line or row.new_line
      if line and line == a.line then
        return i
      end
    end
  end
  return file_start or 1
end

---Swap between unified and split, keeping the cursor on the same source line.
---@param mode "unified"|"split"|nil  nil toggles
function M.set_mode(mode)
  local s = current()
  if not s then
    return
  end

  mode = mode or (s.mode == "split" and "unified" or "split")
  if mode == s.mode then
    return
  end

  local a = anchor()
  local win = vim.api.nvim_get_current_win()

  if mode == "split" then
    -- One vertical split; both halves belong to the same session, so a keymap works from
    -- whichever side the cursor happens to be in.
    s.bufs =
      { old = vim.api.nvim_create_buf(false, true), new = vim.api.nvim_create_buf(false, true) }
    for _, b in pairs(s.bufs) do
      vim.bo[b].buftype = "nofile"
      vim.bo[b].bufhidden = "hide"
      vim.bo[b].swapfile = false
      vim.bo[b].filetype = "revu"
      sessions[b] = s
      set_keymaps(b)
    end

    vim.api.nvim_win_set_buf(win, s.bufs.old)
    vim.cmd("vsplit")
    local right = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right, s.bufs.new)

    s.split = render.split(s.files, text_width(s.bufs.old))
    paint(s.bufs.old, s.split.old)
    paint(s.bufs.new, s.split.new)
    draw_comments(s.bufs.old, s.split.old.rows, s)
    draw_comments(s.bufs.new, s.split.new.rows, s)

    -- Equal row counts on both sides, so binding them cannot drift.
    for w, b in pairs({ [win] = s.bufs.old, [right] = s.bufs.new }) do
      vim.api.nvim_win_call(w, function()
        vim.wo.scrollbind = true
        vim.wo.cursorbind = true
        vim.wo.wrap = false
        vim.wo.number = false
        vim.wo.signcolumn = require("revu.config").options.signs and "yes" or "no"
        vim.wo.cursorline = true
        vim.wo.foldenable = false
      end)
      local _ = b
    end

    s.mode = "split"
    if a then
      pcall(vim.api.nvim_win_set_cursor, right, { locate(s.split.new.rows, a), 0 })
    end
    vim.api.nvim_set_current_win(right)
  else
    teardown_split(s)

    vim.wo.foldenable = true
    draw(s.buf)
    refresh_chevrons(s.buf)
    if a then
      pcall(
        vim.api.nvim_win_set_cursor,
        vim.api.nvim_get_current_win(),
        { locate(s.render.rows, a), 0 }
      )
    end
  end
end

---Rows and side for whichever buffer the cursor is in.
---@param s table
---@return revu.RenderRow[], "old"|"new"
local function rows_here(s)
  if s.mode == "split" then
    local buf = vim.api.nvim_get_current_buf()
    if buf == s.bufs.old then
      return s.split.old.rows, "old"
    end
    return s.split.new.rows, "new"
  end
  return s.render.rows, "new"
end

---Redraw whichever buffers are on screen, keeping the cursor.
---@param s table
local function redraw(s)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)

  if s.mode == "split" then
    draw_comments(s.bufs.old, s.split.old.rows, s)
    draw_comments(s.bufs.new, s.split.new.rows, s)
  else
    draw_comments(s.buf, s.render.rows, s)
  end

  pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

---Comment on the line under the cursor.
function M.comment()
  local s = current()
  if not s then
    return
  end

  local rows = rows_here(s)
  local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row or row.kind == "header" or row.kind == "filler" then
    vim.notify("revu: nothing to comment on here", vim.log.levels.WARN)
    return
  end

  local side = row.new_line and "new" or "old"
  local line = row.new_line or row.old_line
  if not line then
    return
  end

  -- Anchor against the working tree, which is what re-anchoring will compare to later --
  -- not against the diff row, whose text can be a deletion that no longer exists.
  local full = s.root .. "/" .. row.path
  local file = vim.uv.fs_stat(full) and vim.fn.readfile(full) or {}
  local text = file[line] or ""

  local context = {}
  for i = math.max(line - 2, 1), math.min(line + 2, #file) do
    if i ~= line then
      table.insert(context, file[i])
    end
  end

  require("revu.ui.compose").open({ title = ("%s:%d"):format(row.path, line) }, function(body)
    local _, err = s.store:add({
      path = row.path,
      side = side,
      line = line,
      anchor = text,
      context = context,
      body = body,
    })
    if err then
      vim.notify("revu: " .. err, vim.log.levels.ERROR)
      return
    end
    redraw(s)
  end)
end

---Comments anchored to the row under the cursor.
---@param s table
---@return revu.Comment[]
local function comments_here(s)
  local rows = rows_here(s)
  local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row or not row.path then
    return {}
  end

  local side = row.new_line and "new" or "old"
  local line = row.new_line or row.old_line
  local out = {}
  for _, c in ipairs(s.store and s.store:list({ path = row.path, side = side }) or {}) do
    if c.line == line then
      table.insert(out, c)
    end
  end
  return out
end

---Flip open/resolved on the comment under the cursor.
function M.toggle_resolved()
  local s = current()
  if not s then
    return
  end

  local here = comments_here(s)
  if #here == 0 then
    vim.notify("revu: no comment on this line", vim.log.levels.WARN)
    return
  end

  for _, c in ipairs(here) do
    s.store:update(c.id, { status = c.status == "resolved" and "open" or "resolved" })
  end
  redraw(s)
end

---Delete the comment under the cursor.
function M.delete_comment()
  local s = current()
  if not s then
    return
  end

  local here = comments_here(s)
  if #here == 0 then
    return
  end

  for _, c in ipairs(here) do
    s.store:remove(c.id)
  end
  redraw(s)
end

---Move to the next or previous commented row.
---@param delta integer
function M.jump_comment(delta)
  local s = current()
  if not s then
    return
  end

  local rows = rows_here(s)
  local marked = {}
  for _, c in ipairs(s.store and s.store:list() or {}) do
    local row = row_for(rows, c.path, c.side, c.line)
    if row then
      marked[row] = true
    end
  end

  local sorted = vim.tbl_keys(marked)
  table.sort(sorted)
  if #sorted == 0 then
    vim.notify("revu: no comments", vim.log.levels.INFO)
    return
  end

  local at = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if delta > 0 then
    for _, r in ipairs(sorted) do
      if r > at then
        target = r
        break
      end
    end
    target = target or sorted[1]
  else
    for i = #sorted, 1, -1 do
      if sorted[i] < at then
        target = sorted[i]
        break
      end
    end
    target = target or sorted[#sorted]
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
end

---Comments that no longer have a home in the working tree.
---@return revu.Comment[]
function M.orphans()
  local s = current()
  return s and s.orphans or {}
end

---Fold or unfold the file section the cursor is in.
function M.toggle()
  local s, buf = current()
  if not s then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = s.render.rows[row]
  if not entry or not entry.file_index then
    return
  end

  -- The fold begins on the pill's bottom border, so aim there wherever the cursor is.
  local header = render.header_row(s.render, entry.file_index)
  local start = header and header + 1 or row
  local closed = vim.fn.foldclosed(start) ~= -1

  pcall(vim.cmd, ("%d%s"):format(start, closed and "foldopen" or "foldclose"))
  refresh_chevrons(buf)

  if header then
    pcall(vim.api.nvim_win_set_cursor, 0, { header, 0 })
  end
end

---Open or close every file at once.
---@param open boolean
function M.toggle_all(open)
  fold_cmd(open and "zR" or "zM")
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

  teardown_split(s)

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

  teardown_split(s)

  sessions[s.buf] = nil
  sessions[buf] = nil
  if s.prev_buf and vim.api.nvim_buf_is_valid(s.prev_buf) then
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), s.prev_buf)
  else
    vim.cmd("enew")
  end
  pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
end

---Current session, for tests and modules built on this.
---@return table|nil
function M.session()
  return (current())
end

return M
