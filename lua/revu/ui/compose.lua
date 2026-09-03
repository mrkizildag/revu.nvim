-- Floating editor for writing a comment.
--
-- A real buffer rather than vim.ui.input: review notes are often several lines, and a
-- prompt that discards the text on <Esc> is the wrong shape for them.

local M = {}

---Join buffer lines into a body, dropping trailing blank lines only.
---
---Not a full trim: leading indentation and internal blank lines are part of what someone
---wrote, and a comment is frequently a short list or a code snippet.
---@param lines string[]
---@return string
local function normalize(lines)
  local last = #lines
  while last > 0 and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return table.concat(lines, "\n", 1, math.max(last, 0))
end

---@param opts { title?: string, text?: string }
---@param on_submit fun(text: string)
---@return integer bufnr, integer winid
function M.open(opts, on_submit)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  -- `acwrite` makes :w fire BufWriteCmd instead of erroring, so the habitual save gesture
  -- submits rather than being rejected.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "revu://comment")

  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end

  -- Centred on the editor, not on the cursor: a cursor-relative float near the bottom of
  -- the screen gets clipped, which is exactly where a long diff puts you.
  local width = math.min(72, math.max(30, vim.o.columns - 8))
  local height = math.min(10, math.max(3, vim.o.lines - 6))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "comment") .. " ",
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:RevuCommentBorder"

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local text = normalize(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.bo[buf].modified = false
    close()
    if text ~= "" then
      on_submit(text)
    end
  end

  ---Closing with text in the buffer asks first: losing a written comment to a reflex <Esc>
  ---is a bad trade, and there is no undo for it.
  local function cancel()
    local text = normalize(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if text ~= "" and vim.fn.confirm("Save this comment?", "&Yes\n&No", 1) == 1 then
      submit()
      return
    end
    vim.bo[buf].modified = false
    close()
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "revu: save comment" })
  vim.keymap.set("n", "q", cancel, { buffer = buf, desc = "revu: close" })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, desc = "revu: close" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = submit,
  })

  vim.cmd("startinsert!")
  return buf, win
end

return M
