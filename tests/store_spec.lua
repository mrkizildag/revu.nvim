local store_factory = require("revu.store")

--- A throwaway directory that looks enough like a repo for the store.
---@param opts? { git?: boolean }
local function tmp_repo(opts)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  if (opts or {}).git ~= false then
    vim.fn.mkdir(dir .. "/.git", "p")
  end
  return dir
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function sample(t)
  return vim.tbl_extend("keep", t or {}, {
    path = "lua/a.lua",
    line = 10,
    body = "needs a guard",
    anchor = "local ok = pcall(f)",
    context = { "before", "after" },
  })
end

describe("store: crud", function()
  it("adds a comment and fills in defaults", function()
    local s = store_factory.new(tmp_repo())
    local c, err = s:add(sample())

    assert.is_nil(err)
    assert.is_truthy(c.id)
    assert.equals("new", c.side)
    assert.equals("open", c.status)
    assert.is_truthy(c.created_at:match("^%d%d%d%d%-%d%d%-%d%dT"))
    assert.equals(1, #s:list())
  end)

  it("gives each comment a distinct id", function()
    local s = store_factory.new(tmp_repo())
    local seen = {}
    for i = 1, 50 do
      local c = s:add(sample({ line = i }))
      assert.is_nil(seen[c.id], "duplicate id: " .. tostring(c.id))
      seen[c.id] = true
    end
  end)

  it("gets by id and returns nil for an unknown one", function()
    local s = store_factory.new(tmp_repo())
    local c = s:add(sample())
    assert.equals(c.id, s:get(c.id).id)
    assert.is_nil(s:get("nope"))
  end)

  it("updates a comment without letting the id change", function()
    local s = store_factory.new(tmp_repo())
    local c = s:add(sample())

    local updated, err = s:update(c.id, { body = "rewritten", status = "resolved", id = "hacked" })
    assert.is_nil(err)
    assert.equals("rewritten", updated.body)
    assert.equals("resolved", updated.status)
    assert.equals(c.id, updated.id)
  end)

  it("removes a comment", function()
    local s = store_factory.new(tmp_repo())
    local c = s:add(sample())
    assert.is_true((s:remove(c.id)))
    assert.equals(0, #s:list())
    assert.is_false((s:remove(c.id)))
  end)

  it("filters by path, side and status", function()
    local s = store_factory.new(tmp_repo())
    s:add(sample({ path = "a.lua", line = 1 }))
    s:add(sample({ path = "b.lua", line = 2, side = "old" }))
    local c = s:add(sample({ path = "a.lua", line = 3 }))
    s:update(c.id, { status = "resolved" })

    assert.equals(2, #s:list({ path = "a.lua" }))
    assert.equals(1, #s:list({ side = "old" }))
    assert.equals(1, #s:list({ status = "resolved" }))
    assert.equals(1, #s:list({ path = "a.lua", status = "open" }))
  end)
end)

describe("store: validation", function()
  local cases = {
    { name = "missing path", patch = { path = nil } },
    { name = "empty path", patch = { path = "" } },
    { name = "zero line", patch = { line = 0 } },
    { name = "fractional line", patch = { line = 1.5 } },
    { name = "blank body", patch = { body = "   " } },
    { name = "bad side", patch = { side = "middle" } },
    { name = "bad status", patch = { status = "maybe" } },
  }

  for _, case in ipairs(cases) do
    it("rejects " .. case.name, function()
      local s = store_factory.new(tmp_repo())
      local c = vim.tbl_extend("force", sample(), case.patch)
      if case.patch.path == nil and case.name == "missing path" then
        c.path = nil
      end
      local added, err = s:add(c)
      assert.is_nil(added)
      assert.is_truthy(err)
      assert.equals(0, #s:list())
    end)
  end

  it("rejects an update that would make the comment invalid", function()
    local s = store_factory.new(tmp_repo())
    local c = s:add(sample())
    local updated, err = s:update(c.id, { body = "" })
    assert.is_nil(updated)
    assert.is_truthy(err)
    assert.equals("needs a guard", s:get(c.id).body)
  end)
end)

describe("store: persistence", function()
  it("round trips through disk unchanged", function()
    local root = tmp_repo()
    local a = store_factory.new(root)
    a:add(sample({ line = 1, body = "one" }))
    a:add(sample({ path = "b.lua", line = 2, body = "two", side = "old" }))

    local b = store_factory.new(root)
    local ok, err = b:load()
    assert.is_true(ok)
    assert.is_nil(err)
    assert.same(a:list(), b:list())
  end)

  it("treats a missing file as an empty store, not an error", function()
    local s = store_factory.new(tmp_repo())
    local ok, err = s:load()
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(0, #s:list())
  end)

  it("returns an error for corrupt json without crashing", function()
    local root = tmp_repo()
    vim.fn.mkdir(root .. "/.revu", "p")
    local f = assert(io.open(root .. "/.revu/comments.json", "w"))
    f:write("{ this is not json ")
    f:close()

    local s = store_factory.new(root)
    local ok, err = s:load()
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.equals(0, #s:list())
  end)

  it("drops malformed entries but keeps valid ones", function()
    local root = tmp_repo()
    vim.fn.mkdir(root .. "/.revu", "p")
    local f = assert(io.open(root .. "/.revu/comments.json", "w"))
    f:write(vim.json.encode({
      { id = "good", path = "a.lua", line = 1, body = "fine", side = "new", status = "open" },
      { id = "bad", path = "", line = 1, body = "broken" },
    }))
    f:close()

    local s = store_factory.new(root)
    s:load()
    assert.equals(1, #s:list())
    assert.equals("good", s:list()[1].id)
  end)

  it("regenerates comments.md on every write", function()
    local root = tmp_repo()
    local s = store_factory.new(root)
    s:add(sample({ body = "first note" }))
    assert.is_truthy(read(root .. "/.revu/comments.md"):find("first note", 1, true))

    local c = s:list()[1]
    s:update(c.id, { body = "second note" })
    local md = read(root .. "/.revu/comments.md")
    assert.is_truthy(md:find("second note", 1, true))
    assert.is_nil(md:find("first note", 1, true))
  end)

  it("notifies subscribers on write", function()
    local s = store_factory.new(tmp_repo())
    local fired = 0
    s:on_change(function()
      fired = fired + 1
    end)
    local c = s:add(sample())
    s:update(c.id, { body = "changed" })
    s:remove(c.id)
    assert.equals(3, fired)
  end)
end)

describe("store: git exclude", function()
  it("adds .revu/ to .git/info/exclude exactly once across repeated writes", function()
    local root = tmp_repo()
    local s = store_factory.new(root)
    for i = 1, 5 do
      s:add(sample({ line = i }))
    end

    local contents = read(root .. "/.git/info/exclude")
    local count = 0
    for line in contents:gmatch("[^\n]+") do
      if line == ".revu/" then
        count = count + 1
      end
    end
    assert.equals(1, count)
  end)

  it("preserves existing exclude entries and does not glue lines together", function()
    local root = tmp_repo()
    vim.fn.mkdir(root .. "/.git/info", "p")
    local f = assert(io.open(root .. "/.git/info/exclude", "w"))
    f:write("*.log") -- deliberately no trailing newline
    f:close()

    store_factory.new(root):add(sample())

    local contents = read(root .. "/.git/info/exclude")
    assert.is_truthy(contents:find("\n%.revu/"))
    local first = contents:match("^[^\n]*")
    assert.equals("*.log", first)
  end)

  it("works in a directory that is not a git repo", function()
    local s = store_factory.new(tmp_repo({ git = false }))
    local c, err = s:add(sample())
    assert.is_nil(err)
    assert.is_truthy(c)
  end)
end)
