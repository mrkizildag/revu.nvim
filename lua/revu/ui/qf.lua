-- Comments as a quickfix list.
--
-- The quickfix list is the right home for this: it is navigable with :cnext, filterable,
-- and every user already knows it. A notify popup can only be read once, which is the wrong
-- shape for a list you work through.

local M = {}

---One quickfix line per comment. Multi-line bodies show their first line.
---@param comment revu.Comment
---@param orphaned boolean
---@return string
local function summary(comment, orphaned)
  local first = vim.split(comment.body, "\n", { plain = true })[1] or ""
  local prefix = orphaned and "[stale] " or (comment.status == "resolved" and "[done] " or "")
  return prefix .. first
end

---@param root string
---@param placed revu.Comment[]
---@param orphaned revu.Comment[]
---@return integer count
function M.populate(root, placed, orphaned)
  local items = {}

  local function add(list, is_orphan)
    for _, c in ipairs(list) do
      table.insert(items, {
        filename = root .. "/" .. c.path,
        lnum = c.line,
        col = 1,
        -- An orphan's line number is where it used to be, so mark it as a warning: the
        -- position is a best guess rather than a fact.
        type = is_orphan and "W" or "I",
        text = summary(c, is_orphan),
      })
    end
  end

  add(placed, false)
  add(orphaned, true)

  table.sort(items, function(a, b)
    if a.filename == b.filename then
      return a.lnum < b.lnum
    end
    return a.filename < b.filename
  end)

  vim.fn.setqflist({}, " ", { title = "revu comments", items = items })
  return #items
end

return M
