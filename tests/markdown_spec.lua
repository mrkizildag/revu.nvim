local markdown = require("revu.markdown")

local function c(t)
  return vim.tbl_extend("keep", t, {
    id = t.id or "x",
    side = "new",
    status = "open",
    anchor = "",
    context = {},
    created_at = "2026-01-01T00:00:00Z",
  })
end

describe("markdown.render", function()
  it("groups by file and sorts by line", function()
    local out = markdown.render({
      c({ path = "b.lua", line = 5, body = "second file" }),
      c({ path = "a.lua", line = 20, body = "later line" }),
      c({ path = "a.lua", line = 3, body = "earlier line" }),
    })

    local a_at = out:find("## a.lua", 1, true)
    local b_at = out:find("## b.lua", 1, true)
    assert.is_truthy(a_at)
    assert.is_truthy(b_at)
    assert.is_true(a_at < b_at, "a.lua should be grouped before b.lua")
    assert.is_true(out:find("earlier line", 1, true) < out:find("later line", 1, true))
  end)

  it("marks resolved comments as checked", function()
    local out = markdown.render({
      c({ path = "a.lua", line = 1, body = "open one" }),
      c({ path = "a.lua", line = 2, body = "done one", status = "resolved" }),
    })
    assert.is_truthy(out:match("%- %[ %] %*%*L1%*%*.-open one"))
    assert.is_truthy(out:match("%- %[x%] %*%*L2%*%*.-done one"))
  end)

  it("includes the anchor text when present", function()
    local out = markdown.render({
      c({ path = "a.lua", line = 7, body = "guard this", anchor = "  local x = 1" }),
    })
    assert.is_truthy(out:find("`local x = 1`", 1, true))
  end)

  it("flags the old side and leaves the new side implicit", function()
    local out = markdown.render({
      c({ path = "a.lua", line = 1, body = "on old", side = "old" }),
      c({ path = "a.lua", line = 2, body = "on new", side = "new" }),
    })
    assert.is_truthy(out:find("_(old side)_", 1, true))
    local new_line = out:match("[^\n]*on new[^\n]*")
    assert.is_nil(new_line:find("old side", 1, true))
  end)

  it("says so when there are no comments", function()
    assert.is_truthy(markdown.render({}):find("No comments", 1, true))
  end)

  it("does not mutate the input", function()
    local input =
      { c({ path = "z.lua", line = 2, body = "b" }), c({ path = "a.lua", line = 1, body = "a" }) }
    markdown.render(input)
    assert.equals("z.lua", input[1].path)
  end)
end)
