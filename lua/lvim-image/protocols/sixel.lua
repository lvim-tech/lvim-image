-- lvim-image.protocols.sixel: the sixel encoder — foot / contour / mlterm / xterm(+sixel) / WezTerm / Konsole.
-- Sixel has no in-terminal image id or placement model: the encoded pixels are written AT THE CURSOR
-- (`ESC P q … ST`) and become part of the grid. So we encode with libsixel's `img2sixel` (fed PNG bytes on
-- stdin) at the exact DISPLAY pixel size (cols/rows × the measured cell size) and write the result at the
-- target cell, bracketed by cursor save/restore so nvim's own cursor is untouched. The encoded sixel is CACHED
-- per pixel size on the image, so a relayout re-issues it without re-encoding.
--
-- Source: a PNG is read from disk untouched; any other raster is encoded to PNG in memory (decode.to_png,
-- libvips) before img2sixel. Grid-drawn images have no delete-by-id — a repaint of the cells clears them — so
-- `delete` is a no-op. Requires `img2sixel` (libsixel) on PATH; without it `place_at` renders nothing.
--
---@module "lvim-image.protocols.sixel"

local terminal = require("lvim-image.terminal")

local M = {}

local seq = 0

--- Allocate a placement sequence number (sixel has no persistent id; kept only for interface parity).
---@return integer
function M.next_id()
    seq = seq + 1
    return seq
end

--- Read a file's raw bytes, or nil.
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

--- The PNG bytes to feed img2sixel: a PNG source verbatim; anything else encoded to PNG in memory.
---@param img { kind: string, path?: string, src: string }
---@return string|nil
local function png_bytes(img)
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
    return read_bytes(img.src)
end

--- Encode PNG bytes to a sixel stream at `wpx × hpx` pixels via `img2sixel` (stdin → stdout). Returns nil when
--- img2sixel is missing or fails.
---@param png string
---@param wpx integer
---@param hpx integer
---@return string|nil
local function encode(png, wpx, hpx)
    if vim.fn.executable("img2sixel") ~= 1 then
        return nil
    end
    local res = vim.system({ "img2sixel", "-w", tostring(wpx), "-h", tostring(hpx) }, { stdin = png, text = false })
        :wait()
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return nil
    end
    return res.stdout
end

--- No-op: sixel is encoded at PLACE time (it needs the display pixel size, known only then). Kept for interface
--- parity with kitty's transmit/place split.
---@param _img table
function M.transmit(_img) end

--- Draw the image at a 1-based screen cell `(row, col)`, sized `cols × rows` cells. Encodes (once per pixel
--- size, then cached on the image) and writes the sixel at the cell, saving/restoring the cursor around it.
---@param img { kind: string, path?: string, src: string, _sixel?: table<string, string> }
---@param row integer
---@param col integer
---@param cols integer
---@param rows integer
---@param placement_id integer  unused — kept for interface parity
function M.place_at(img, row, col, cols, rows, placement_id)
    local cell = terminal.cell_size()
    local wpx = math.max(1, cols * cell.w)
    local hpx = math.max(1, rows * cell.h)
    local key = wpx .. "x" .. hpx
    img._sixel = img._sixel or {}
    ---@type string?
    local data = img._sixel[key]
    if not data then
        local png = png_bytes(img)
        if not png then
            return
        end
        data = encode(png, wpx, hpx)
        if not data then
            return
        end
        img._sixel[key] = data
    end
    -- Cursor positioning goes UNwrapped to the pane pty (write_raw): tmux translates the pane-relative CUP to
    -- the outer screen itself. Wrapping it in the passthrough would send pane coords straight to the OUTER
    -- terminal (wrong position in a split + a grid desync). Only the SIXEL payload rides the passthrough.
    terminal.write_raw("\27[s") -- save cursor
    terminal.write_raw(string.format("\27[%d;%dH", row, col)) -- move to the cell
    terminal.write(data)
    terminal.write_raw("\27[u") -- restore cursor
end

--- No persistent placement to remove (grid-drawn); a repaint of the cells clears the image.
---@param _id integer
function M.delete(_id) end

return M
