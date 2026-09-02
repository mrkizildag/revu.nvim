local card = require("revu.ui.card")

local function text_of(virt_line)
  local t = ""
  for _, chunk in ipairs(virt_line) do
    t = t .. chunk[1]
  end
  return t
end

local function comment(t)
  return vim.tbl_extend("keep", t, { status = "open", body = "note" })
end

describe("card.lines", function()
  it("draws a box whose rows are all the same width", function()
    for _, width in ipairs({ 40, 70, 120 }) do
      local lines = card.lines(comment({ body = "short" }), width)
      local seen = {}
      for _, l in ipairs(lines) do
        seen[vim.fn.strdisplaywidth(text_of(l))] = true
      end
      assert.equals(1, vim.tbl_count(seen), "rows differ in width at " .. width)
    end
  end)

  it("wraps a long body instead of overflowing", function()
    local long = string.rep("word ", 60)
    local lines = card.lines(comment({ body = long }), 50)
    assert.is_true(#lines > 3, "expected the body to wrap")
    for _, l in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(text_of(l)) <= 50)
    end
  end)

  it("shows open and resolved differently", function()
    local open = text_of(card.lines(comment({}), 60)[1])
    local done = text_of(card.lines(comment({ status = "resolved" }), 60)[1])
    assert.is_truthy(open:find("open", 1, true))
    assert.is_truthy(done:find("resolved", 1, true))
    assert.are_not.equals(open, done)
  end)

  it("colours the status marker separately from the border", function()
    local groups = {}
    for _, chunk in ipairs(card.lines(comment({}), 60)[1]) do
      groups[chunk[2]] = true
    end
    assert.is_true(groups["RevuCommentBorder"])
    assert.is_true(groups["RevuCommentOpen"])
  end)

  it("stacks several comments for one row", function()
    local one = card.lines(comment({}), 60)
    local stacked = card.stack({ comment({}), comment({ body = "second" }) }, 60)
    assert.equals(#one * 2, #stacked)
  end)

  it("does not collapse below a readable width", function()
    local lines = card.lines(comment({ body = "x" }), 10)
    assert.is_true(vim.fn.strdisplaywidth(text_of(lines[1])) >= 24)
  end)
end)
