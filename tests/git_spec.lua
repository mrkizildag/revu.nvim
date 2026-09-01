local git = require("revu.git")

local function sh(cmd, cwd)
  return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

--- A repo with one commit, one modification, and untracked files including a nested one
--- and an ignored one.
local function repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  sh({ "git", "init", "-q", "-b", "main" }, dir)
  sh({ "git", "config", "user.email", "t@t" }, dir)
  sh({ "git", "config", "user.name", "t" }, dir)

  vim.fn.writefile({ "tracked one" }, dir .. "/tracked.txt")
  vim.fn.writefile({ "*.log" }, dir .. "/.gitignore")
  sh({ "git", "add", "-A" }, dir)
  sh({ "git", "commit", "-qm", "init" }, dir)

  vim.fn.writefile({ "tracked one", "tracked two" }, dir .. "/tracked.txt")
  vim.fn.writefile({ "brand new", "second line" }, dir .. "/new.txt")
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.writefile({ "nested new" }, dir .. "/sub/deep.txt")
  vim.fn.writefile({ "noise" }, dir .. "/build.log")
  return dir
end

describe("git.untracked", function()
  it("lists untracked files, including inside new directories", function()
    local files = git.untracked(repo())
    table.sort(files)
    assert.same({ "new.txt", "sub/deep.txt" }, files)
  end)

  it("excludes gitignored files", function()
    local files = git.untracked(repo())
    for _, f in ipairs(files) do
      assert.is_nil(f:find("%.log$"), "ignored file leaked into the list: " .. f)
    end
  end)

  it("returns an empty list in a clean repo", function()
    local dir = repo()
    sh({ "git", "add", "-A" }, dir)
    sh({ "git", "commit", "-qm", "all" }, dir)
    assert.same({}, git.untracked(dir))
  end)
end)

describe("git.diff_untracked", function()
  it("produces an addition diff despite --no-index exiting 1", function()
    local out, err = git.diff_untracked("new.txt", repo())
    assert.is_nil(err)
    assert.is_truthy(out:find("new file mode", 1, true))
    assert.is_truthy(out:find("--- /dev/null", 1, true))
    assert.is_truthy(out:find("+brand new", 1, true))
  end)
end)

describe("git.diff_untracked binary", function()
  it("reports a binary untracked file as binary rather than emitting garbage", function()
    local dir = repo()
    local f = assert(io.open(dir .. "/blob.bin", "wb"))
    f:write("\0\1\2\3binary\0content")
    f:close()

    local out = git.diff_untracked("blob.bin", dir)
    assert.is_truthy(out:find("Binary files", 1, true), "expected a binary marker")

    local parsed = require("revu.diff").parse(out)[1]
    assert.is_true(parsed.binary)
    assert.equals(0, #parsed.hunks)
  end)
end)

describe("git.compares_worktree", function()
  it("is true for a plain revision and false for a range", function()
    assert.is_true(git.compares_worktree("HEAD"))
    assert.is_true(git.compares_worktree("abc1234"))
    assert.is_false(git.compares_worktree("main...HEAD"))
    assert.is_false(git.compares_worktree("main..HEAD"))
  end)
end)

describe("git.diff with untracked", function()
  local diff = require("revu.diff")

  it("includes untracked files by default", function()
    local raw = git.diff("HEAD", repo())
    local paths = {}
    for _, f in ipairs(diff.parse(raw)) do
      paths[f.path] = f.status
    end
    assert.equals("modified", paths["tracked.txt"])
    assert.equals("added", paths["new.txt"])
    assert.equals("added", paths["sub/deep.txt"])
    assert.is_nil(paths["build.log"])
  end)

  it("marks every line of an untracked file as an addition", function()
    local raw = git.diff("HEAD", repo())
    for _, f in ipairs(diff.parse(raw)) do
      if f.path == "new.txt" then
        local kinds = {}
        for _, h in ipairs(f.hunks) do
          for _, l in ipairs(h.lines) do
            table.insert(kinds, l.kind)
          end
        end
        assert.same({ "add", "add" }, kinds)
        return
      end
    end
    error("new.txt not found in the diff")
  end)

  it("can be turned off", function()
    local raw = git.diff("HEAD", repo(), { untracked = false })
    for _, f in ipairs(diff.parse(raw)) do
      assert.are_not.equals("new.txt", f.path)
    end
  end)

  it("never includes untracked files for a commit range", function()
    local dir = repo()
    sh({ "git", "commit", "-qam", "second" }, dir)
    local raw = git.diff("main...HEAD", dir)
    for _, f in ipairs(diff.parse(raw)) do
      assert.are_not.equals("new.txt", f.path)
    end
  end)
end)
