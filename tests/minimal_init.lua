-- Minimal rtp for the test suite: this plugin plus plenary (borrowed from the user's
-- lazy install so the suite needs no vendoring step).
local lazy = vim.fn.expand("~/.local/share/nvim/lazy")
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(lazy .. "/plenary.nvim")
vim.cmd("runtime plugin/plenary.vim")
