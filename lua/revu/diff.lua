-- Unified-diff parser. Turns `git diff` output into the model both view modes render from.
--
-- Split and unified modes are two renderings of THIS structure, which is why the toggle is
-- a re-render rather than a second parsing path.

local M = {}

---@class revu.DiffLine
---@field kind "context"|"add"|"del"
---@field text string
---@field old_line integer|nil  line number on the old side (nil for additions)
---@field new_line integer|nil  line number on the new side (nil for deletions)

---@class revu.Hunk
---@field old_start integer
---@field new_start integer
---@field header string          text after the closing @@, e.g. the enclosing function
---@field lines revu.DiffLine[]

---@class revu.File
---@field path string            new path; for a deletion, the path that was removed
---@field old_path string|nil    set only on rename
---@field status "added"|"deleted"|"modified"|"renamed"
---@field binary boolean
---@field hunks revu.Hunk[]

---Strip git's leading a/ or b/ from a --- / +++ path.
---@param p string
---@return string|nil  nil for /dev/null
local function strip_prefix(p)
  if p == "/dev/null" then
    return nil
  end
  -- Git quotes paths containing specials as "..."; unquote the simple case.
  local unquoted = p:match('^"(.*)"$')
  if unquoted then
    p = unquoted:gsub('\\(.)', '%1')
  end
  return (p:gsub("^[ab]/", ""))
end

---@param header string  e.g. "@@ -1,3 +1,4 @@ func foo()"
---@return revu.Hunk|nil
local function parse_hunk_header(header)
  local old_start, new_start, trailing =
    header:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@(.*)$")
  if not old_start then
    return nil
  end
  return {
    old_start = tonumber(old_start),
    new_start = tonumber(new_start),
    header = (trailing or ""):gsub("^%s+", ""),
    lines = {},
  }
end

---Parse raw `git diff` output.
---@param text string
---@return revu.File[]
function M.parse(text)
  local files = {} ---@type revu.File[]
  local file, hunk
  local old_no, new_no

  local function close_hunk()
    if file and hunk then
      table.insert(file.hunks, hunk)
    end
    hunk = nil
  end

  local function close_file()
    close_hunk()
    if file then
      table.insert(files, file)
    end
    file = nil
  end

  local lines = vim.split(text or "", "\n", { plain = true })
  -- git diff output ends with a newline, so the split leaves a trailing "" that would
  -- otherwise be read as an empty context line and append a phantom row to the last hunk.
  if lines[#lines] == "" then
    table.remove(lines)
  end

  for _, line in ipairs(lines) do
    if line:match("^diff %-%-git ") then
      close_file()
      file = { path = "", status = "modified", binary = false, hunks = {} }
    elseif not file then
      -- preamble before the first file header; ignore
    elseif line:match("^new file mode") then
      file.status = "added"
    elseif line:match("^deleted file mode") then
      file.status = "deleted"
    elseif line:match("^rename from ") then
      file.status = "renamed"
      file.old_path = line:sub(#"rename from " + 1)
    elseif line:match("^rename to ") then
      file.status = "renamed"
      file.path = line:sub(#"rename to " + 1)
    elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
      file.binary = true
    elseif line:match("^%-%-%- ") then
      close_hunk()
      local p = strip_prefix(line:sub(5))
      if p and file.path == "" then
        file.path = p
      end
    elseif line:match("^%+%+%+ ") then
      local p = strip_prefix(line:sub(5))
      if p then
        file.path = p
      end
    elseif line:match("^@@") then
      close_hunk()
      hunk = parse_hunk_header(line)
      if hunk then
        old_no, new_no = hunk.old_start, hunk.new_start
      end
    elseif hunk then
      local tag, rest = line:sub(1, 1), line:sub(2)
      if tag == "+" then
        table.insert(hunk.lines, { kind = "add", text = rest, new_line = new_no })
        new_no = new_no + 1
      elseif tag == "-" then
        table.insert(hunk.lines, { kind = "del", text = rest, old_line = old_no })
        old_no = old_no + 1
      elseif tag == " " or line == "" then
        -- Some producers emit a bare empty line for an empty context line.
        table.insert(hunk.lines, {
          kind = "context",
          text = tag == " " and rest or "",
          old_line = old_no,
          new_line = new_no,
        })
        old_no, new_no = old_no + 1, new_no + 1
      elseif tag == "\\" then
        -- "\ No newline at end of file" annotates the previous line; not a line itself.
      else
        -- Unknown line inside a hunk: end it rather than misnumber everything after.
        close_hunk()
      end
    end
  end

  close_file()
  return files
end

---Flatten a file's hunks into the row list the unified view renders.
---Hunk headers become their own rows so the view can style them.
---@param file revu.File
---@return { kind: "hunk"|"context"|"add"|"del", text: string, old_line: integer|nil, new_line: integer|nil }[]
function M.unified_rows(file)
  local rows = {}
  for _, h in ipairs(file.hunks) do
    table.insert(rows, {
      kind = "hunk",
      text = ("@@ -%d +%d @@ %s"):format(h.old_start, h.new_start, h.header),
    })
    for _, l in ipairs(h.lines) do
      table.insert(rows, l)
    end
  end
  return rows
end

return M
