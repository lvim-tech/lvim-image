-- lvim-image.uiimg: a `vim.ui.img`-compatible image backend (set / get / del) built on lvim-image's kitty
-- engine. Neovim ships an experimental native `vim.ui.img`, but it writes graphics via `nvim_ui_send` and does
-- NO tmux passthrough — so inside tmux its capability query is blocked (`:checkhealth img` → "not supported")
-- and images do not display. This adapter routes the SAME kitty graphics commands through lvim-image's terminal
-- layer (`/dev/tty` + tmux DCS passthrough), so the native image API — and any plugin built on it — works under
-- tmux too. `M.register()` installs it as `vim.ui.img`.
--
-- Like the native backend this is SCREEN-POSITIONAL: an `a=p` placement pinned to a screen row/col (it does NOT
-- scroll with buffer content — for content-anchored inline images use lvim-image's own placeholder path). An
-- update (`set(id, opts)`) re-issues the `a=p` placement, so moving an image is flicker-free (no re-transmit).
--
---@module "lvim-image.uiimg"

local terminal = require("lvim-image.terminal")
local kitty = require("lvim-image.protocols.kitty")

local M = {}

-- Mirror of Neovim's `vim.ui.img.Opts` (defined in the nvim runtime, so not visible to an isolated check).
---@class lvim-image.uiimg.Opts
---@field row? integer     starting row (1-indexed)
---@field col? integer     starting column (1-indexed)
---@field width? integer   width in cells
---@field height? integer  height in cells
---@field zindex? integer  stacking order (higher = on top)

--- User-facing placement id -> tracking info.
---@type table<integer, { img_id: integer, opts: lvim-image.uiimg.Opts }>
local state = {}

--- Emit the `a=p` placement at the position in `opts`, bracketed by cursor save+hide / restore+show so Nvim's
--- own cursor is left untouched. Nil `width`/`height` fall through to the image's natural cell size.
---@param img_id integer
---@param placement_id integer
---@param opts lvim-image.uiimg.Opts
local function place(img_id, placement_id, opts)
    terminal.write_raw("\0277\27[?25l") -- save cursor + hide
    kitty.place_at({ id = img_id }, opts.row or 1, opts.col or 1, opts.width, opts.height, placement_id)
    terminal.write_raw("\0278\27[?25h") -- restore cursor + show
end

--- Display an image or update an existing one — the `vim.ui.img.set` contract. A string is raw PNG bytes to
--- display at `opts` (returns a new id); an integer is a previously returned id to update (move/resize).
---@param data_or_id string|integer
---@param opts? lvim-image.uiimg.Opts
---@return integer id
function M.set(data_or_id, opts)
    opts = opts or {}
    if type(data_or_id) == "string" then
        terminal.setup()
        local img_id = kitty.next_id()
        local placement_id = kitty.next_id()
        kitty.transmit({ id = img_id, kind = "png_bytes", bytes = data_or_id })
        place(img_id, placement_id, opts)
        state[placement_id] = { img_id = img_id, opts = vim.deepcopy(opts) }
        return placement_id
    end
    local id = data_or_id
    local entry = state[id]
    assert(entry, "invalid image id: " .. tostring(id))
    local merged = vim.tbl_extend("force", entry.opts, opts)
    place(entry.img_id, id, merged)
    entry.opts = merged
    return id
end

--- A copy of an image's current opts, or nil when unknown — the `vim.ui.img.get` contract.
---@param id integer
---@return lvim-image.uiimg.Opts?
function M.get(id)
    local entry = state[id]
    return entry and vim.deepcopy(entry.opts) or nil
end

--- Delete one image, or ALL images when `math.huge` is given — the `vim.ui.img.del` contract.
---@param id integer
---@return boolean found
function M.del(id)
    if id == math.huge then
        local had = next(state) ~= nil
        if had then
            for placement_id, entry in pairs(state) do
                kitty.delete(entry.img_id, placement_id)
                kitty.delete(entry.img_id)
            end
            state = {}
        end
        return had
    end
    local entry = state[id]
    if not entry then
        return false
    end
    kitty.delete(entry.img_id, id)
    kitty.delete(entry.img_id)
    state[id] = nil
    return true
end

--- Whether the host terminal can display images (mirrors the private `vim.ui.img._supported`). Uses
--- lvim-image's own detection (kitty graphics, tmux-aware) rather than a raw APC query.
---@return boolean supported
function M._supported()
    terminal.setup()
    return terminal.supported()
end

--- Install this adapter as `vim.ui.img` so the native image API (and any plugin built on it) routes through
--- lvim-image's tmux-aware `/dev/tty` backend. Idempotent; tears images down on VimLeavePre.
function M.register()
    ---@diagnostic disable-next-line: assign-type-mismatch
    vim.ui.img = M
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("LvimImageUiImg", { clear = true }),
        callback = function()
            M.del(math.huge)
        end,
    })
end

return M
