local render = require("revu.ui.render")
local diff = require("revu.diff")

local function parse(...)
  return diff.parse(table.concat({ ... }, "\n") .. "\n")[1]
end

local FILE = parse(
  "diff --git a/a.lua b/a.lua",
  "--- a/a.lua",
  "+++ b/a.lua",
  "@@ -10,3 +10,4 @@ function foo()",
  " keep",
  "-gone",
  "+new",
  " tail"
)

describe("render.unified", function()
  it("puts only code text in the buffer, with no +/- prefix", function()
    local r = render.unified(FILE)
    assert.same({ "keep", "gone", "new", "tail" }, r.lines)
  end)

  it("highlights additions and deletions but not context", function()
    local r = render.unified(FILE)
    local by_row = {}
    for _, m in ipairs(r.marks) do
      by_row[m.row] = m
    end
    assert.is_nil(by_row[0].line_hl, "context must not be background-highlighted")
    assert.equals("RevuDelete", by_row[1].line_hl)
    assert.equals("RevuAdd", by_row[2].line_hl)
    assert.is_nil(by_row[3].line_hl)
  end)

  it("gives every row an inline prefix, padded so columns line up", function()
    local r = render.unified(FILE)
    local by_row = {}
    for _, m in ipairs(r.marks) do
      by_row[m.row] = m
    end
    assert.equals("  ", by_row[0].prefix_text) -- context
    assert.equals("- ", by_row[1].prefix_text)
    assert.equals("+ ", by_row[2].prefix_text)
    assert.equals("RevuAddPrefix", by_row[2].prefix_hl)

    local widths = {}
    for _, m in pairs(by_row) do
      widths[#m.prefix_text] = true
    end
    assert.equals(1, vim.tbl_count(widths), "all prefixes must be the same width")
  end)

  it("keeps the prefix out of the buffer text so code stays yankable", function()
    local r = render.unified(FILE)
    for _, l in ipairs(r.lines) do
      assert.is_nil(l:find("^[+-] "))
    end
  end)

  it("omits gutter signs unless they are configured on", function()
    local r = render.unified(FILE)
    for _, m in ipairs(r.marks) do
      assert.is_nil(m.sign_text)
    end

    require("revu.config").setup({ signs = { add = "▎", delete = "▎" } })
    local with_signs = render.unified(FILE)
    local found = false
    for _, m in ipairs(with_signs.marks) do
      if m.sign_text then
        found = true
      end
    end
    assert.is_true(found)
    require("revu.config").setup({})
  end)

  it("emits the hunk header as a virtual line, not a buffer line", function()
    local r = render.unified(FILE)
    assert.equals(1, #r.virt)
    assert.equals(0, r.virt[1].row)
    assert.is_truthy(r.virt[1].text:find("@@", 1, true))
    assert.is_truthy(r.virt[1].text:find("function foo()", 1, true))
    for _, l in ipairs(r.lines) do
      assert.is_nil(l:find("@@", 1, true), "no @@ should reach the buffer")
    end
  end)

  it("keeps rows parallel to lines", function()
    local r = render.unified(FILE)
    assert.equals(#r.lines, #r.rows)
    assert.same({ "context", "del", "add", "context" }, {
      r.rows[1].kind,
      r.rows[2].kind,
      r.rows[3].kind,
      r.rows[4].kind,
    })
  end)

  it("renders a placeholder for a binary file rather than an empty buffer", function()
    local f = parse(
      "diff --git a/logo.png b/logo.png",
      "index 1..2 100644",
      "Binary files a/logo.png and b/logo.png differ"
    )
    local r = render.unified(f)
    assert.is_true(r.binary)
    assert.equals(1, #r.lines)
    assert.is_truthy(r.lines[1]:find("binary", 1, true))
    assert.equals(0, #r.marks)
  end)

  it("renders a placeholder when a file has no hunks", function()
    local r = render.unified({ path = "x.lua", status = "modified", binary = false, hunks = {} })
    assert.equals(1, #r.lines)
    assert.equals(#r.lines, #r.rows)
  end)

  it("emits one virtual header per hunk, at the right row", function()
    local f = parse(
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1 +1 @@",
      "-a",
      "+A",
      "@@ -10 +10 @@",
      "-b",
      "+B"
    )
    local r = render.unified(f)
    assert.equals(2, #r.virt)
    assert.equals(0, r.virt[1].row)
    assert.equals(2, r.virt[2].row, "second header sits above the third buffer row")
  end)
end)

describe("render.source_line", function()
  it("prefers the new side and falls back to the old for deletions", function()
    local r = render.unified(FILE)
    local line, side = render.source_line(r, 1)
    assert.equals(10, line)
    assert.equals("new", side)

    line, side = render.source_line(r, 2) -- the deleted row
    assert.equals(11, line)
    assert.equals("old", side)

    line, side = render.source_line(r, 3) -- the added row
    assert.equals(11, line)
    assert.equals("new", side)
  end)

  it("returns nil past the end", function()
    assert.is_nil((render.source_line(render.unified(FILE), 99)))
  end)
end)
