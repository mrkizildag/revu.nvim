-- Turns a parsed diff file into everything a buffer needs: its lines, the extmarks that
-- style them, and a parallel row table mapping each buffer row back to a source line.
--
-- Pure -- no buffers, no windows, no API calls -- so the layout is unit-testable and the
-- split renderer in #6 can reuse the same shape.
--
-- Two decisions that matter:
--
--   * The buffer holds ONLY code text, with no `+`/`-` prefix. Prefixed lines are not
--     valid source, so treesitter would fail to parse them; add/delete is carried by
--     `line_hl_group` and `sign_text` instead, which is also what makes the text yankable
--     as real code.
--   * Hunk headers are virtual lines, not buffer lines. That keeps buffer rows in 1:1
--     correspondence with source lines, so mapping a cursor row to a comment anchor in #7
--     needs no offset arithmetic, and treesitter never sees an `@@ ... @@` line.

local config = require("revu.config")

local M = {}

---@class revu.RenderRow
---@field kind "header"|"context"|"add"|"del"
---@field path string|nil        file the row belongs to
---@field file_index integer|nil index into the review's file list
---@field old_line integer|nil
---@field new_line integer|nil

---@class revu.Render
---@field lines string[]                                        buffer contents
---@field rows revu.RenderRow[]                                 parallel to `lines`
---@field marks { row: integer, line_hl: string?, sign_text: string?, sign_hl: string?, prefix_text: string?, prefix_hl: string?, segments: table[]? }[]
---@field virt { row: integer, text: string, hl: string }[]     hunk headers, drawn above `row`
---@field binary boolean

---@param file revu.File
---@return revu.Render
function M.unified(file)
  local opts = config.options

  if file.binary then
    return {
      lines = { ("── binary file (%s) ──"):format(file.path) },
      rows = { { kind = "context" } },
      marks = {},
      virt = {},
      binary = true,
    }
  end

  local out = { lines = {}, rows = {}, marks = {}, virt = {}, binary = false }

  for _, hunk in ipairs(file.hunks) do
    -- Attached to the row that follows it, so it renders above the hunk's first line.
    table.insert(out.virt, {
      row = #out.lines,
      text = ("@@ -%d +%d @@%s"):format(
        hunk.old_start,
        hunk.new_start,
        hunk.header ~= "" and (" " .. hunk.header) or ""
      ),
      hl = "RevuHunk",
    })

    for _, line in ipairs(hunk.lines) do
      table.insert(out.lines, line.text)
      table.insert(out.rows, {
        kind = line.kind,
        old_line = line.old_line,
        new_line = line.new_line,
      })

      local row = #out.lines - 1 -- extmarks are 0-based
      local mark = { row = row }

      if line.kind == "add" then
        mark.line_hl = "RevuAdd"
        mark.prefix_text = opts.prefix.add
        mark.prefix_hl = "RevuAddPrefix"
        mark.sign_text = opts.signs and opts.signs.add or nil
        mark.sign_hl = "RevuAddSign"
      elseif line.kind == "del" then
        mark.line_hl = "RevuDelete"
        mark.prefix_text = opts.prefix.delete
        mark.prefix_hl = "RevuDeletePrefix"
        mark.sign_text = opts.signs and opts.signs.delete or nil
        mark.sign_hl = "RevuDeleteSign"
      else
        -- Context still gets a prefix, of equal width, so the columns line up.
        mark.prefix_text = opts.prefix.context
      end

      if mark.line_hl or mark.prefix_text then
        table.insert(out.marks, mark)
      end
    end
  end

  if #out.lines == 0 then
    out.lines = { ("── no textual changes (%s) ──"):format(file.path) }
    out.rows = { { kind = "context" } }
  end

  return out
end

---Added and removed line counts for a file.
---@param file revu.File
---@return integer adds, integer dels
function M.stat(file)
  local adds, dels = 0, 0
  for _, h in ipairs(file.hunks) do
    for _, l in ipairs(h.lines) do
      if l.kind == "add" then
        adds = adds + 1
      elseif l.kind == "del" then
        dels = dels + 1
      end
    end
  end
  return adds, dels
end

---@class revu.HeaderLine
---@field text string
---@field segments { col: integer, end_col: integer, hl: string }[]

---The pill introducing a file: a bordered box spanning the window, with the path on the
---left of the middle row and the counts on the right.
---
---Three real buffer lines rather than one, and real rather than virtual, because the
---cursor has to be able to land on the pill to fold the section and virtual text cannot be
---navigated to. A single line needs several colours -- dimmed directory, bright filename,
---green additions, red deletions -- which is why each row carries byte-offset segments
---instead of one line highlight.
---@param file revu.File
---@param collapsed boolean
---@param width integer
---@return revu.HeaderLine[]  exactly three: top, content, bottom
function M.header_lines(file, collapsed, width)
  local h = config.options.header
  local b = h.borderchars
  local top, right, bottom, left, tl, tr, br, bl = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8]

  local inner = math.max(width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right), 1)

  local dir, name = file.path:match("^(.*/)([^/]+)$")
  dir, name = dir or "", name or file.path

  ---@type { [1]: string, [2]: string|nil }[]
  local lead = {
    { " ", nil },
    { collapsed and h.collapsed or h.expanded, "RevuHeaderChevron" },
    { " ", nil },
    { dir, "RevuHeaderDir" },
    { name, "RevuHeaderName" },
  }
  local tail = file.binary and { { "binary", "RevuHeaderStat" }, { " ", nil } }
    or {
      { "+" .. select(1, M.stat(file)), "RevuHeaderAdd" },
      { "  ", nil },
      { "−" .. select(2, M.stat(file)), "RevuHeaderDelete" },
      { " ", nil },
    }

  local function width_of(pieces)
    local w = 0
    for _, piece in ipairs(pieces) do
      w = w + vim.fn.strdisplaywidth(piece[1])
    end
    return w
  end

  -- Counts sit against the right edge; the gap absorbs whatever is left over. A window too
  -- narrow for both collapses the gap to a single space rather than breaking the box.
  local gap = math.max(inner - width_of(lead) - width_of(tail), 1)

  local content, segments = left, { { col = 0, end_col = #left, hl = "RevuHeaderBorder" } }
  local function append(pieces)
    for _, piece in ipairs(pieces) do
      if piece[2] and piece[1] ~= "" then
        segments[#segments + 1] = { col = #content, end_col = #content + #piece[1], hl = piece[2] }
      end
      content = content .. piece[1]
    end
  end

  append(lead)
  content = content .. (" "):rep(gap)
  append(tail)
  segments[#segments + 1] = { col = #content, end_col = #content + #right, hl = "RevuHeaderBorder" }
  content = content .. right

  local function border(l, fill, r)
    local text = l .. fill:rep(inner) .. r
    return { text = text, segments = { { col = 0, end_col = #text, hl = "RevuHeaderBorder" } } }
  end

  return {
    border(tl, top, tr),
    { text = content, segments = segments },
    border(bl, bottom, br),
  }
end

---Render a whole review: every file in one buffer, each behind a header row.
---@param files revu.File[]
---@param collapsed table<string, boolean>|nil  paths that are folded shut
---@param width integer|nil  window width the header pills should fill
---@return revu.Render
function M.review(files, collapsed, width)
  collapsed = collapsed or {}
  width = width or 80
  local out = { lines = {}, rows = {}, marks = {}, virt = {}, binary = false }

  for index, file in ipairs(files) do
    local is_collapsed = collapsed[file.path] == true

    -- Three rows per pill; all tagged as `header` so folding works from any of them.
    for _, hl_line in ipairs(M.header_lines(file, is_collapsed, width)) do
      table.insert(out.lines, hl_line.text)
      table.insert(out.rows, { kind = "header", path = file.path, file_index = index })
      table.insert(out.marks, { row = #out.lines - 1, segments = hl_line.segments })
    end

    if not is_collapsed then
      local body = M.unified(file)
      local offset = #out.lines

      for i, line in ipairs(body.lines) do
        table.insert(out.lines, line)
        local r = vim.tbl_extend("force", body.rows[i], { path = file.path, file_index = index })
        table.insert(out.rows, r)
      end
      for _, m in ipairs(body.marks) do
        table.insert(out.marks, vim.tbl_extend("force", m, { row = m.row + offset }))
      end
      for _, v in ipairs(body.virt) do
        table.insert(out.virt, vim.tbl_extend("force", v, { row = v.row + offset }))
      end
    end
  end

  return out
end

---Buffer row to put the cursor on for `file_index`: the middle row of the pill, where the
---filename is, rather than its top border.
---@param render revu.Render
---@param file_index integer
---@return integer|nil
function M.header_row(render, file_index)
  for i, r in ipairs(render.rows) do
    if r.kind == "header" and r.file_index == file_index then
      return i + 1
    end
  end
  return nil
end

---Source line a buffer row refers to, preferring the new side.
---
---A deleted row has no new-side number, so it falls back to the old side; the caller gets
---the side back too, since a comment must record which one it is anchored to.
---@param render revu.Render
---@param row integer  1-based buffer row
---@return integer|nil line, "old"|"new"|nil side
function M.source_line(render, row)
  local r = render.rows[row]
  if not r then
    return nil, nil
  end
  if r.new_line then
    return r.new_line, "new"
  end
  if r.old_line then
    return r.old_line, "old"
  end
  return nil, nil
end

return M
