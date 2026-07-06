-- lvim-image.buf: open an image FILE directly as a buffer. A `BufReadCmd` on image extensions takes
-- over the (binary) file load and instead renders the image full-window, centred, re-fit on resize and torn
-- down on wipe. This is what makes `nvim picture.png` (or `:edit picture.jpg`) show the picture. PNGs pass
-- through; everything else is decoded in memory by image/decode.lua — no temp files.
--
---@module "lvim-image.buf"

local api = vim.api
local config = require("lvim-image.config")

local M = {}

---@param buf integer
---@param path string
local function default_read(buf, path)
    local ok, lines = pcall(vim.fn.readfile, path, "b")
    if not ok then
        vim.notify("lvim-image: failed to read " .. path, vim.log.levels.WARN)
        return
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
end

--- `*.ext` patterns (both cases) for every configured format — drives the BufReadCmd registration.
---@return string[]
local function patterns()
    local pats = {}
    for _, e in ipairs(config.formats) do
        pats[#pats + 1] = "*." .. e
        pats[#pats + 1] = "*." .. e:upper()
    end
    return pats
end

--- Render `src` centred + fit into image buffer `buf` shown in `win`. Returns the Placement, or nil on
--- failure (leaving an error line in the buffer).
---@param buf integer
---@param win integer
---@param src string
---@return lvim-image.Placement|nil
local function display(buf, win, src)
    local Image = require("lvim-image.image")
    local img = Image.new(src)
    if not (img and img:prepare()) then
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  [lvim-image] " .. ((img and img.err) or "cannot display") })
        vim.bo[buf].modifiable = false
        return nil
    end
    local Placement = require("lvim-image.placement")
    return Placement.new(img, {
        buf = buf,
        win = win,
        max_w = api.nvim_win_get_width(win),
        max_h = api.nvim_win_get_height(win),
        center = true,
    })
end

--- Turn `buf` (shown in `win`) into the image viewer for `src`: mark it a throwaway image scratch, apply the
--- viewer window options (saving the prior ones), and render — re-fit on resize, restored + cleaned up on wipe.
---@param buf integer
---@param win integer
---@param src string
local function render_image(buf, win, src)
    local saved_winopts = {}
    for _, opt in ipairs({ "number", "relativenumber", "list", "wrap", "cursorline", "signcolumn" }) do
        pcall(function()
            saved_winopts[opt] = vim.wo[win][opt]
        end)
    end

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "lvim-image"
    for _, opt in ipairs({ "number", "relativenumber", "list", "wrap", "cursorline" }) do
        pcall(function()
            vim.wo[win][opt] = false
        end)
    end
    pcall(function()
        vim.wo[win].signcolumn = "no"
    end)
    pcall(function()
        require("lvim-utils.cursor").mark_hide_buffer(buf, true)
    end)

    ---@type lvim-image.Placement|nil
    local pl
    local function render()
        if not (api.nvim_buf_is_valid(buf) and api.nvim_win_is_valid(win)) then
            return
        end
        if pl then
            pl:close()
        end
        pl = display(buf, win, src)
    end
    render()

    local grp = api.nvim_create_augroup("LvimImageBuf_" .. buf, { clear = true })
    api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = grp,
        buffer = buf,
        callback = function()
            vim.schedule(render)
        end,
    })
    api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = grp,
        buffer = buf,
        once = true,
        callback = function()
            if pl then
                pl:close()
            end
        end,
    })
    api.nvim_create_autocmd("BufWinLeave", {
        group = grp,
        buffer = buf,
        once = true,
        callback = function()
            if api.nvim_win_is_valid(win) then
                for opt, value in pairs(saved_winopts) do
                    pcall(function()
                        vim.wo[win][opt] = value
                    end)
                end
            end
        end,
    })
end

--- `BufReadCmd` handler: take over an opened image file. When a graphics protocol is available, render the
--- image; otherwise perform the DEFAULT binary read (so the buffer holds the real bytes and `:w` round-trips
--- instead of truncating an empty buffer). Terminal capability detection is ASYNC — its DA1/XTVERSION replies
--- land on `TermResponse` after this handler runs — so on the not-yet-supported path we install a ONE-SHOT
--- `TermResponse` re-check that switches the (still-untouched) buffer to the image view once support appears.
---@param ev { buf: integer, match: string, file: string }
function M.open(ev)
    local buf = ev.buf
    local src = vim.fn.fnamemodify((ev.match ~= "" and ev.match) or ev.file or api.nvim_buf_get_name(buf), ":p")
    local image = require("lvim-image")
    image.setup()
    if not config.enabled then
        default_read(buf, src)
        return
    end
    if image.supported() then
        render_image(buf, api.nvim_get_current_win(), src)
        return
    end
    -- Not supported yet: read the file so the buffer is not left empty, then wait for the async capability
    -- replies. If support resolves and the buffer is still an untouched image file, render it in place.
    default_read(buf, src)
    api.nvim_create_autocmd("TermResponse", {
        group = api.nvim_create_augroup("LvimImageBufDetect_" .. buf, { clear = true }),
        callback = function()
            if not api.nvim_buf_is_valid(buf) then
                return true -- returning true removes this autocmd
            end
            if image.supported() and not vim.bo[buf].modified then
                local win = vim.fn.bufwinid(buf)
                if win ~= -1 then
                    render_image(buf, win, src)
                    return true
                end
            end
        end,
    })
end

--- Register the `BufReadCmd` so opening an image file displays it. Idempotent.
function M.setup()
    api.nvim_create_autocmd("BufReadCmd", {
        group = api.nvim_create_augroup("LvimImageBufReadCmd", { clear = true }),
        pattern = patterns(),
        callback = M.open,
    })
end

return M
