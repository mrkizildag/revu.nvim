-- Syntax colouring for a buffer that holds several languages at once.
--
-- The review buffer has no single `filetype` -- it may hold Lua, Go and YAML -- so
-- `vim.treesitter.start()` cannot be used: it attaches exactly one parser to the buffer.
--
-- Instead each file's section is parsed on its own with a string parser for that language,
-- the highlights query is run over it, and the capture ranges are emitted as extmarks
-- offset into the review buffer. Foreground only, so the diff background from
-- `line_hl_group` still shows through.
--
-- Caveat inherited from unified diffs generally: interleaved add and delete lines are not
-- always syntactically valid, so a tree may be imperfect. It still colours the large
-- majority of tokens, which beats none.

local M = {}

---Contiguous runs of non-header rows, one per file section.
---@param rows revu.RenderRow[]
---@return { path: string, first: integer, last: integer }[]  1-based, inclusive
function M.sections(rows)
  local out, current = {}, nil

  for i, row in ipairs(rows) do
    if row.kind == "header" or not row.path then
      current = nil
    elseif current and current.path == row.path then
      current.last = i
    else
      current = { path = row.path, first = i, last = i }
      out[#out + 1] = current
    end
  end

  return out
end

---@param path string
---@return string|nil
local function language_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  -- Only languages with an installed parser; asking for a missing one throws.
  local ok = pcall(vim.treesitter.language.add, lang)
  return ok and lang or nil
end

---Colour one section.
---@param buf integer
---@param ns integer
---@param lang string
---@param first integer  1-based buffer row the section starts at
---@param lines string[]
local function highlight_section(buf, ns, lang, first, lines)
  local text = table.concat(lines, "\n")

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return
  end

  local tree = (parser:parse() or {})[1]
  if not tree then
    return
  end

  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return
  end

  for id, node in query:iter_captures(tree:root(), text) do
    local capture = query.captures[id]
    -- Captures beginning with `_` are internal to the query and have no highlight group.
    if not capture:find("^_") then
      local srow, scol, erow, ecol = node:range()
      -- Priority below treesitter's own default so a user's overrides still win, and the
      -- diff line background is unaffected either way -- these set foreground only.
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, first - 1 + srow, scol, {
        end_row = first - 1 + erow,
        end_col = ecol,
        hl_group = "@" .. capture,
        priority = 90,
      })
    end
  end
end

---Apply syntax highlighting to every file section in the review.
---@param buf integer
---@param ns integer  a namespace of its own, cleared and rebuilt on each draw
---@param rows revu.RenderRow[]
function M.apply(buf, ns, rows)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, section in ipairs(M.sections(rows)) do
    local lang = language_for(section.path)
    if lang then
      local lines = vim.api.nvim_buf_get_lines(buf, section.first - 1, section.last, false)
      highlight_section(buf, ns, lang, section.first, lines)
    end
  end
end

return M
