local view = require("revu.ui.view")
local render = require("revu.ui.render")

local function sh(cmd, cwd)
  return vim.system(cmd, { cwd = cwd, text = true }):wait()
end

local function repo_with_changes()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  sh({ "git", "init", "-q", "-b", "main" }, dir)
  sh({ "git", "config", "user.email", "t@t" }, dir)
  sh({ "git", "config", "user.name", "t" }, dir)

  vim.fn.writefile({ "local M = {}", "", "function M.go()", "  return 1", "end" }, dir .. "/a.lua")
  vim.fn.writefile({ "print('b')" }, dir .. "/b.lua")
  sh({ "git", "add", "-A" }, dir)
  sh({ "git", "commit", "-qm", "init" }, dir)

  vim.fn.writefile({ "local M = {}", "", "function M.go()", "  return 2", "end" }, dir .. "/a.lua")
  vim.fn.writefile({ "print('new')" }, dir .. "/c.lua")
  return dir
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe("view.open", function()
  local dir

  before_each(function()
    require("revu.config").setup({})
    dir = repo_with_changes()
  end)

  after_each(function()
    if view.is_open() then
      view.close()
    end
  end)

  it("opens in the current window without creating a tab", function()
    local tabs = #vim.api.nvim_list_tabpages()
    assert.is_true((view.open("HEAD", dir)))
    assert.equals(tabs, #vim.api.nvim_list_tabpages())
  end)

  it("remembers the buffer it replaced", function()
    local before = vim.api.nvim_get_current_buf()
    view.open("HEAD", dir)
    assert.equals(before, view.session().prev_buf)
  end)

  it("does not name the buffer like a path", function()
    view.open("HEAD", dir)
    -- `revu://<rev>/<path>` got shortened to nonsense in the tabline; the review buffer
    -- carries no name at all now.
    assert.equals("", vim.api.nvim_buf_get_name(0))
    assert.equals("revu", vim.bo.filetype)
  end)

  it("puts every changed file in one buffer", function()
    view.open("HEAD", dir)
    local headers = 0
    for _, r in ipairs(view.session().render.rows) do
      if r.kind == "header" then
        headers = headers + 1
      end
    end
    assert.equals(#view.session().files, headers)
    assert.is_true(headers >= 2)
  end)

  it("renders a header row with a chevron, path and stat", function()
    view.open("HEAD", dir)
    local first = lines()[1]
    assert.is_truthy(first:find("▾", 1, true), "expanded chevron")
    assert.is_truthy(first:find("╭─", 1, true), "rounded corner")
    assert.is_truthy(first:find("%+%d"), "add count")
  end)
end)

describe("view.toggle", function()
  it("folds a file section shut and back open", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    local expanded = #lines()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    view.toggle()

    local collapsed = #lines()
    assert.is_true(collapsed < expanded, "collapsing should remove rows")
    assert.is_truthy(lines()[1]:find("▸", 1, true), "chevron should flip")

    view.toggle()
    assert.equals(expanded, #lines())
    assert.is_truthy(lines()[1]:find("▾", 1, true))

    view.close()
  end)

  it("keeps the cursor on the header it toggled", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    view.toggle()
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    view.close()
  end)

  it("toggles from a body row, not just the header", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    local before = #lines()
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- inside the first file's diff
    view.toggle()
    assert.is_true(#lines() < before)

    view.close()
  end)
end)

describe("view.jump_file", function()
  it("moves between headers and wraps", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    view.jump_file(1)
    local second = vim.api.nvim_win_get_cursor(0)[1]
    assert.is_true(second > 1)
    assert.equals("header", view.session().render.rows[second].kind)

    view.jump_file(-1)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])

    view.close()
  end)
end)

describe("view.close", function()
  it("restores the buffer that was there before", function()
    local dir = repo_with_changes()
    local before = vim.api.nvim_get_current_buf()
    view.open("HEAD", dir)
    assert.are_not.equals(before, vim.api.nvim_get_current_buf())

    view.close()
    assert.equals(before, vim.api.nvim_get_current_buf())
    assert.is_false(view.is_open())
  end)
end)

describe("view.open_file", function()
  it("opens the real file at the reviewed line", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    -- find a row that maps to a source line in a.lua
    local target
    for i, r in ipairs(view.session().render.rows) do
      if r.path == "a.lua" and r.kind ~= "header" and (r.new_line or r.old_line) then
        target = i
        break
      end
    end
    assert.is_truthy(target)

    vim.api.nvim_win_set_cursor(0, { target, 0 })
    local expected = render.source_line(view.session().render, target)
    view.open_file()

    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("a.lua", 1, true))
    assert.equals(expected, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)
