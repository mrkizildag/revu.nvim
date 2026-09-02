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
    -- context carries only its alignment prefix; no background highlight
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

    local widths = {}
    for _, m in pairs(by_row) do
      widths[#m.prefix_text] = true
    end
    assert.equals(1, vim.tbl_count(widths), "all prefixes must be the same width")
  end)

  it("puts nothing in the gutter by default, so the marker sits under the pill", function()
    for _, m in ipairs(render.unified(FILE).marks) do
      assert.is_nil(m.sign_text)
    end
  end)

  it("still supports gutter signs when configured", function()
    require("revu.config").setup({ signs = { add = "+", delete = "-" } })
    local found = false
    for _, m in ipairs(render.unified(FILE).marks) do
      if m.sign_text then
        found = true
      end
    end
    assert.is_true(found)
    require("revu.config").setup({})
  end)

  it("keeps markers out of the buffer text so an empty line stays empty", function()
    local f = parse(
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,2 +1,3 @@",
      " keep",
      "+",
      "+tail"
    )
    local r = render.unified(f)
    assert.equals("", r.lines[2], "an added blank line must render as a genuinely empty line")
    for _, l in ipairs(r.lines) do
      assert.is_nil(l:find("^[+-]"))
    end
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

describe("render.review", function()
  local A = parse(
    "diff --git a/a.lua b/a.lua",
    "--- a/a.lua",
    "+++ b/a.lua",
    "@@ -1,2 +1,2 @@",
    " keep",
    "-old",
    "+new"
  )
  local B = parse(
    "diff --git a/b.lua b/b.lua",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/b.lua",
    "@@ -0,0 +1 @@",
    "+fresh"
  )

  it("puts a three-row pill above each file", function()
    local r = render.review({ A, B })
    for row = 1, 3 do
      assert.equals("header", r.rows[row].kind)
      assert.equals("a.lua", r.rows[row].path)
    end
    -- the name lives on the middle row; rows 1 and 3 are borders
    assert.is_truthy(r.lines[2]:find("a.lua", 1, true))
    assert.is_nil(r.lines[1]:find("a.lua", 1, true))

    local second = render.header_row(r, 2)
    assert.equals("b.lua", r.rows[second].path)
    assert.is_truthy(r.lines[second]:find("b.lua", 1, true))
  end)

  it("tags every row with its file so a cursor row resolves to a path", function()
    local r = render.review({ A, B })
    for _, row in ipairs(r.rows) do
      assert.is_truthy(row.path)
      assert.is_truthy(row.file_index)
    end
  end)

  it("offsets marks and hunk headers into whole-review coordinates", function()
    local r = render.review({ A, B })
    for _, m in ipairs(r.marks) do
      assert.is_true(m.row < #r.lines)
    end
    for _, v in ipairs(r.virt) do
      assert.is_true(v.row < #r.lines, "hunk header must point at a real row")
      assert.are_not.equals("header", r.rows[v.row + 1].kind)
    end
  end)

  it("always renders every row, so folding cannot invalidate a position", function()
    local r = render.review({ A, B })
    local body = 0
    for _, row in ipairs(r.rows) do
      if row.kind ~= "header" then
        body = body + 1
      end
    end
    assert.is_true(body > 0, "bodies are always present; folds hide them, rows are not removed")
  end)

  it("levels the fold so it starts on the pill's bottom border", function()
    local r = render.review({ A, B })
    local levels = render.fold_levels(r.rows)
    assert.equals(#r.rows, #levels)

    for i, row in ipairs(r.rows) do
      if row.kind == "header" then
        -- the bottom border opens the fold, so a closed file still shows the pill
        assert.equals(row.part == "bottom" and ">1" or "0", levels[i], "row " .. i)
      else
        assert.equals("1", levels[i], "row " .. i)
      end
    end
  end)

  it("shows the collapsed chevron only when folded", function()
    local cfg = require("revu.config").options.header
    assert.is_truthy(render.header_lines(A, false, 80)[2].text:find(cfg.expanded, 1, true))
    assert.is_truthy(render.header_lines(A, true, 80)[2].text:find(cfg.collapsed, 1, true))
  end)

  it("counts additions and deletions per file", function()
    local adds, dels = render.stat(A)
    assert.equals(1, adds)
    assert.equals(1, dels)
    assert.is_truthy(render.header_lines(A, false, 80)[2].text:find("+1", 1, true))
  end)

  it("labels a binary file instead of counting lines", function()
    local bin = parse(
      "diff --git a/x.png b/x.png",
      "index 1..2 100644",
      "Binary files a/x.png and b/x.png differ"
    )
    assert.is_truthy(render.header_lines(bin, false, 80)[2].text:find("binary", 1, true))
  end)
end)

describe("render.header_lines", function()
  local NESTED = parse(
    "diff --git a/lua/revu/ui/render.lua b/lua/revu/ui/render.lua",
    "--- a/lua/revu/ui/render.lua",
    "+++ b/lua/revu/ui/render.lua",
    "@@ -1,2 +1,3 @@",
    " keep",
    "-old",
    "+new"
  )

  it("is a three-line box", function()
    local h = render.header_lines(NESTED, false, 80)
    assert.equals(3, #h)
    local b = require("revu.config").options.header.borderchars
    assert.is_truthy(h[1].text:find("^" .. b[5]))
    assert.is_truthy(h[1].text:find(b[6] .. "$"))
    assert.is_truthy(h[3].text:find("^" .. b[8]))
    assert.is_truthy(h[3].text:find(b[7] .. "$"))
    assert.is_truthy(h[2].text:find("^" .. b[4]), "content row starts with a side border")
    assert.is_truthy(h[2].text:find(b[2] .. "$"), "content row ends with a side border")
  end)

  it("fills the given width exactly on every row", function()
    for _, w in ipairs({ 60, 80, 120, 200 }) do
      for i, line in ipairs(render.header_lines(NESTED, false, w)) do
        assert.equals(w, vim.fn.strdisplaywidth(line.text), ("width %d, row %d"):format(w, i))
      end
    end
  end)

  it("puts the path on the left and the counts on the right", function()
    local content = render.header_lines(NESTED, false, 100)[2].text
    local name_at = content:find("render.lua", 1, true)
    local add_at = content:find("+1", 1, true)
    assert.is_true(name_at < add_at, "filename should come before the counts")
    assert.is_true(add_at > 60, "counts should sit against the right edge")
  end)

  it("does not break when the window is narrower than the content", function()
    local h = render.header_lines(NESTED, false, 12)
    assert.equals(3, #h)
    assert.is_truthy(h[2].text:find("render.lua", 1, true))
  end)

  it("colours the directory, filename and counts separately", function()
    local content = render.header_lines(NESTED, false, 100)[2]
    local by_hl = {}
    for _, seg in ipairs(content.segments) do
      by_hl[seg.hl] = content.text:sub(seg.col + 1, seg.end_col)
    end
    assert.equals("lua/revu/ui/", by_hl.RevuHeaderDir)
    assert.equals("render.lua", by_hl.RevuHeaderName)
    assert.is_truthy(by_hl.RevuHeaderAdd:find("+1", 1, true))
    assert.is_truthy(by_hl.RevuHeaderDelete:find("−1", 1, true))
  end)

  it("omits the directory segment for a top-level file", function()
    local top = parse(
      "diff --git a/init.lua b/init.lua",
      "--- a/init.lua",
      "+++ b/init.lua",
      "@@ -1 +1 @@",
      "-a",
      "+b"
    )
    for _, seg in ipairs(render.header_lines(top, false, 100)[2].segments) do
      assert.are_not.equals("RevuHeaderDir", seg.hl)
    end
  end)

  it("keeps segment offsets inside their row", function()
    for _, line in ipairs(render.header_lines(NESTED, false, 100)) do
      for _, seg in ipairs(line.segments) do
        assert.is_true(seg.col >= 0 and seg.end_col <= #line.text, seg.hl .. " out of range")
      end
    end
  end)
end)

describe("cursor landing", function()
  -- top, body, bottom, then two diff rows, then another pill
  local ROWS = {
    { kind = "header", part = "top" },
    { kind = "header", part = "body" },
    { kind = "header", part = "bottom" },
    { kind = "context" },
    { kind = "add" },
    { kind = "header", part = "top" },
    { kind = "header", part = "body" },
    { kind = "header", part = "bottom" },
  }

  it("allows diff rows and the pill's content row only", function()
    assert.is_false(render.is_landable(ROWS[1]))
    assert.is_true(render.is_landable(ROWS[2]))
    assert.is_false(render.is_landable(ROWS[3]))
    assert.is_true(render.is_landable(ROWS[4]))
    assert.is_true(render.is_landable(ROWS[5]))
    assert.is_false(render.is_landable(nil))
  end)

  it("continues downward when travelling down onto a border", function()
    assert.equals(2, render.next_landable(ROWS, 1, 1))
    assert.equals(4, render.next_landable(ROWS, 3, 1))
    assert.equals(7, render.next_landable(ROWS, 6, 1))
  end)

  it("continues upward when travelling up onto a border", function()
    assert.equals(5, render.next_landable(ROWS, 6, -1))
    assert.equals(7, render.next_landable(ROWS, 8, -1))
    assert.equals(2, render.next_landable(ROWS, 3, -1))
  end)

  it("turns around rather than parking on a border at either end", function()
    -- row 1 is a border and there is nothing above it
    assert.equals(2, render.next_landable(ROWS, 1, -1))
    -- row 8 is a border and there is nothing below it
    assert.equals(7, render.next_landable(ROWS, 8, 1))
  end)

  it("returns nil when nothing at all is landable", function()
    local all_borders = { { kind = "header", part = "top" }, { kind = "header", part = "bottom" } }
    assert.is_nil(render.next_landable(all_borders, 1, 1))
  end)
end)

describe("render.split", function()
  local A = parse(
    "diff --git a/a.lua b/a.lua",
    "--- a/a.lua",
    "+++ b/a.lua",
    "@@ -1,3 +1,3 @@",
    " keep",
    "-old one",
    "-old two",
    "+new one"
  )

  it("gives both sides exactly the same number of rows", function()
    local sp = render.split({ A }, 80)
    assert.equals(#sp.old.lines, #sp.new.lines)
    assert.equals(#sp.old.rows, #sp.new.rows)
  end)

  it("pads the side that has no counterpart", function()
    local sp = render.split({ A }, 80)

    local kinds = { old = {}, new = {} }
    for i = 1, #sp.old.rows do
      if sp.old.rows[i].kind ~= "header" then
        table.insert(kinds.old, sp.old.rows[i].kind)
        table.insert(kinds.new, sp.new.rows[i].kind)
      end
    end

    assert.same({ "context", "del", "del", "filler" }, kinds.old)
    assert.same({ "context", "filler", "filler", "add" }, kinds.new)
  end)

  it("keeps deletions on the old side and additions on the new", function()
    local sp = render.split({ A }, 80)
    for i, row in ipairs(sp.old.rows) do
      assert.are_not.equals("add", row.kind, "an addition must not appear on the old side")
      assert.are_not.equals(
        "del",
        sp.new.rows[i].kind,
        "a deletion must not appear on the new side"
      )
    end
  end)

  it("numbers each side against its own file", function()
    local sp = render.split({ A }, 80)
    for i, row in ipairs(sp.old.rows) do
      if row.kind == "del" or row.kind == "context" then
        assert.is_truthy(row.old_line)
      end
      local n = sp.new.rows[i]
      if n.kind == "add" or n.kind == "context" then
        assert.is_truthy(n.new_line)
      end
    end
  end)

  it("repeats the pill on both sides so the rows stay aligned", function()
    local sp = render.split({ A }, 80)
    for i = 1, 3 do
      assert.equals("header", sp.old.rows[i].kind)
      assert.equals("header", sp.new.rows[i].kind)
      assert.equals(sp.old.lines[i], sp.new.lines[i])
    end
  end)

  it("stays aligned across several files of different sizes", function()
    local B = parse(
      "diff --git a/b.lua b/b.lua",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/b.lua",
      "@@ -0,0 +1,3 @@",
      "+one",
      "+two",
      "+three"
    )
    local sp = render.split({ A, B }, 80)
    assert.equals(#sp.old.lines, #sp.new.lines)
    for i = 1, #sp.old.rows do
      assert.equals(
        sp.old.rows[i].path,
        sp.new.rows[i].path,
        "row " .. i .. " must describe the same file"
      )
    end
  end)

  it("reads the same model the unified view does", function()
    -- one parse, two renderers: if this ever needs its own parse the model is wrong
    local files = { A }
    local unified = render.review(files, 80)
    local sp = render.split(files, 80)
    assert.is_truthy(unified.rows[1].path)
    assert.equals(unified.rows[1].path, sp.old.rows[1].path)
  end)
end)
