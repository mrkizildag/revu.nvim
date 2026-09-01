local diff = require("revu.diff")

--- Build a diff string from lines, so fixtures stay readable inline.
local function d(...)
  return table.concat({ ... }, "\n") .. "\n"
end

describe("diff.parse", function()
  it("numbers context, additions and deletions on the correct sides", function()
    local files = diff.parse(d(
      "diff --git a/a.lua b/a.lua",
      "index 111..222 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -10,3 +10,4 @@ function foo()",
      " keep1",
      "-gone",
      "+new1",
      "+new2",
      " keep2"
    ))

    assert.equals(1, #files)
    local f = files[1]
    assert.equals("a.lua", f.path)
    assert.equals("modified", f.status)
    assert.equals(1, #f.hunks)

    local h = f.hunks[1]
    assert.equals(10, h.old_start)
    assert.equals(10, h.new_start)
    assert.equals("function foo()", h.header)

    local kinds, olds, news = {}, {}, {}
    for _, l in ipairs(h.lines) do
      table.insert(kinds, l.kind)
      table.insert(olds, l.old_line or -1)
      table.insert(news, l.new_line or -1)
    end
    assert.same({ "context", "del", "add", "add", "context" }, kinds)
    -- old side advances on context+del only; new side on context+add only
    assert.same({ 10, 11, -1, -1, 12 }, olds)
    -- new side: context at 10 advances the counter, so the two adds are 11 and 12
    assert.same({ 10, -1, 11, 12, 13 }, news)
  end)

  it("detects an added file", function()
    local f = diff.parse(d(
      "diff --git a/new.lua b/new.lua",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/new.lua",
      "@@ -0,0 +1,2 @@",
      "+one",
      "+two"
    ))[1]
    assert.equals("added", f.status)
    assert.equals("new.lua", f.path)
    assert.equals(2, #f.hunks[1].lines)
  end)

  it("detects a deleted file and keeps its path", function()
    local f = diff.parse(d(
      "diff --git a/old.lua b/old.lua",
      "deleted file mode 100644",
      "--- a/old.lua",
      "+++ /dev/null",
      "@@ -1,2 +0,0 @@",
      "-one",
      "-two"
    ))[1]
    assert.equals("deleted", f.status)
    assert.equals("old.lua", f.path)
  end)

  it("detects a rename and records both paths", function()
    local f = diff.parse(d(
      "diff --git a/from.lua b/to.lua",
      "similarity index 95%",
      "rename from from.lua",
      "rename to to.lua",
      "--- a/from.lua",
      "+++ b/to.lua",
      "@@ -1 +1 @@",
      "-a",
      "+b"
    ))[1]
    assert.equals("renamed", f.status)
    assert.equals("to.lua", f.path)
    assert.equals("from.lua", f.old_path)
  end)

  it("flags binary files and adds no hunks", function()
    local f = diff.parse(d(
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ"
    ))[1]
    assert.is_true(f.binary)
    assert.equals(0, #f.hunks)
  end)

  it("ignores the no-newline marker without emitting a line", function()
    local f = diff.parse(d(
      "diff --git a/a.txt b/a.txt",
      "--- a/a.txt",
      "+++ b/a.txt",
      "@@ -1 +1 @@",
      "-old",
      "\\ No newline at end of file",
      "+new",
      "\\ No newline at end of file"
    ))[1]
    assert.equals(2, #f.hunks[1].lines)
    assert.same({ "del", "add" }, { f.hunks[1].lines[1].kind, f.hunks[1].lines[2].kind })
  end)

  it("treats a bare empty line inside a hunk as empty context", function()
    local f = diff.parse(d(
      "diff --git a/a.txt b/a.txt",
      "--- a/a.txt",
      "+++ b/a.txt",
      "@@ -1,3 +1,3 @@",
      " one",
      "",
      "+three"
    ))[1]
    local l = f.hunks[1].lines[2]
    assert.equals("context", l.kind)
    assert.equals("", l.text)
    assert.equals(2, l.old_line)
  end)

  it("parses multiple files and multiple hunks", function()
    local files = diff.parse(d(
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1 +1 @@",
      "-a",
      "+A",
      "@@ -10 +10 @@",
      "-b",
      "+B",
      "diff --git a/c.lua b/c.lua",
      "--- a/c.lua",
      "+++ b/c.lua",
      "@@ -5 +5 @@",
      "-c",
      "+C"
    ))
    assert.equals(2, #files)
    assert.equals(2, #files[1].hunks)
    assert.equals(1, #files[2].hunks)
    assert.equals(10, files[1].hunks[2].old_start)
  end)

  it("returns an empty list for empty input", function()
    assert.same({}, diff.parse(""))
    assert.same({}, diff.parse(nil))
  end)
end)

describe("diff.unified_rows", function()
  it("emits a hunk row before each hunk's lines", function()
    local f = diff.parse(d(
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,2 +1,2 @@ ctx",
      " keep",
      "-old",
      "+new"
    ))[1]
    local rows = diff.unified_rows(f)
    assert.equals("hunk", rows[1].kind)
    assert.same({ "hunk", "context", "del", "add" },
      { rows[1].kind, rows[2].kind, rows[3].kind, rows[4].kind })
  end)
end)
