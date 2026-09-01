-- Window and buffer lifecycle for the unified diff view.
--
-- One tabpage per review session, one scratch buffer per file. State is keyed by tabpage
-- so several reviews (different revisions, say) can be open at once without colliding.

local diff = require("revu.diff")
local git = require("revu.git")
local render = require("revu.ui.render")

local M = {}

local NS = vim.api.nvim_create_namespace("revu_diff")

---@type table<integer, { rev: string, cwd: string, files: revu.File[], index: integer, bufs: table<integer, integer>, render: revu.Render }>
local sessions = {}

---@param path string
---@return string
local function filetype_for(path)
  return vim.filetype.match({ filename = path }) or ""
end

---@param file revu.File
---@param rev string
---@return integer bufnr, revu.Render
local function build_buffer(file, rev)
  local r = render.unified(file)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if not r.binary then
    -- Interleaved add/delete lines are not always syntactically valid, so treesitter may
    -- produce an imperfect tree here. It still highlights the overwhelming majority of
    -- tokens correctly, which beats no highlighting at all.
    vim.bo[buf].filetype = filetype_for(file.path)
  end

  pcall(vim.api.nvim_buf_set_name, buf, ("revu://%s/%s"):format(rev, file.path))

  for _, m in ipairs(r.marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, m.row, 0, {
      line_hl_group = m.line_hl,
      sign_text = m.sign_text,
      sign_hl_group = m.sign_hl,
      -- Inline rather than buffer text: the +/- shows but is not selectable or yankable,
      -- and buffer columns still line up with the real source.
      virt_text = m.prefix_text and { { m.prefix_text, m.prefix_hl } } or nil,
      virt_text_pos = m.prefix_text and "inline" or nil,
    })
  end

  for _, v in ipairs(r.virt) do
    -- `virt_lines_above` on the row the hunk starts at, so the header sits above it
    -- without occupying a real line.
    vim.api.nvim_buf_set_extmark(buf, NS, v.row, 0, {
      virt_lines = { { { v.text, v.hl } } },
      virt_lines_above = true,
    })
  end

  return buf, r
end

---@param tab integer
local function show(tab, index)
  local s = sessions[tab]
  if not s or not s.files[index] then
    return
  end
  s.index = index

  local file = s.files[index]
  local buf = s.bufs[index]
  local r
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf, r = build_buffer(file, s.rev)
    s.bufs[index] = buf
  end

  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  if r then
    s.render = r
  end

  vim.wo.number = true
  vim.wo.signcolumn = "yes"
  vim.wo.wrap = false

  vim.api.nvim_echo({
    { ("revu  %s  "):format(s.rev), "Comment" },
    { ("[%d/%d] "):format(index, #s.files), "Title" },
    { file.path, "Normal" },
  }, false, {})
end

---Open a review of `rev` in a new tabpage.
---@param rev string|nil
---@param cwd string|nil
---@return boolean ok, string|nil err
function M.open(rev, cwd)
  cwd = cwd or vim.uv.cwd()
  rev = rev or require("revu.config").options.rev

  local root, root_err = git.root(cwd)
  if not root then
    return false, root_err or "not a git repository"
  end

  local raw, diff_err = git.diff(rev, root, { untracked = require("revu.config").options.untracked })
  if not raw then
    return false, diff_err
  end

  local files = diff.parse(raw)
  if #files == 0 then
    return false, ("no changes against %s"):format(rev)
  end

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  sessions[tab] = { rev = rev, cwd = root, files = files, index = 1, bufs = {} }

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("revu-session-" .. tab, { clear = true }),
    callback = function()
      -- Buffers are bufhidden=wipe, so they go with the tab; drop our reference too.
      sessions[tab] = nil
    end,
  })

  show(tab, 1)
  return true, nil
end

---@return boolean
function M.is_open()
  return sessions[vim.api.nvim_get_current_tabpage()] ~= nil
end

---Cycle files. Small on purpose -- the picker in #8 is the real navigation.
---@param delta integer
function M.cycle(delta)
  local tab = vim.api.nvim_get_current_tabpage()
  local s = sessions[tab]
  if not s then
    return
  end
  local next_index = ((s.index - 1 + delta) % #s.files) + 1
  show(tab, next_index)
end

function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  if not sessions[tab] then
    return
  end
  sessions[tab] = nil
  vim.cmd("tabclose")
end

---Current session, for tests and for the modules that build on this.
---@return table|nil
function M.session()
  return sessions[vim.api.nvim_get_current_tabpage()]
end

return M
