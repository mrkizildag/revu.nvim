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

  --- +/- drawn immediately before each line as inline virtual text, so they sit under the
  --- pill's interior rather than out in the gutter. Virtual, not buffer content: they
  --- cannot be selected, yanked or edited, and yanking a line gives back real code.
  --- Context gets a blank of equal width so the columns line up.
  prefix = {
    add = "+ ",
    delete = "- ",
    context = "  ",
  },

  --- +/- in the sign column instead, out to the left of everything, the way gitsigns marks
  --- hunks. Off by default now that the prefix carries the same information inline.
  --- Set to `{ add = "+", delete = "-" }` to use the gutter as well or instead.
  signs = false,

  --- Comment cards drawn under the line they are anchored to.
  comment = {
    indent = "  ",
    corner_left = "╭",
    corner_right = "╮",
    bottom_left = "╰",
    bottom_right = "╯",
    side = "│",
    fill = "─",
    open = "●",
    resolved = "✓",
  },

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
    --- Padding on the side of a split that has no counterpart line.
    RevuFiller = "NonText",
    RevuCommentBorder = "FloatBorder",
    RevuCommentBody = "Normal",
    RevuCommentOpen = "WarningMsg",
    RevuCommentResolved = "Added",
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
