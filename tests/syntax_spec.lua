local syntax = require("revu.ui.syntax")

describe("syntax.sections", function()
  it("groups contiguous body rows per file and skips pill rows", function()
    local rows = {
      { kind = "header", part = "top", path = "a.lua" },
      { kind = "header", part = "body", path = "a.lua" },
      { kind = "header", part = "bottom", path = "a.lua" },
      { kind = "context", path = "a.lua" },
      { kind = "add", path = "a.lua" },
      { kind = "header", part = "top", path = "b.go" },
      { kind = "header", part = "body", path = "b.go" },
      { kind = "header", part = "bottom", path = "b.go" },
      { kind = "del", path = "b.go" },
    }
    assert.same({
      { path = "a.lua", first = 4, last = 5 },
      { path = "b.go", first = 9, last = 9 },
    }, syntax.sections(rows))
  end)

  it("returns nothing for a review of only collapsed files", function()
    local rows = {
      { kind = "header", part = "top", path = "a.lua" },
      { kind = "header", part = "body", path = "a.lua" },
      { kind = "header", part = "bottom", path = "a.lua" },
    }
    assert.same({}, syntax.sections(rows))
  end)

  it("starts a new section when the path changes without a header between", function()
    local rows = {
      { kind = "context", path = "a.lua" },
      { kind = "context", path = "b.lua" },
    }
    assert.equals(2, #syntax.sections(rows))
  end)
end)

describe("syntax.apply", function()
  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local NS = vim.api.nvim_create_namespace("revu_syntax_test")

  it("colours a lua section using that language's captures", function()
    local buf = scratch({ "pill", "pill", "pill", "local function go(a)", "  return a" })
    local rows = {
      { kind = "header", part = "top", path = "a.lua" },
      { kind = "header", part = "body", path = "a.lua" },
      { kind = "header", part = "bottom", path = "a.lua" },
      { kind = "add", path = "a.lua" },
      { kind = "add", path = "a.lua" },
    }
    syntax.apply(buf, NS, rows)

    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
      groups[m[4].hl_group] = true
      assert.is_true(m[2] >= 3, "must not colour the pill rows")
    end
    assert.is_true(groups["@keyword.function"] or groups["@keyword"], "expected a keyword capture")
  end)

  it("never emits a private @_ capture", function()
    local buf = scratch({ "h", "h", "h", "local x = { a = 1 }", "return x" })
    local rows = {
      { kind = "header", part = "top", path = "a.lua" },
      { kind = "header", part = "body", path = "a.lua" },
      { kind = "header", part = "bottom", path = "a.lua" },
      { kind = "context", path = "a.lua" },
      { kind = "context", path = "a.lua" },
    }
    syntax.apply(buf, NS, rows)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
      assert.is_nil(m[4].hl_group:find("^@_"), "leaked " .. m[4].hl_group)
    end
  end)

  it("leaves a file with no known language alone rather than erroring", function()
    local buf = scratch({ "some bytes" })
    local rows = { { kind = "context", path = "blob.unknownext" } }
    assert.has_no.errors(function()
      syntax.apply(buf, NS, rows)
    end)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {}))
  end)

  it("clears previous highlights so a redraw does not stack them", function()
    local buf = scratch({ "local function go() end" })
    local rows = { { kind = "add", path = "a.lua" } }

    syntax.apply(buf, NS, rows)
    local first = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
    syntax.apply(buf, NS, rows)
    local second = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})

    assert.is_true(first > 0)
    assert.equals(first, second)
  end)

  it("uses its own namespace so diff marks survive", function()
    local buf = scratch({ "local x = 1" })
    local diff_ns = vim.api.nvim_create_namespace("revu_diff_test")
    vim.api.nvim_buf_set_extmark(buf, diff_ns, 0, 0, { line_hl_group = "DiffAdd" })

    syntax.apply(buf, NS, { { kind = "add", path = "a.lua" } })

    local kept = vim.api.nvim_buf_get_extmarks(buf, diff_ns, 0, -1, { details = true })
    assert.equals(1, #kept)
    assert.equals("DiffAdd", kept[1][4].line_hl_group)
  end)
end)
