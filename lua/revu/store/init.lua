-- Store factory and the interface the rest of the plugin codes against.
--
-- The UI must never require a concrete backend. Today the only one is local_json; the
-- boundary exists so a backend that talks to a daemon (for real-time sync) can be swapped
-- in without touching a render path.
--
-- `on_change` is the load-bearing part of the interface: a local store fires it on save,
-- a remote one would also fire when a peer edits. Subscribing rather than polling is what
-- makes that swap possible.

local M = {}

---@class revu.Comment
---@field id string
---@field path string            repo-relative
---@field side "old"|"new"
---@field line integer           1-based, on that side
---@field anchor string          verbatim text of the anchored line
---@field context string[]       surrounding lines, for re-anchoring
---@field body string
---@field status "open"|"resolved"
---@field created_at string      ISO 8601

---@class revu.Store
---@field load fun(self): boolean, string|nil
---@field save fun(self): boolean, string|nil
---@field list fun(self, opts?: { path?: string, side?: string, status?: string }): revu.Comment[]
---@field get fun(self, id: string): revu.Comment|nil
---@field add fun(self, comment: table): revu.Comment|nil, string|nil
---@field update fun(self, id: string, patch: table): revu.Comment|nil, string|nil
---@field remove fun(self, id: string): boolean, string|nil
---@field on_change fun(self, cb: fun())

---@param root string  absolute path to the repo root
---@param opts? { backend?: "local_json" }
---@return revu.Store
function M.new(root, opts)
  local backend = (opts or {}).backend or "local_json"
  return require("revu.store." .. backend).new(root)
end

return M
