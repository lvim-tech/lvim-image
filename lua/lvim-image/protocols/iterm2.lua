-- lvim-image.protocols.iterm2: the iTerm2 inline-image protocol (OSC 1337) encoder — iTerm2, WezTerm, Konsole.
-- One command draws the image AT THE CURSOR: `ESC ] 1337 ; File=inline=1;width=<cols>;height=<rows>;
-- preserveAspectRatio=0 : <base64 image> ST`. Unlike kitty there is NO transmit/place split and NO image id —
-- the encoded image travels with each placement, so `transmit` only CACHES the base64 on the image and
-- `place_at` positions the cursor and emits it (bracketed by save/restore so nvim's cursor is left untouched).
-- Everything is written through terminal.write (which adds tmux passthrough on the outer ESC).
--
-- iTerm2 wants a COMPLETE image FILE (PNG/JPEG/GIF/…): a PNG source is read from disk untouched; any other
-- raster is encoded to PNG in memory via decode.to_png (libvips, no temp file). Grid-drawn images have no
-- delete-by-id — whatever repaints those cells (the viewer close / a redraw) clears them — so `delete` no-ops.
--
---@module "lvim-image.protocols.iterm2"

local terminal = require("lvim-image.terminal")

local b64 = vim.base64.encode

local M = {}

local seq = 0

--- Allocate a placement sequence number. iTerm2 has no persistent image id; this exists only for parity with
--- the backend interface (`image.new` stores it as `img.id`).
---@return integer
function M.next_id()
    seq = seq + 1
    return seq
end

--- Read a file's raw bytes, or nil when it cannot be opened.
---@param path string
---@return string|nil
local function read_bytes(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

--- The complete image-file bytes for `img`: a PNG source verbatim; anything else encoded to PNG in memory.
---@param img { kind: string, path?: string, src: string }
---@return string|nil
local function image_bytes(img)
    if img.kind == "png_file" and img.path then
        return read_bytes(img.path)
    end
    local ok, decode = pcall(require, "lvim-image.decode")
    if ok and decode then
        local png = decode.to_png(img.src)
        if png then
            return png
        end
    end
    return read_bytes(img.src) -- last resort: hand the raw source to the terminal to decode
end

--- Cache the base64-encoded image bytes on `img`. No tty write here — iTerm2 sends the data at PLACE time, so
--- the encode is done once and reused across relayouts. Gated by the cached field.
---@param img { kind: string, path?: string, src: string, _iterm?: string }
function M.transmit(img)
    if img._iterm then
        return
    end
    local bytes = image_bytes(img)
    if bytes then
        img._iterm = b64(bytes)
    end
end

--- Draw the image at a 1-based screen cell `(row, col)`, sized `cols × rows` cells. Saves + restores the OS
--- cursor around the draw so nvim's own cursor position is not disturbed; re-issued by the renderer on relayout.
---@param img { kind: string, path?: string, src: string, _iterm?: string }
---@param row integer
---@param col integer
---@param cols integer
---@param rows integer
---@param placement_id integer  unused (iTerm2 has no placement id) — kept for interface parity
function M.place_at(img, row, col, cols, rows, placement_id)
    if not img._iterm then
        M.transmit(img)
    end
    if not img._iterm then
        return
    end
    -- width/height are CELL counts; preserveAspectRatio=0 because the renderer already fit the box to aspect.
    local head = string.format("\27]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=0:", cols, rows)
    -- Cursor positioning goes UNwrapped to the pane pty (write_raw): tmux translates the pane-relative CUP to
    -- the outer screen itself. Wrapping it in the passthrough would send pane coords straight to the OUTER
    -- terminal (wrong position in a split + a grid desync). Only the IMAGE payload rides the passthrough.
    terminal.write_raw("\27[s") -- save cursor
    terminal.write_raw(string.format("\27[%d;%dH", row, col)) -- move to the cell
    terminal.write(head .. img._iterm .. "\27\\")
    terminal.write_raw("\27[u") -- restore cursor
end

--- No persistent placement to remove (the image is drawn into the grid); a repaint of those cells clears it.
---@param _id integer
function M.delete(_id) end

return M
