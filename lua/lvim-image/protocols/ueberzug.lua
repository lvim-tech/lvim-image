-- lvim-image.protocols.ueberzug: the ueberzugpp OVERLAY backend — the universal fallback for terminals with no
-- native graphics protocol (X11/Wayland + the ueberzugpp binary). Unlike the escape-sequence protocols,
-- ueberzugpp is a separate DAEMON that draws images in its own window layered OVER the terminal; we drive it by
-- writing newline-delimited JSON commands to its stdin (add / remove, keyed by identifier). Because it is an
-- overlay it survives nvim's grid repaints and is simply REPOSITIONED (a fresh `add` with the same identifier)
-- on relayout.
--
-- The daemon is spawned LAZILY on the first placement and killed on VimLeavePre (else the overlay + process
-- leak — the hard-won cleanup discipline). Identifiers are PID-scoped so multiple nvim instances sharing one
-- screen never collide. ueberzugpp reads the image FILE itself (most formats), so we hand it the source path —
-- no transmit / encode step.
--
---@module "lvim-image.protocols.ueberzug"

local api = vim.api

local M = {}

local pid = vim.fn.getpid()
local seq = 0

---@type vim.SystemObj|nil  the running ueberzugpp daemon (nil until spawned / after shutdown)
local proc = nil

--- Allocate a PID-scoped identifier for a new overlay (unique across nvim instances sharing one screen).
---@return string
function M.next_id()
    seq = seq + 1
    return string.format("lvim%d_%d", pid, seq)
end

--- Kill the ueberzugpp daemon (removing every overlay it owns). Idempotent — safe to call more than once.
function M.shutdown()
    if proc then
        local p = proc
        proc = nil
        pcall(function()
            p:write(nil) -- close stdin so the daemon exits cleanly
        end)
        pcall(function()
            p:kill("sigterm") -- in case it does not exit on stdin close
        end)
    end
end

--- Spawn the ueberzugpp daemon (once) and install the VimLeavePre cleanup. Returns the process, or nil when the
--- binary is missing / spawn fails.
---@return vim.SystemObj|nil
local function ensure_daemon()
    if proc then
        return proc
    end
    local bin = (vim.fn.executable("ueberzugpp") == 1 and "ueberzugpp")
        or (vim.fn.executable("ueberzug") == 1 and "ueberzug")
        or nil
    if not bin then
        return nil
    end
    local ok, p = pcall(vim.system, { bin, "layer", "--parser", "json" }, { stdin = true, stderr = false })
    if not ok or not p then
        return nil
    end
    proc = p
    api.nvim_create_autocmd("VimLeavePre", {
        group = api.nvim_create_augroup("LvimImageUeberzug", { clear = true }),
        callback = function()
            M.shutdown()
        end,
    })
    return proc
end

--- Send one JSON command line to the daemon (spawning it if needed). Silently drops when unavailable.
---@param cmd table
local function send(cmd)
    local p = ensure_daemon()
    if not p then
        return
    end
    local ok, line = pcall(vim.json.encode, cmd)
    if ok and line then
        pcall(function()
            p:write(line .. "\n")
        end)
    end
end

--- No-op: ueberzugpp reads the image file directly at place time, so there is nothing to pre-transmit.
---@param _img table
function M.transmit(_img) end

--- Add (or REPOSITION — same identifier) the overlay at a 1-based screen cell `(row, col)`, sized `cols × rows`
--- cells. ueberzugpp coordinates are 0-based, so subtract one.
---@param img { id: string, src: string }
---@param row integer
---@param col integer
---@param cols integer
---@param rows integer
---@param placement_id integer  unused — kept for interface parity
function M.place_at(img, row, col, cols, rows, placement_id)
    send({
        action = "add",
        identifier = tostring(img.id),
        x = math.max(0, col - 1),
        y = math.max(0, row - 1),
        width = cols,
        height = rows,
        path = img.src,
        scaler = "fit_contain",
    })
end

--- Remove the overlay for `id`.
---@param id string
function M.delete(id)
    send({ action = "remove", identifier = tostring(id) })
end

return M
