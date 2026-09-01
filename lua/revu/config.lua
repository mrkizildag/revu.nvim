local M = {}

M.defaults = {
  --- Revision to diff against. "HEAD" reviews uncommitted work; "main...HEAD" the branch.
  rev = "HEAD",

  signs = {
    add = "▎",
    delete = "▎",
  },

  --- Linked to existing groups rather than given literal colours, so the plugin inherits
  --- whatever colorscheme is active instead of fighting it.
  highlights = {
    RevuAdd = "DiffAdd",
    RevuDelete = "DiffDelete",
    RevuAddSign = "DiffAdd",
    RevuDeleteSign = "DiffDelete",
    RevuHunk = "Comment",
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
