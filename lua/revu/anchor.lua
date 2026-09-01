-- Re-anchors comments to code that has moved underneath them.
--
-- Line numbers drift the moment an agent edits, which is the expected next step rather
-- than an edge case. A comment keyed only to `path:line` silently points at the wrong code
-- on the second pass -- worse than losing it, because it still looks correct.
--
-- Three outcomes, and the third one matters most:
--   exact    -- the anchor text is still on the recorded line
--   moved    -- found elsewhere nearby; the comment follows it
--   orphaned -- not found; surfaced separately, never rendered at a line we know is wrong
--
-- Pure: takes a comment and the current file lines, returns a verdict. No IO, no store.

local M = {}

-- How far to search either side of the recorded line. Wide enough to survive a normal
-- edit above the comment, narrow enough that an unrelated identical line elsewhere in a
-- large file is not a candidate at all.
M.WINDOW = 25

-- Neighbourhood consulted when scoring context. Deliberately smaller than WINDOW: context
-- disambiguates between near-identical candidates, it does not widen the search.
M.CONTEXT_RADIUS = 3

---@param s string|nil
---@return string
local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

---How much of the comment's recorded context appears around `idx`.
---
---Position-tolerant on purpose: the context array does not record which entries came from
---before the anchor and which from after, and an edit may have shifted them relative to it.
---Presence in the neighbourhood is the signal.
---@param lines string[]
---@param idx integer
---@param context string[]|nil
---@return integer
local function context_score(lines, idx, context)
  if not context or #context == 0 then
    return 0
  end

  local present = {}
  local lo = math.max(1, idx - M.CONTEXT_RADIUS)
  local hi = math.min(#lines, idx + M.CONTEXT_RADIUS)
  for i = lo, hi do
    if i ~= idx then
      present[trim(lines[i])] = true
    end
  end

  local score = 0
  for _, c in ipairs(context) do
    local t = trim(c)
    if t ~= "" and present[t] then
      score = score + 1
    end
  end
  return score
end

---Candidate lines within the window whose text matches, best first.
---@param lines string[]
---@param origin integer
---@param anchor string
---@param context string[]|nil
---@param compare fun(a: string, b: string): boolean
---@return integer|nil
local function best_match(lines, origin, anchor, context, compare)
  local best, best_key
  for offset = 0, M.WINDOW do
    -- Walk outwards so that, all else equal, the nearest candidate wins.
    for _, idx in ipairs(offset == 0 and { origin } or { origin - offset, origin + offset }) do
      if idx >= 1 and idx <= #lines and compare(lines[idx], anchor) then
        local key = { context_score(lines, idx, context), -math.abs(idx - origin) }
        if
          not best_key
          or key[1] > best_key[1]
          or (key[1] == best_key[1] and key[2] > best_key[2])
        then
          best, best_key = idx, key
        end
      end
    end
  end
  return best
end

local function exact_eq(a, b)
  return a == b
end

local function trimmed_eq(a, b)
  return trim(a) == trim(b)
end

---@class revu.Anchored
---@field comment revu.Comment
---@field line integer|nil     resolved line; nil when orphaned
---@field state "exact"|"moved"|"orphaned"

---Resolve one comment against the current contents of its file.
---@param comment revu.Comment
---@param lines string[]  current file lines, 1-based
---@return revu.Anchored
function M.resolve(comment, lines)
  local anchor = comment.anchor

  -- Nothing to match on: trust the stored line rather than inventing a verdict.
  if not anchor or anchor == "" then
    return { comment = comment, line = comment.line, state = "exact" }
  end

  if lines[comment.line] == anchor then
    return { comment = comment, line = comment.line, state = "exact" }
  end

  -- Exact text first. Only if nothing matches exactly do we accept a whitespace-only
  -- difference, so a reindent follows the code while a real edit still orphans.
  local hit = best_match(lines, comment.line, anchor, comment.context, exact_eq)
    or best_match(lines, comment.line, anchor, comment.context, trimmed_eq)

  if hit then
    return { comment = comment, line = hit, state = hit == comment.line and "exact" or "moved" }
  end

  return { comment = comment, line = nil, state = "orphaned" }
end

---Resolve many comments, grouping the file reads.
---@param comments revu.Comment[]
---@param get_lines fun(path: string): string[]|nil
---@return revu.Anchored[]
function M.resolve_all(comments, get_lines)
  local cache = {}
  local out = {}

  for _, c in ipairs(comments) do
    if cache[c.path] == nil then
      cache[c.path] = get_lines(c.path) or false
    end
    local lines = cache[c.path]

    if not lines then
      -- The file is gone. Orphaned rather than dropped: the comment may still be the most
      -- useful thing anyone says about a deletion.
      table.insert(out, { comment = c, line = nil, state = "orphaned" })
    else
      table.insert(out, M.resolve(c, lines))
    end
  end

  return out
end

---A copy of `comment` moved to its resolved line. Never mutates the input.
---@param anchored revu.Anchored
---@return revu.Comment
function M.applied(anchored)
  local c = vim.deepcopy(anchored.comment)
  if anchored.line then
    c.line = anchored.line
  end
  return c
end

return M
