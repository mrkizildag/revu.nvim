local qf = require("revu.ui.qf")

local function comment(t)
  return vim.tbl_extend("keep", t, {
    id = "x",
    side = "new",
    status = "open",
    anchor = "",
    context = {},
    body = "a note",
    created_at = "2026-01-01T00:00:00Z",
  })
end

describe("qf.populate", function()
  it("lists every comment, placed and orphaned", function()
    local n = qf.populate(
      "/repo",
      { comment({ path = "a.lua", line = 3 }) },
      { comment({ path = "b.lua", line = 9 }) }
    )
    assert.equals(2, n)
    assert.equals(2, #vim.fn.getqflist())
  end)

  it("sorts by file then line", function()
    qf.populate("/repo", {
      comment({ path = "b.lua", line = 1 }),
      comment({ path = "a.lua", line = 9 }),
      comment({ path = "a.lua", line = 2 }),
    }, {})

    local seen = {}
    for _, item in ipairs(vim.fn.getqflist()) do
      table.insert(seen, vim.fn.bufname(item.bufnr) .. ":" .. item.lnum)
    end
    assert.same({ "/repo/a.lua:2", "/repo/a.lua:9", "/repo/b.lua:1" }, seen)
  end)

  it("marks an orphan as a warning, since its line is only a guess", function()
    qf.populate("/repo", {}, { comment({ path = "a.lua", line = 4, body = "gone" }) })
    local item = vim.fn.getqflist()[1]
    assert.equals("W", item.type)
    assert.is_truthy(item.text:find("[stale]", 1, true))
  end)

  it("marks a resolved comment without flagging it", function()
    qf.populate("/repo", { comment({ path = "a.lua", line = 1, status = "resolved" }) }, {})
    local item = vim.fn.getqflist()[1]
    assert.equals("I", item.type)
    assert.is_truthy(item.text:find("[done]", 1, true))
  end)

  it("shows only the first line of a multi-line body", function()
    qf.populate(
      "/repo",
      { comment({ path = "a.lua", line = 1, body = "first line\nsecond line" }) },
      {}
    )
    local text = vim.fn.getqflist()[1].text
    assert.is_truthy(text:find("first line", 1, true))
    assert.is_nil(text:find("second line", 1, true))
  end)

  it("returns zero for an empty list", function()
    assert.equals(0, qf.populate("/repo", {}, {}))
  end)
end)
