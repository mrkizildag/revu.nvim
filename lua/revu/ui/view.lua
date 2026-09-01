-- The review buffer: every changed file in one scrolling buffer, each behind a header row
-- that folds its section shut.
--
-- Opens in the window you are already in rather than a new tab. The previous buffer is
-- remembered and restored on close, so review is a mode you enter and leave rather than a
-- place you navigate to.

local diff = require("revu.diff")
local git = require("revu.git")
local render = require("revu.ui.render")

local M = {}

local NS = vim.api.nvim_create_namespace("revu_diff")

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
  local r = render.review(s.files, s.collapsed)
  s.render = r

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for _, m in ipairs(r.marks) do
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
  map("q", M.close, "close review")
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
    return false, ("no changes against %s"):format(rev)
  end

  local prev_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "revu"

  sessions[buf] = {
    rev = rev,
    root = root,
    files = files,
    collapsed = {},
    prev_buf = vim.api.nvim_buf_is_valid(prev_buf) and prev_buf or nil,
  }

  draw(buf)
  set_keymaps(buf)

  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  vim.wo.number = false
  vim.wo.signcolumn = "yes"
  vim.wo.wrap = false
  vim.wo.cursorline = true

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

---Close the review and put back whatever buffer was there before.
function M.close()
  local s, buf = current()
  if not s then
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
