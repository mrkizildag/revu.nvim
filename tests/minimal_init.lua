-- Minimal rtp for the suite: this plugin plus plenary.
--
-- Plenary is resolved from the first path that exists, so the same command works locally
-- (borrowing the lazy.nvim install, no vendoring) and in CI (which clones into .tests/).
-- $PLENARY_PATH overrides both.

local candidates = {}

-- Appended rather than declared inline: a nil first element would make ipairs stop
-- immediately and silently iterate nothing.
if vim.env.PLENARY_PATH and vim.env.PLENARY_PATH ~= "" then
  table.insert(candidates, vim.env.PLENARY_PATH)
end
table.insert(candidates, vim.fn.getcwd() .. "/.tests/plenary.nvim")
table.insert(candidates, vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
table.insert(candidates, vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"))

local plenary
for _, path in ipairs(candidates) do
  if vim.uv.fs_stat(path) then
    plenary = path
    break
  end
end

if not plenary then
  io.stderr:write(
    "plenary.nvim not found in any of:\n  "
      .. table.concat(candidates, "\n  ")
      .. "\nSet $PLENARY_PATH, or:\n"
      .. "  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .tests/plenary.nvim\n"
  )
  vim.cmd("1cq")
end

vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")
