-- Thin wrapper over the git CLI. Everything here returns plain data; no UI, no state.
--
-- Errors are returned, never thrown or notified: callers decide how loud to be, and the
-- test suite can assert on them.

local M = {}

---@param args string[]
---@param cwd string
---@param ok_codes integer[]|nil  exit codes to treat as success besides 0
---@return string|nil stdout, string|nil err
local function run(args, cwd, ok_codes)
  local cmd = { "git" }
  vim.list_extend(cmd, args)

  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true }):wait()
  end)

  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 and not vim.tbl_contains(ok_codes or {}, res.code) then
    local err = (res.stderr or ""):gsub("%s+$", "")
    return nil, err ~= "" and err or ("git " .. table.concat(args, " ") .. " exited " .. res.code)
  end

  return res.stdout or "", nil
end

---Absolute path of the repo root containing `cwd`.
---@param cwd string
---@return string|nil root, string|nil err
function M.root(cwd)
  local out, err = run({ "rev-parse", "--show-toplevel" }, cwd)
  if not out then
    return nil, err
  end
  local root = out:gsub("%s+$", "")
  return root ~= "" and root or nil, root == "" and "not a git repository" or nil
end

---Raw unified diff for `rev`.
---
---`rev` is passed through verbatim, so both "HEAD" (working tree vs HEAD, the default) and
---"main...HEAD" (whole branch) work. `--no-ext-diff` and `--no-color` keep the output
---parseable regardless of the user's git config, which may set an external differ or
---force colour.
---@param rev string|nil  defaults to "HEAD"
---@param cwd string
---@param opts { untracked?: boolean }|nil
---@return string|nil diff, string|nil err
function M.diff(rev, cwd, opts)
  rev = rev or "HEAD"
  opts = opts or {}

  local tracked, err = run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--find-renames",
    "-U3",
    rev,
    "--",
  }, cwd)
  if not tracked then
    return nil, err
  end

  if opts.untracked == false or not M.compares_worktree(rev) then
    return tracked, nil
  end

  local paths = M.untracked(cwd) or {}
  local parts = { tracked }
  for _, path in ipairs(paths) do
    local synthetic = M.diff_untracked(path, cwd)
    if synthetic and synthetic ~= "" then
      table.insert(parts, synthetic)
    end
  end

  return table.concat(parts), nil
end

---Whether `rev` is compared against the working tree.
---
---`git diff HEAD` and `git diff <sha>` compare the worktree, so untracked files belong in
---the review. A range like `main...HEAD` compares two commits, and an untracked file is in
---neither, so including it there would be inventing a change.
---@param rev string
---@return boolean
function M.compares_worktree(rev)
  return not rev:find("%.%.")
end

---Untracked, non-ignored files, repo-relative.
---
---`-uall` matters: the default collapses a new directory to `sub/` rather than listing
---`sub/deep.txt`, which would hide every file an agent created inside a new folder.
---@param cwd string
---@return string[]|nil, string|nil err
function M.untracked(cwd)
  local out, err = run({ "status", "--porcelain", "-uall", "--no-renames" }, cwd)
  if not out then
    return nil, err
  end

  local files = {}
  for line in out:gmatch("[^\n]+") do
    local path = line:match("^%?%? (.+)$")
    if path then
      -- git quotes paths with specials; strip the quoting so the parser sees a real path.
      local unquoted = path:match('^"(.*)"$')
      if unquoted then
        path = unquoted:gsub("\\(.)", "%1")
      end
      table.insert(files, path)
    end
  end
  return files, nil
end

---An all-additions diff for a file git does not track yet.
---
---`--no-index` exits 1 whenever the inputs differ, which is always true here, so that code
---is expected rather than a failure. The output carries `new file mode` and `--- /dev/null`,
---so the existing parser reads it as an addition with no special casing.
---@param path string  repo-relative
---@param cwd string
---@return string|nil diff, string|nil err
function M.diff_untracked(path, cwd)
  return run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-index",
    "-U3",
    "--",
    "/dev/null",
    path,
  }, cwd, { 1 })
end

---Contents of `path` at `rev`, for the "old" side of a split view.
---Returns an empty string for a file that does not exist at that rev (an addition), which
---is a normal case rather than an error.
---@param rev string
---@param path string  repo-relative
---@param cwd string
---@return string|nil content, string|nil err
function M.file_at(rev, path, cwd)
  local out, err = run({ "show", ("%s:%s"):format(rev, path) }, cwd)
  if not out then
    if err and (err:match("does not exist") or err:match("exists on disk, but not in")) then
      return "", nil
    end
    return nil, err
  end
  return out, nil
end

return M
