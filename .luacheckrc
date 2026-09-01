-- Neovim runs LuaJIT, which is 5.1 semantics.
std = "luajit"

-- The editor API. Writable rather than read_globals: `vim.bo[buf].filetype = ...` and
-- `vim.wo.number = ...` are ordinary usage, and read_globals flags every one of them.
globals = { "vim" }

-- stylua owns formatting, including line length; luacheck should not have an opinion.
max_line_length = false

exclude_files = { ".tests/" }

files["lua/revu/diff.lua"] = {
  -- 542 is "empty if branch". The parser has two deliberate no-op branches -- a line
  -- before the first file header, and the "\ No newline at end of file" marker -- and each
  -- exists to stop the line falling through to a later branch that would mishandle it.
  -- They are load-bearing, so the check is off here rather than the branches removed.
  ignore = { "542" },
}

files["tests/"] = {
  -- plenary's busted harness injects these into every spec.
  read_globals = { "describe", "it", "before_each", "after_each", "pending" },
  globals = { "assert" },
}

files["tests/minimal_init.lua"] = {
  -- Not a spec; it runs before the harness exists.
  read_globals = {},
}
