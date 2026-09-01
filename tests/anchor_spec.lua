local anchor = require("revu.anchor")

local function comment(t)
  return vim.tbl_extend("keep", t, {
    id = "c1",
    path = "a.lua",
    side = "new",
    status = "open",
    context = {},
    body = "note",
    created_at = "2026-01-01T00:00:00Z",
  })
end

--- Lines of a small file, 1-based.
local function lines(s)
  return vim.split(s:gsub("^\n", ""), "\n", { plain = true })
end

local BASE = lines([[
local function a()
  return nil
end
]])

describe("anchor.resolve", function()
  it("keeps the line when the file is unchanged", function()
    local r = anchor.resolve(comment({ line = 2, anchor = "  return nil" }), BASE)
    assert.equals("exact", r.state)
    assert.equals(2, r.line)
  end)

  it("follows the anchor when lines are inserted above", function()
    local after = lines([[
-- new header
-- another
local function a()
  return nil
end
]])
    local r = anchor.resolve(comment({ line = 2, anchor = "  return nil" }), after)
    assert.equals("moved", r.state)
    assert.equals(4, r.line)
  end)

  it("follows the anchor when lines are deleted above", function()
    local before = lines([[
-- header
-- header
-- header
local function a()
  return nil
end
]])
    local after = lines([[
local function a()
  return nil
end
]])
    -- recorded against the longer file, then three lines removed above it
    local r = anchor.resolve(comment({ line = 5, anchor = "  return nil" }), after)
    assert.equals("moved", r.state)
    assert.equals(2, r.line)
    assert.equals("  return nil", before[5])
  end)

  it("orphans when the anchored line itself was edited", function()
    local after = lines([[
local function a()
  return false
end
]])
    local r = anchor.resolve(comment({ line = 2, anchor = "  return nil" }), after)
    assert.equals("orphaned", r.state)
    assert.is_nil(r.line)
  end)

  it("uses context to choose between identical candidates", function()
    local after = lines([[
-- inserted
local function a()
  return nil
end
local function b()
  return nil
end
]])
    local c = comment({ line = 2, anchor = "  return nil", context = { "local function a()" } })
    local r = anchor.resolve(c, after)
    assert.equals("moved", r.state)
    assert.equals(3, r.line, "should pick the candidate inside function a, not function b")
  end)

  it("picks the nearest candidate when there is no context to go on", function()
    local after = lines([[
  return nil
padding
padding
  return nil
padding
]])
    local r = anchor.resolve(comment({ line = 4, anchor = "  return nil" }), after)
    assert.equals(4, r.line)
    assert.equals("exact", r.state)
  end)

  it("tolerates a reindent in place", function()
    local reindented = lines([[
local function a()
      return nil
end
]])
    -- The line did not move, so the verdict is `exact` even though the leading
    -- whitespace changed. `state` describes movement, not byte equality.
    local r = anchor.resolve(comment({ line = 2, anchor = "  return nil" }), reindented)
    assert.equals("exact", r.state)
    assert.equals(2, r.line)
  end)

  it("follows a line that was both reindented and shifted", function()
    local after = lines([[
-- inserted
local function a()
      return nil
end
]])
    local r = anchor.resolve(comment({ line = 2, anchor = "  return nil" }), after)
    assert.equals("moved", r.state)
    assert.equals(3, r.line)
  end)

  it("still orphans a real edit rather than fuzzy-matching it", function()
    local edited = lines([[
local function a()
  return false
end
]])
    assert.equals(
      "orphaned",
      anchor.resolve(comment({ line = 2, anchor = "  return nil" }), edited).state
    )
  end)

  it("orphans when the anchor moved beyond the window", function()
    local padded = {}
    for _ = 1, anchor.WINDOW + 5 do
      table.insert(padded, "padding")
    end
    table.insert(padded, "  return nil")

    local r = anchor.resolve(comment({ line = 1, anchor = "  return nil" }), padded)
    assert.equals("orphaned", r.state)
  end)

  it("finds it right at the window edge", function()
    local padded = {}
    for _ = 1, anchor.WINDOW - 1 do
      table.insert(padded, "padding")
    end
    table.insert(padded, "  return nil")

    local r = anchor.resolve(comment({ line = 1, anchor = "  return nil" }), padded)
    assert.equals("moved", r.state)
    assert.equals(anchor.WINDOW, r.line)
  end)

  it("trusts the stored line when there is no anchor text", function()
    local r = anchor.resolve(comment({ line = 2, anchor = "" }), BASE)
    assert.equals("exact", r.state)
    assert.equals(2, r.line)
  end)

  it("does not mutate the comment", function()
    local c = comment({ line = 2, anchor = "  return nil" })
    anchor.resolve(c, lines("x\ny\nz\n  return nil\n"))
    assert.equals(2, c.line)
  end)
end)

describe("anchor.resolve_all", function()
  it("orphans comments whose file is gone", function()
    local out = anchor.resolve_all(
      { comment({ line = 1, anchor = "x", path = "deleted.lua" }) },
      function()
        return nil
      end
    )
    assert.equals("orphaned", out[1].state)
  end)

  it("reads each file once", function()
    local reads = {}
    local cs = {
      comment({ id = "1", line = 2, anchor = "  return nil", path = "a.lua" }),
      comment({ id = "2", line = 3, anchor = "end", path = "a.lua" }),
      comment({ id = "3", line = 1, anchor = "local function a()", path = "b.lua" }),
    }
    anchor.resolve_all(cs, function(path)
      reads[path] = (reads[path] or 0) + 1
      return BASE
    end)
    assert.equals(1, reads["a.lua"])
    assert.equals(1, reads["b.lua"])
  end)

  it("resolves a mix of states in one pass", function()
    local shifted = lines([[
-- inserted
local function a()
  return nil
end
]])
    local out = anchor.resolve_all({
      comment({ id = "1", line = 3, anchor = "  return nil" }),
      comment({ id = "2", line = 1, anchor = "gone forever" }),
    }, function()
      return shifted
    end)
    assert.equals("exact", out[1].state)
    assert.equals("orphaned", out[2].state)
  end)
end)

describe("anchor.applied", function()
  it("returns a copy moved to the resolved line", function()
    local c = comment({ line = 2, anchor = "  return nil" })
    local moved = anchor.applied({ comment = c, line = 9, state = "moved" })
    assert.equals(9, moved.line)
    assert.equals(2, c.line, "original must not be mutated")
  end)

  it("leaves an orphan's line alone", function()
    local c = comment({ line = 2, anchor = "x" })
    local out = anchor.applied({ comment = c, line = nil, state = "orphaned" })
    assert.equals(2, out.line)
  end)
end)
