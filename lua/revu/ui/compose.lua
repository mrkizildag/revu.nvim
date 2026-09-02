-- A small floating window for writing a comment.
--
-- Deliberately a real buffer rather than vim.ui.input: comments are frequently several
-- lines, and a prompt that loses your text on <Esc> is the wrong shape for review notes.

local M = {}

---@param opts { title?: string, text?: string, width?: integer, height?: integer }
---@param on_submit fun(text: string)
---@return integer bufnr, integer winid
function M.open(opts, on_submit)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end

  local width = opts.width or math.min(72, math.floor(vim.o.columns * 0.6))
  local height = opts.height or 6

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "comment") .. " ",
    title_pos = "center",
  })

  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:RevuCommentBorder"

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    close()
    -- Trimmed here rather than in the store, so cancelling by clearing the buffer works.
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
      on_submit(text)
    end
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "revu: save comment" })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, desc = "revu: save comment" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "revu: discard" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "revu: discard" })

  vim.cmd("startinsert!")
  return buf, win
end

return M
