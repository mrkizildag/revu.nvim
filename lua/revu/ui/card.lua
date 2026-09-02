-- Renders a comment as the block of virtual lines drawn under the line it is anchored to.
--
-- Pure: comments in, virt_lines specs out. No buffers, no extmarks -- so the layout is
-- unit-testable and the same card is used by both view modes.

local config = require("revu.config")

local M = {}

---@param s string
---@param width integer
---@return string[]
local function wrap(s, width)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    if line == "" then
      line = word
    elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
      line = line .. " " .. word
    else
      table.insert(out, line)
      line = word
    end
  end
  if line ~= "" then
    table.insert(out, line)
  end
  return #out > 0 and out or { "" }
end

---The virtual lines for one comment.
---
---`virt_lines` takes a list of lines, each a list of {text, highlight} chunks, so a card is
---built as data and handed to a single extmark.
---@param comment revu.Comment
---@param width integer  usable text width
---@return table[]  virt_lines
function M.lines(comment, width)
  local c = config.options.comment
  local w = vim.fn.strdisplaywidth

  -- Everything between the corners is `inner` cells wide on all three rows; the arithmetic
  -- is done once here rather than per row, because a border that is off by one is exactly
  -- the kind of thing that looks broken and is tedious to chase.
  local inner = math.max(width - w(c.indent) - 2, 24)

  local resolved = comment.status == "resolved"
  local status = resolved and "resolved" or "open"
  local status_hl = resolved and "RevuCommentResolved" or "RevuCommentOpen"
  local marker = resolved and c.resolved or c.open

  local lead = c.fill:rep(2) .. " "
  local label = marker .. " " .. status .. " "
  local tail = math.max(inner - w(lead) - w(label), 0)

  local out = {
    {
      { c.indent .. c.corner_left .. lead, "RevuCommentBorder" },
      { label, status_hl },
      { c.fill:rep(tail) .. c.corner_right, "RevuCommentBorder" },
    },
  }

  local body_width = inner - 2 -- a space of padding either side
  for _, line in ipairs(wrap(comment.body, body_width)) do
    table.insert(out, {
      { c.indent .. c.side .. " ", "RevuCommentBorder" },
      { line, "RevuCommentBody" },
      { (" "):rep(math.max(body_width - w(line), 0)) .. " " .. c.side, "RevuCommentBorder" },
    })
  end

  table.insert(out, {
    { c.indent .. c.bottom_left .. c.fill:rep(inner) .. c.bottom_right, "RevuCommentBorder" },
  })

  return out
end

---Every card for a row, stacked.
---@param comments revu.Comment[]
---@param width integer
---@return table[]
function M.stack(comments, width)
  local out = {}
  for _, comment in ipairs(comments) do
    vim.list_extend(out, M.lines(comment, width))
  end
  return out
end

return M
