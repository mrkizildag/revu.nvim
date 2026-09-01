local view = require("revu.ui.view")

local function sh(cmd, cwd)
  return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

--- A real git repo with one commit and uncommitted changes.
local function repo_with_changes()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  sh({ "git", "init", "-q", "-b", "main" }, dir)
  sh({ "git", "config", "user.email", "t@t" }, dir)
  sh({ "git", "config", "user.name", "t" }, dir)

  vim.fn.writefile(
    { "local M = {}", "", "function M.go()", "  return 1", "end", "", "return M" },
    dir .. "/a.lua"
  )
  vim.fn.writefile({ "print('b')" }, dir .. "/b.lua")
  sh({ "git", "add", "-A" }, dir)
  sh({ "git", "commit", "-qm", "init" }, dir)

  -- modify one file, add another
  vim.fn.writefile(
    { "local M = {}", "", "function M.go()", "  return 2", "end", "", "return M" },
    dir .. "/a.lua"
  )
  vim.fn.writefile({ "print('new file')" }, dir .. "/c.lua")
  sh({ "git", "add", "-A" }, dir)
  return dir
end

local function current_buf_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe("view.open", function()
  local dir

  before_each(function()
    require("revu.config").setup({})
    require("revu.ui.highlights").apply()
    dir = repo_with_changes()
  end)

  after_each(function()
    if view.is_open() then
      view.close()
    end
  end)

  it("opens a session with every changed file", function()
    local ok, err = view.open("HEAD", dir)
    assert.is_true(ok, tostring(err))
    assert.is_true(view.is_open())
    assert.equals(2, #view.session().files) -- a.lua modified, c.lua added
  end)

  it("creates a scratch buffer that cannot be edited", function()
    view.open("HEAD", dir)
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("nofile", vim.bo[buf].buftype)
    assert.equals("wipe", vim.bo[buf].bufhidden)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].swapfile)
  end)

  it("sets the filetype from the reviewed path so treesitter attaches", function()
    view.open("HEAD", dir)
    assert.equals("lua", vim.bo[vim.api.nvim_get_current_buf()].filetype)
  end)

  it("puts no diff punctuation in the buffer", function()
    view.open("HEAD", dir)
    for _, l in ipairs(current_buf_lines()) do
      assert.is_nil(l:find("^@@"))
      assert.is_nil(l:find("^%+%+%+"))
    end
  end)

  it("applies line and sign extmarks for changed rows", function()
    view.open("HEAD", dir)
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_get_namespaces()["revu_diff"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

    local line_hls, virt = 0, 0
    for _, m in ipairs(marks) do
      if m[4].line_hl_group then
        line_hls = line_hls + 1
      end
      if m[4].virt_lines then
        virt = virt + 1
      end
    end
    assert.is_true(line_hls > 0, "expected add/delete line highlights")
    assert.is_true(virt > 0, "expected a hunk header as a virtual line")
  end)

  it("draws +/- as inline virtual text, not buffer content", function()
    view.open("HEAD", dir)
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_get_namespaces()["revu_diff"]

    local inline = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text then
        assert.equals("inline", m[4].virt_text_pos)
        inline = inline + 1
      end
    end
    assert.is_true(inline > 0, "expected inline +/- prefixes")

    -- The guarantee that matters: the prefix is not in the text, so yanking a line gives
    -- back real code rather than diff punctuation.
    for _, l in ipairs(current_buf_lines()) do
      assert.is_nil(l:find("^[+-] "))
    end
  end)

  it("reports an error rather than opening when there are no changes", function()
    sh({ "git", "commit", "-qam", "all done" }, dir)
    local ok, err = view.open("HEAD", dir)
    assert.is_false(ok)
    assert.is_truthy(err:find("no changes", 1, true))
    assert.is_false(view.is_open())
  end)

  it("reports an error outside a git repository", function()
    local plain = vim.fn.tempname()
    vim.fn.mkdir(plain, "p")
    local ok, err = view.open("HEAD", plain)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)
end)

describe("view.cycle", function()
  it("moves between files and wraps around", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    local first = view.session().index
    view.cycle(1)
    assert.are_not.equals(first, view.session().index)
    view.cycle(1)
    assert.equals(first, view.session().index, "should wrap with two files")

    view.close()
  end)
end)

describe("view.close", function()
  it("drops the session and its tab", function()
    local dir = repo_with_changes()
    local tabs_before = #vim.api.nvim_list_tabpages()
    view.open("HEAD", dir)
    assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())

    view.close()
    assert.is_false(view.is_open())
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
  end)
end)
