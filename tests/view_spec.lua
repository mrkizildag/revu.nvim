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
  local dir

  before_each(function()
    require("revu.config").setup({})
    dir = repo_with_changes()
  end)

  after_each(function()
    view.close()
  end)

  --- The fold starts on the pill's bottom border, one row below the content row.
  local function fold_closed_for(file_index)
    local header = render.header_row(view.session().render, file_index)
    return vim.fn.foldclosed(header + 1) ~= -1
  end

  it("folds without removing rows, so stored positions stay valid", function()
    view.open("HEAD", dir)
    local rows_before = vim.api.nvim_buf_line_count(0)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.toggle()

    assert.is_true(fold_closed_for(1))
    assert.equals(rows_before, vim.api.nvim_buf_line_count(0), "rows must survive a fold")
  end)

  it("flips the chevron to match the fold state", function()
    view.open("HEAD", dir)
    local content = render.header_row(view.session().render, 1)

    vim.api.nvim_win_set_cursor(0, { content, 0 })
    view.toggle()
    assert.is_truthy(
      vim.api.nvim_buf_get_lines(0, content - 1, content, false)[1]:find("▸", 1, true)
    )

    view.toggle()
    assert.is_truthy(
      vim.api.nvim_buf_get_lines(0, content - 1, content, false)[1]:find("▾", 1, true)
    )
    assert.is_false(fold_closed_for(1))
  end)

  it("keeps the cursor on the header it toggled", function()
    view.open("HEAD", dir)
    local content = render.header_row(view.session().render, 1)
    vim.api.nvim_win_set_cursor(0, { content, 0 })
    view.toggle()
    assert.equals(content, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("toggles from a body row, not just the header", function()
    view.open("HEAD", dir)

    local body
    for i, r in ipairs(view.session().render.rows) do
      if r.file_index == 1 and r.kind ~= "header" then
        body = i
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { body, 0 })
    view.toggle()

    assert.is_true(fold_closed_for(1))
  end)

  it("collapses and expands every file at once", function()
    view.open("HEAD", dir)
    local files = #view.session().files
    assert.is_true(files >= 2)

    view.toggle_all(false)
    for i = 1, files do
      assert.is_true(fold_closed_for(i), "file " .. i .. " should be folded")
    end

    view.toggle_all(true)
    for i = 1, files do
      assert.is_false(fold_closed_for(i), "file " .. i .. " should be open")
    end
  end)

  it("shows the pill's bottom border as the fold line, not a line count", function()
    view.open("HEAD", dir)
    view.toggle_all(false)

    local header = render.header_row(view.session().render, 1)
    local start = vim.fn.foldclosed(header + 1)
    assert.are_not.equals(-1, start)

    -- foldtextresult asks vim what it would actually draw for that closed fold, which is
    -- the only way to exercise foldtext: v:foldstart is set only while vim renders one.
    local drawn = vim.fn.foldtextresult(start)
    assert.equals(vim.fn.getline(start), drawn)
    assert.is_truthy(drawn:find("╰", 1, true), "a folded file should read as a closed pill")
    assert.is_nil(drawn:find("lines"), "not vim's default '+-- N lines'")
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

describe("view.set_mode", function()
  local dir

  before_each(function()
    require("revu.config").setup({})
    dir = repo_with_changes()
  end)

  after_each(function()
    view.close()
  end)

  local function first_add()
    for i, r in ipairs(view.session().render.rows) do
      if r.kind == "add" and r.new_line then
        return i, r
      end
    end
  end

  it("splits into two bound windows", function()
    view.open("HEAD", dir)
    local wins = #vim.api.nvim_tabpage_list_wins(0)

    view.set_mode("split")
    assert.equals("split", view.session().mode)
    assert.equals(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_true(vim.wo.scrollbind)
    assert.is_true(vim.wo.cursorbind)
  end)

  it("gives both sides the same number of rows so binding cannot drift", function()
    view.open("HEAD", dir)
    view.set_mode("split")
    local s = view.session()
    assert.equals(#s.split.old.lines, #s.split.new.lines)
    assert.equals(vim.api.nvim_buf_line_count(s.bufs.old), vim.api.nvim_buf_line_count(s.bufs.new))
  end)

  it("keeps the cursor on the same source line across a round trip", function()
    view.open("HEAD", dir)
    local row, entry = first_add()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.set_mode("split")
    local s = view.session()
    local in_split = s.split.new.rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert.equals(entry.path, in_split.path)
    assert.equals(entry.new_line, in_split.new_line)

    view.set_mode("unified")
    local back = view.session().render.rows[vim.api.nvim_win_get_cursor(0)[1]]
    assert.equals(entry.path, back.path)
    assert.equals(entry.new_line, back.new_line)
  end)

  it("toggles when given no argument", function()
    view.open("HEAD", dir)
    view.set_mode()
    assert.equals("split", view.session().mode)
    view.set_mode()
    assert.equals("unified", view.session().mode)
  end)

  it("returns to a single window and cleans up the side buffers", function()
    view.open("HEAD", dir)
    view.set_mode("split")
    local s = view.session()
    local old_buf, new_buf = s.bufs.old, s.bufs.new

    view.set_mode("unified")
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(new_buf))
  end)

  it("does nothing when already in the requested mode", function()
    view.open("HEAD", dir)
    local buf = vim.api.nvim_get_current_buf()
    view.set_mode("unified")
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
  end)
end)

describe("comments", function()
  local dir

  before_each(function()
    require("revu.config").setup({})
    dir = repo_with_changes()
  end)

  after_each(function()
    view.close()
  end)

  local COMMENT_NS = vim.api.nvim_create_namespace("revu_comments")

  --- Add a comment against the first added line, the way M.comment does.
  local function add(body)
    local s = view.session()
    for i, r in ipairs(s.render.rows) do
      if r.kind == "add" and r.new_line then
        local file = vim.fn.readfile(s.root .. "/" .. r.path)
        local c = s.store:add({
          path = r.path,
          side = "new",
          line = r.new_line,
          anchor = file[r.new_line] or "",
          context = {},
          body = body or "needs a guard",
        })
        return c, i
      end
    end
  end

  local function cards_in(buf)
    return vim.api.nvim_buf_get_extmarks(buf, COMMENT_NS, 0, -1, { details = true })
  end

  it("draws a card under the line it is anchored to", function()
    view.open("HEAD", dir)
    local c, row = add()
    view.set_mode("split")
    view.set_mode("unified")

    local marks = cards_in(vim.api.nvim_get_current_buf())
    assert.equals(1, #marks)
    assert.equals(row - 1, marks[1][2], "card must sit on the anchored row")

    local body = ""
    for _, vl in ipairs(marks[1][4].virt_lines) do
      for _, chunk in ipairs(vl) do
        body = body .. chunk[1]
      end
    end
    assert.is_truthy(body:find(c.body, 1, true))
  end)

  it("shows the same comment in split mode, on the new side", function()
    view.open("HEAD", dir)
    add()
    view.set_mode("split")

    local s = view.session()
    assert.equals(1, #cards_in(s.bufs.new), "the addition lives on the new side")
    assert.equals(0, #cards_in(s.bufs.old))
  end)

  it("survives a mode round trip", function()
    view.open("HEAD", dir)
    add()
    view.set_mode("split")
    view.set_mode("unified")
    assert.equals(1, #cards_in(vim.api.nvim_get_current_buf()))
  end)

  it("round trips through comments.json", function()
    view.open("HEAD", dir)
    local c = add("persisted note")

    local fresh = require("revu.store").new(dir)
    fresh:load()
    local found = fresh:get(c.id)
    assert.is_truthy(found)
    assert.equals("persisted note", found.body)
  end)

  it("toggles resolved and reflects it in the card", function()
    view.open("HEAD", dir)
    local c, row = add()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.toggle_resolved()
    assert.equals("resolved", view.session().store:get(c.id).status)

    local body = ""
    for _, vl in ipairs(cards_in(vim.api.nvim_get_current_buf())[1][4].virt_lines) do
      for _, chunk in ipairs(vl) do
        body = body .. chunk[1]
      end
    end
    assert.is_truthy(body:find("resolved", 1, true))
  end)

  it("deletes the comment and its card", function()
    view.open("HEAD", dir)
    local _, row = add()
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    view.delete_comment()
    assert.equals(0, #view.session().store:list())
    assert.equals(0, #cards_in(vim.api.nvim_get_current_buf()))
  end)

  it("jumps between commented rows", function()
    view.open("HEAD", dir)
    local _, row = add()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.jump_comment(1)
    assert.equals(row, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("lists a comment whose anchor is gone rather than drawing it somewhere wrong", function()
    view.open("HEAD", dir)
    local s = view.session()
    s.store:add({
      path = "a.lua",
      side = "new",
      line = 3,
      anchor = "this text is nowhere in the file",
      context = {},
      body = "orphan",
    })

    view.set_mode("split")
    view.set_mode("unified")

    assert.equals(0, #cards_in(vim.api.nvim_get_current_buf()))
    assert.equals(1, #view.orphans())
    assert.equals("orphan", view.orphans()[1].body)
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

  it("keeps stored positions valid across a fold", function()
    view.open("HEAD", dir)
    local rbuf = vim.api.nvim_get_current_buf()
    local rows = view.session().render.rows

    -- park deep in the review, below the file we are about to fold
    local deep
    for i = #rows, 1, -1 do
      if rows[i].kind ~= "header" and (rows[i].new_line or rows[i].old_line) then
        deep = i
        break
      end
    end
    local text = vim.api.nvim_buf_get_lines(0, deep - 1, deep, false)[1]
    vim.api.nvim_win_set_cursor(0, { deep, 0 })

    view.open_file()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "nx", false)

    -- fold the first file, which used to shift every row below it
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    view.toggle()

    for i = #vim.fn.getjumplist()[1], 1, -1 do
      local j = vim.fn.getjumplist()[1][i]
      if j.bufnr == rbuf then
        local now = vim.api.nvim_buf_get_lines(rbuf, j.lnum - 1, j.lnum, false)[1]
        assert.equals(deep, j.lnum, "the entry must not be clamped")
        assert.equals(text, now, "the row must still hold what it held")
        return
      end
    end
    error("no jumplist entry for the review")
  end)

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
