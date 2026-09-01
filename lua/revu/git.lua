-- Thin wrapper over the git CLI. Everything here returns plain data; no UI, no state.
--
-- Errors are returned, never thrown or notified: callers decide how loud to be, and the
-- test suite can assert on them.

local M = {}

---@param args string[]
---@param cwd string
---@return string|nil stdout, string|nil err
local function run(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)

  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true }):wait()
  end)

  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
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
---@return string|nil diff, string|nil err
function M.diff(rev, cwd)
  return run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--find-renames",
    "-U3",
    rev or "HEAD",
    "--",
  }, cwd)
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
