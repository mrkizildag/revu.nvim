local M = {}

M.defaults = {
  --- Revision to diff against. "HEAD" reviews uncommitted work; "main...HEAD" the branch.
  rev = "HEAD",

  --- Include files git does not track yet. On by default because agents create new files
  --- constantly and a review that hides them is worse than useless. Ignored automatically
  --- for commit ranges, where an untracked file belongs to neither side.
  untracked = true,

  --- Full-width pill introducing each file. A real buffer line, not virtual text: the
  --- cursor has to land on it to toggle the section, and virtual text cannot be navigated
  --- to. Segments are coloured individually, so the path dims and the counts go green/red.
  header = {
    expanded = "▾",
    collapsed = "▸",
    --- Telescope's ordering, so a borderchars set can be lifted straight from a theme:
    --- { top, right, bottom, left, top-left, top-right, bottom-right, bottom-left }
    borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
  },

  --- +/- in the sign column, the way gitsigns marks hunks. The gutter is outside the text
  --- area, so the cursor never travels through them and the code still starts at column 1.
  signs = {
    add = "+",
    delete = "-",
  },

  --- Inline +/- drawn immediately before each line instead. Off by default: inline virtual
  --- text occupies screen columns, so moving up and down parks the cursor visually on the
  --- marker. Set to `{ add = "+ ", delete = "- ", context = "  " }` to use it anyway.
  prefix = false,

  --- Linked to existing groups rather than given literal colours, so the plugin inherits
  --- whatever colorscheme is active instead of fighting it.
  highlights = {
    RevuAdd = "DiffAdd",
    RevuDelete = "DiffDelete",
    RevuAddSign = "DiffAdd",
    RevuDeleteSign = "DiffDelete",
    RevuAddPrefix = "DiffAdd",
    RevuDeletePrefix = "DiffDelete",
    RevuHunk = "Comment",
    -- `Added`/`Removed` are the semantic foreground green and red, unlike DiffAdd and
    -- DiffDelete which are backgrounds meant for whole lines.
    RevuHeaderBorder = "FloatBorder",
    RevuHeaderChevron = "Special",
    RevuHeaderDir = "Comment",
    RevuHeaderName = "Title",
    RevuHeaderAdd = "Added",
    RevuHeaderDelete = "Removed",
    RevuHeaderStat = "Comment",
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
