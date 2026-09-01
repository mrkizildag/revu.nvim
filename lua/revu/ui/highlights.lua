-- Defines the plugin's highlight groups as links to existing ones.
--
-- No literal colours anywhere: the plugin inherits the user's colorscheme, and re-links on
-- ColorScheme so it survives a theme switch (Themery and friends change it at runtime).

local config = require("revu.config")

local M = {}

function M.apply()
  for group, target in pairs(config.options.highlights) do
    -- `default = true` means a user who defined the group themselves keeps their version.
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("revu-highlights", { clear = true }),
    callback = M.apply,
  })
end

return M
