local config = require("revu.config")

local M = {}

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  require("revu.ui.highlights").setup()

  local view = require("revu.ui.view")

  vim.api.nvim_create_user_command("Revu", function(cmd)
    local rev = cmd.args ~= "" and cmd.args or nil
    local ok, err = view.open(rev)
    if not ok then
      vim.notify("revu: " .. tostring(err), vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    desc = "Review changes against a revision (default HEAD)",
    complete = function(lead)
      local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "--branches" })
      table.insert(out, "HEAD")
      return vim.tbl_filter(function(x)
        return x:find(lead, 1, true) == 1
      end, out)
    end,
  })

  vim.api.nvim_create_user_command("RevuClose", function()
    view.close()
  end, { desc = "Close the review and discard it" })

  vim.api.nvim_create_user_command("RevuComments", function()
    if view.list_comments() == 0 then
      vim.notify("revu: no comments", vim.log.levels.INFO)
    end
  end, { desc = "List every comment in the quickfix list" })

  vim.api.nvim_create_user_command("RevuSplit", function()
    view.set_mode("split")
  end, { desc = "Show the review as old | new" })

  vim.api.nvim_create_user_command("RevuUnified", function()
    view.set_mode("unified")
  end, { desc = "Show the review as one combined column" })

  vim.api.nvim_create_user_command("RevuHide", function()
    view.hide()
  end, { desc = "Hide the review, keeping it for :Revu to return to" })

  vim.api.nvim_create_user_command("RevuNext", function()
    view.jump_file(1)
  end, { desc = "Next changed file" })

  vim.api.nvim_create_user_command("RevuPrev", function()
    view.jump_file(-1)
  end, { desc = "Previous changed file" })
end

return M
