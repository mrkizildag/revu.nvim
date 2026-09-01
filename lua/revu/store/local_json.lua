-- File-backed comment store: `.revu/comments.json` is the source of truth,
-- `.revu/comments.md` is regenerated from it on every write.
--
-- Implements the revu.Store interface (see store/init.lua). The UI only ever talks to
-- that interface, so a future backend that speaks to a daemon can replace this without
-- touching a render path.

local markdown = require("revu.markdown")

local M = {}

local Store = {}
Store.__index = Store

local SIDES = { old = true, new = true }
local STATUSES = { open = true, resolved = true }

-- Monotonic within a process; hrtime alone could repeat if two adds land in the same
-- nanosecond, which is unlikely but free to rule out.
local seq = 0
local function new_id()
  seq = seq + 1
  return ("c%x%02x"):format(vim.uv.hrtime(), seq % 256)
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---@param path string
---@return string|nil contents  nil when the file does not exist
local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

---@return boolean ok, string|nil err
local function write_file(path, contents)
  local fd, open_err = vim.uv.fs_open(path, "w", 420)
  if not fd then
    return false, tostring(open_err)
  end
  local ok, write_err = pcall(vim.uv.fs_write, fd, contents, 0)
  vim.uv.fs_close(fd)
  if not ok then
    return false, tostring(write_err)
  end
  return true, nil
end

---Append `.revu/` to .git/info/exclude, exactly once.
---
---Chosen over .gitignore so the plugin never modifies a tracked file in the repo under
---review: nothing shows in `git status` and nothing can land in a PR diff.
---@param root string
---@return boolean ok, string|nil err
local function ensure_git_exclude(root)
  local info = root .. "/.git/info"
  if not vim.uv.fs_stat(root .. "/.git") then
    -- Not a git repo (or a worktree file rather than a dir); nothing to exclude into.
    return true, nil
  end
  vim.fn.mkdir(info, "p")

  local path = info .. "/exclude"
  local contents = read_file(path) or ""
  for line in contents:gmatch("[^\n]+") do
    if line:gsub("%s+$", "") == ".revu/" then
      return true, nil
    end
  end

  local prefix = (contents == "" or contents:sub(-1) == "\n") and "" or "\n"
  return write_file(path, contents .. prefix .. ".revu/\n")
end

---@param c table
---@return string|nil err
local function validate(c)
  if type(c.path) ~= "string" or c.path == "" then
    return "comment.path must be a non-empty string"
  end
  if type(c.line) ~= "number" or c.line < 1 or c.line % 1 ~= 0 then
    return "comment.line must be a positive integer"
  end
  if type(c.body) ~= "string" or c.body:gsub("%s", "") == "" then
    return "comment.body must be a non-empty string"
  end
  if c.side ~= nil and not SIDES[c.side] then
    return "comment.side must be 'old' or 'new'"
  end
  if c.status ~= nil and not STATUSES[c.status] then
    return "comment.status must be 'open' or 'resolved'"
  end
  return nil
end

--- Create a store rooted at a repository.
---@param root string  absolute path to the repo root
---@return revu.Store
function M.new(root)
  local self = setmetatable({
    root = root,
    dir = root .. "/.revu",
    json_path = root .. "/.revu/comments.json",
    md_path = root .. "/.revu/comments.md",
    _comments = {},
    _listeners = {},
    _loaded = false,
  }, Store)
  return self
end

---Load from disk. A missing file is an empty store and not an error; a corrupt one is an
---empty store AND an error, so the caller can warn without the plugin failing to start.
---@return boolean ok, string|nil err
function Store:load()
  self._loaded = true
  self._comments = {}

  local raw = read_file(self.json_path)
  if not raw or raw:gsub("%s", "") == "" then
    return true, nil
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return false, ("could not parse %s: %s"):format(self.json_path, tostring(decoded))
  end

  for _, c in ipairs(decoded) do
    if type(c) == "table" and not validate(c) then
      table.insert(self._comments, c)
    end
  end
  return true, nil
end

---@return boolean ok, string|nil err
function Store:save()
  vim.fn.mkdir(self.dir, "p")

  local ok, err = ensure_git_exclude(self.root)
  if not ok then
    return false, err
  end

  ok, err = write_file(self.json_path, vim.json.encode(self._comments))
  if not ok then
    return false, err
  end

  -- Regenerated wholesale rather than patched: the JSON is the only thing that has to be
  -- correct, so the Markdown can never drift from it.
  ok, err = write_file(self.md_path, markdown.render(self._comments))
  if not ok then
    return false, err
  end

  for _, cb in ipairs(self._listeners) do
    pcall(cb)
  end
  return true, nil
end

function Store:_ensure_loaded()
  if not self._loaded then
    self:load()
  end
end

---@param opts? { path?: string, side?: string, status?: string }
---@return revu.Comment[]
function Store:list(opts)
  self:_ensure_loaded()
  opts = opts or {}
  local out = {}
  for _, c in ipairs(self._comments) do
    local keep = (not opts.path or c.path == opts.path)
      and (not opts.side or c.side == opts.side)
      and (not opts.status or c.status == opts.status)
    if keep then
      table.insert(out, c)
    end
  end
  return out
end

---@param id string
---@return revu.Comment|nil
function Store:get(id)
  self:_ensure_loaded()
  for _, c in ipairs(self._comments) do
    if c.id == id then
      return c
    end
  end
  return nil
end

---@param comment table
---@return revu.Comment|nil, string|nil err
function Store:add(comment)
  self:_ensure_loaded()

  local err = validate(comment)
  if err then
    return nil, err
  end

  local c = vim.tbl_extend("keep", vim.deepcopy(comment), {
    id = new_id(),
    side = "new",
    status = "open",
    context = {},
    anchor = "",
    created_at = now_iso(),
  })

  table.insert(self._comments, c)
  local ok, save_err = self:save()
  if not ok then
    table.remove(self._comments)
    return nil, save_err
  end
  return c, nil
end

---@param id string
---@param patch table
---@return revu.Comment|nil, string|nil err
function Store:update(id, patch)
  self:_ensure_loaded()

  for i, c in ipairs(self._comments) do
    if c.id == id then
      local merged = vim.tbl_extend("force", vim.deepcopy(c), patch)
      merged.id = c.id -- ids are not reassignable
      local err = validate(merged)
      if err then
        return nil, err
      end
      self._comments[i] = merged
      local ok, save_err = self:save()
      if not ok then
        self._comments[i] = c
        return nil, save_err
      end
      return merged, nil
    end
  end
  return nil, ("no comment with id %s"):format(id)
end

---@param id string
---@return boolean removed, string|nil err
function Store:remove(id)
  self:_ensure_loaded()

  for i, c in ipairs(self._comments) do
    if c.id == id then
      table.remove(self._comments, i)
      local ok, err = self:save()
      if not ok then
        table.insert(self._comments, i, c)
        return false, err
      end
      return true, nil
    end
  end
  return false, ("no comment with id %s"):format(id)
end

---Subscribe to writes. A local store fires on save; a remote backend would also fire when
---a peer changes something, which is why the UI must subscribe rather than poll.
---@param cb fun()
function Store:on_change(cb)
  table.insert(self._listeners, cb)
end

return M
