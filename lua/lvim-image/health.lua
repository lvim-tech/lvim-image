-- lvim-image.health: `:checkhealth lvim-image` — reports the resolved terminal, the chosen
-- graphics protocol + capabilities, the measured cell pixel size, the tty write device, and whether libvips
-- (in-memory non-PNG decode) is available, plus the optional external rasterizers.
--
---@module "lvim-image.health"

local M = {}

---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

--- Run the health checks.
function M.check()
    local h = vim.health
    h.start("lvim-image")

    if vim.fn.has("nvim-0.12") == 1 then
        h.ok("Neovim >= 0.12")
    else
        h.error("Neovim >= 0.12 required")
    end
    if has("lvim-utils.utils") then
        h.ok("lvim-utils (base) is available")
    else
        h.error("lvim-utils not found — lvim-image requires it (utils / colors / cursor)")
    end
    if has("lvim-ui.surface") then
        h.ok("lvim-ui is available (the floating viewer builds on it)")
    else
        h.error("lvim-ui not found — the :LvimImage viewer requires it")
    end

    local image = require("lvim-image")
    image.setup()
    local info = image.info()

    if info.term then
        h.ok("terminal: " .. info.term)
    else
        h.warn("terminal: not resolved yet (the XTVERSION reply may still be pending)")
    end
    h.info(
        ("tmux=%s  zellij=%s  ssh=%s  cell=%dx%d px"):format(
            tostring(info.in_tmux),
            tostring(info.in_zellij),
            tostring(info.is_ssh),
            info.cell.w,
            info.cell.h
        )
    )

    local c = info.caps
    local function cap(name, ok)
        if ok then
            h.ok(name .. ": supported")
        else
            h.info(name .. ": not detected")
        end
    end
    cap("kitty", c.kitty)
    cap("iterm2", c.iterm2)
    cap("sixel", c.sixel)
    cap("ueberzug", c.ueberzug)
    if c.placeholders then
        h.ok("kitty unicode placeholders: supported (inline-anchored images)")
    end

    local cfg_backend = image.config.backend
    local proto = cfg_backend ~= "auto" and cfg_backend
        or require("lvim-image.terminal").pick_protocol(image.config.force)
    if proto then
        h.ok("active protocol: " .. proto .. (cfg_backend ~= "auto" and " (pinned in config)" or " (auto-detected)"))
    else
        h.error("no graphics protocol detected — set `force = true` to assume kitty, or pin `backend`")
    end

    -- External tools the non-kitty backends need beyond the terminal itself: sixel encodes through libsixel's
    -- `img2sixel`; the ueberzug fallback drives the `ueberzugpp` overlay daemon. Error only when the ACTIVE
    -- protocol needs a tool that is missing; otherwise just note it (kitty/iTerm2 need neither).
    if vim.fn.executable("img2sixel") == 1 then
        h.ok("img2sixel (libsixel): present (sixel encoding)")
    elseif proto == "sixel" then
        h.error("img2sixel (libsixel) NOT found — the active sixel protocol cannot encode images; install libsixel")
    else
        h.info("img2sixel (libsixel): missing (needed only for the sixel protocol)")
    end
    if vim.fn.executable("ueberzugpp") == 1 or vim.fn.executable("ueberzug") == 1 then
        h.ok("ueberzugpp: present (overlay fallback)")
    elseif proto == "ueberzug" then
        h.error("ueberzugpp NOT found — the active ueberzug protocol cannot draw; install ueberzugpp")
    else
        h.info("ueberzugpp: missing (needed only for the ueberzug overlay fallback)")
    end

    local ok, decode = pcall(require, "lvim-image.decode")
    if ok and decode.available() then
        h.ok("libvips: available (in-memory decode of JPEG/GIF/WEBP/TIFF/SVG/PDF — no temp files)")
    else
        h.warn("libvips: NOT available — only PNG passthrough works; install libvips for other formats")
    end

    for _, b in ipairs({ "gs", "rsvg-convert" }) do
        if vim.fn.executable(b) == 1 then
            h.ok(b .. ": present (used by libvips for PDF/SVG)")
        else
            h.info(b .. ": missing (optional — needed for PDF/SVG via libvips)")
        end
    end
end

return M
