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
    local seen = {}
    for _, r in ipairs(view.session().render.rows) do
      if r.kind == "header" then
        seen[r.path] = (seen[r.path] or 0) + 1
      end
    end
    assert.equals(#view.session().files, vim.tbl_count(seen))
    assert.is_true(vim.tbl_count(seen) >= 2)
    for path, rows in pairs(seen) do
      assert.equals(3, rows, path .. " should have a three-row pill")
    end
  end)

  it("sizes the pill to the text area, not the window", function()
    view.open("HEAD", dir)
    local win = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(win)[1]
    local usable = vim.api.nvim_win_get_width(win) - info.textoff

    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if view.session().render.rows[i].kind == "header" then
        assert.equals(
          usable,
          vim.fn.strdisplaywidth(l),
          "pill row " .. i .. " must fit the text area"
        )
      end
    end
  end)

  it("renders a bordered pill with the path left and counts right", function()
    view.open("HEAD", dir)
    local l = lines()
    assert.is_truthy(l[1]:find("^╭"), "top border")
    assert.is_truthy(l[2]:find("▾", 1, true), "expanded chevron on the content row")
    assert.is_truthy(l[2]:find("%+%d"), "add count")
    assert.is_truthy(l[3]:find("^╰"), "bottom border")
    assert.is_true(l[2]:find("%+%d") > l[2]:find("%.lua"), "counts right of the filename")
  end)

  it("draws +/- in the sign column, outside the text area", function()
    view.open("HEAD", dir)
    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_get_namespaces()["revu_diff"]

    local signs, inline = 0, 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].sign_text then
        signs = signs + 1
      end
      if m[4].virt_text then
        inline = inline + 1
      end
    end

    assert.is_true(signs > 0, "expected +/- in the gutter")
    assert.equals(0, inline, "nothing inline for the cursor to travel through")
    assert.equals("yes", vim.wo.signcolumn)

    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      assert.is_nil(l:find("^[+-] "))
    end
  end)

  it("points at the branch diff when the tree is clean but the branch is ahead", function()
    sh({ "git", "switch", "-qc", "feature" }, dir)
    sh({ "git", "add", "-A" }, dir)
    sh({ "git", "commit", "-qm", "committed work" }, dir)

    local ok, err = view.open("HEAD", dir)
    assert.is_false(ok)
    assert.is_truthy(err:find("working tree is clean", 1, true))
    assert.is_truthy(err:find("main...HEAD", 1, true), "should name the command that works")
  end)

  it("reports plainly when there is nothing to review anywhere", function()
    sh({ "git", "add", "-A" }, dir)
    sh({ "git", "commit", "-qm", "all done" }, dir)

    local ok, err = view.open("HEAD", dir)
    assert.is_false(ok)
    assert.is_truthy(err:find("no changes", 1, true))
    -- on the base branch there is no better command to suggest
    assert.is_nil(err:find("try", 1, true))
  end)

  it("reports an error outside a git repository", function()
    local plain = vim.fn.tempname()
    vim.fn.mkdir(plain, "p")
    local ok, err = view.open("HEAD", plain)
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.is_false(view.is_open())
  end)
end)

describe("view.toggle", function()
  it("folds a file section shut and back open", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    local expanded = #lines()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.toggle()

    local collapsed = #lines()
    assert.is_true(collapsed < expanded, "collapsing should remove rows")
    assert.is_truthy(lines()[2]:find("▸", 1, true), "chevron should flip")

    view.toggle()
    assert.equals(expanded, #lines())
    assert.is_truthy(lines()[2]:find("▾", 1, true))

    view.close()
  end)

  it("keeps the cursor on the header it toggled", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.toggle()
    -- back on the content row of the pill it toggled, not its top border
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    view.close()
  end)

  it("toggles from a body row, not just the header", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    local before = #lines()
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- inside the first file's diff, past the pill
    view.toggle()
    assert.is_true(#lines() < before)

    view.close()
  end)
end)

describe("cursor skipping borders", function()
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

  --- CursorMoved does not fire under headless feedkeys, so drive the handler the way the
  --- autocmd would and assert on where it puts the cursor.
  local function land_on(row, coming_from)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    view.session().last_row = coming_from
    vim.cmd("doautocmd CursorMoved")
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  it("starts on the first pill's content row, not its border", function()
    view.open("HEAD", dir)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    assert.equals("body", view.session().render.rows[row].part)
  end)

  it("moves off a top border downward when travelling down", function()
    view.open("HEAD", dir)
    assert.equals("body", view.session().render.rows[land_on(1, 0)].part)
  end)

  it("moves off a bottom border downward when travelling down", function()
    view.open("HEAD", dir)
    local landed = land_on(3, 2)
    assert.is_true(render.is_landable(view.session().render.rows[landed]))
    assert.is_true(landed > 3)
  end)

  it("moves off a bottom border upward when travelling up", function()
    view.open("HEAD", dir)
    assert.equals(2, land_on(3, 4))
  end)

  it("leaves a legitimate row alone", function()
    view.open("HEAD", dir)
    local rows = view.session().render.rows
    local body
    for i, r in ipairs(rows) do
      if r.kind == "context" or r.kind == "add" then
        body = i
        break
      end
    end
    assert.equals(body, land_on(body, body - 1))
  end)
end)

describe("view.jump_file", function()
  it("moves between headers and wraps", function()
    local dir = repo_with_changes()
    view.open("HEAD", dir)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.jump_file(1)
    local second = vim.api.nvim_win_get_cursor(0)[1]
    assert.is_true(second > 2)
    assert.equals("header", view.session().render.rows[second].kind)

    view.jump_file(-1)
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

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

describe("returning to the review", function()
  local dir

  before_each(function()
    require("revu.config").setup({})
    dir = repo_with_changes()
  end)

  after_each(function()
    view.close()
  end)

  local function first_body_row()
    for i, r in ipairs(view.session().render.rows) do
      if r.kind ~= "header" and (r.new_line or r.old_line) then
        return i
      end
    end
  end

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "nx", false)
  end

  it("keeps the review buffer alive when something replaces it", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    assert.equals("hide", vim.bo[rbuf].bufhidden)

    vim.api.nvim_win_set_cursor(0, { first_body_row(), 0 })
    view.open_file()

    assert.are_not.equals(rbuf, vim.api.nvim_get_current_buf())
    assert.is_true(vim.api.nvim_buf_is_valid(rbuf), "the review must survive the jump")
  end)

  it("returns to the row it was left on", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    local row = first_body_row()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.open_file()
    press("<C-o>")

    assert.equals(rbuf, vim.api.nvim_get_current_buf())
    assert.equals(row, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("walks back through several jumps", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { first_body_row(), 0 })

    view.open_file() -- review -> a.lua
    press("G") -- a jump within the file
    press("<C-o>") -- back to where we entered a.lua
    assert.are_not.equals(rbuf, vim.api.nvim_get_current_buf())

    press("<C-o>") -- and back into the review
    assert.equals(rbuf, vim.api.nvim_get_current_buf())
  end)

  it("hide keeps the session so :Revu comes back to the same place", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    local row = first_body_row()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.hide()
    assert.are_not.equals(rbuf, vim.api.nvim_get_current_buf())
    assert.is_true(vim.api.nvim_buf_is_valid(rbuf))

    view.open("HEAD", dir)
    assert.equals(rbuf, vim.api.nvim_get_current_buf(), "should reuse, not rebuild")
    assert.equals(row, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("does not leak a buffer per :Revu", function()
    local function revu_buffers()
      local n = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "revu" then
          n = n + 1
        end
      end
      return n
    end

    local before = revu_buffers()
    view.open("HEAD", dir)
    view.hide()
    view.open("HEAD", dir)
    view.hide()
    view.open("HEAD", dir)
    assert.equals(before + 1, revu_buffers())
  end)

  it("leaves exactly one jumplist entry for the review when jumping out", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { first_body_row(), 0 })

    view.open_file()

    -- `m'` records one; :edit must not add a second, or <C-o> stutters on the way back.
    local entries = 0
    for _, j in ipairs(vim.fn.getjumplist()[1]) do
      if j.bufnr == rbuf then
        entries = entries + 1
      end
    end
    assert.equals(1, entries)
  end)

  it("records the review position before leaving, not after", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    local row = first_body_row()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.open_file()

    for _, j in ipairs(vim.fn.getjumplist()[1]) do
      if j.bufnr == rbuf then
        assert.equals(row, j.lnum, "the entry must point at the row we left")
        return
      end
    end
    error("no jumplist entry for the review")
  end)

  -- Enable once #19 replaces row-removal with real vim folds. Collapsing currently
  -- rewrites the whole buffer, which destroys vim's position tracking: a jumplist entry
  -- below the fold is silently clamped, so <C-o> lands on unrelated content.
  pending("keeps stored positions valid across a fold (needs real folds, #19)")

  it("close discards the buffer even when the review is hidden", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    view.hide()

    view.close()
    assert.is_false(vim.api.nvim_buf_is_valid(rbuf))
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
