-- lvim-image.config: the LIVE configuration for the image module. `image.setup()` merges the user's
-- opts into this table IN PLACE (via lvim-utils.utils.merge); every reader does `require("lvim-image
-- .config")` and sees the effective values. No state here — only knobs and their documented defaults.
--
---@module "lvim-image.config"

---@class lvim-image.Config
---@field enabled boolean                     master switch
---@field force boolean                        draw even when no protocol is detected (assume kitty)
---@field backend "auto"|"kitty"|"iterm2"|"sixel"|"ueberzug"  force a specific protocol, or auto-detect
---@field provide_ui_img boolean               also register lvim-image as `vim.ui.img` (opt-in; the direct API is unaffected)
---@field formats string[]                     source extensions the module will attempt to display
---@field max_width number                     max viewer width (fraction ≤ 1 of the editor, or absolute cells)
---@field max_height number                    max viewer height (fraction ≤ 1 of the editor, or absolute cells)
---@field border string|string[]               gutter around the viewer's PANEL GROUP (not the title/footer)
---@field detail_label string                  palette accent NAME for detail-row labels (e.g. "blue")
---@field detail_value string                  palette accent NAME for detail-row values (e.g. "yellow")
---@field decode lvim-image.Config.Decode
---@field inline lvim-image.Config.Inline

---@class lvim-image.Config.Inline
---@field enabled boolean     auto-render inline images when a document buffer of a `filetypes` type opens
---@field filetypes string[]  document filetypes that auto-enable inline rendering (when `enabled`)
---@field max_width number    inline image cell width: fraction of the window (≤ 1) or absolute cells
---@field max_height number   inline image cell-height CAP: fraction of the window (≤ 1) or absolute cells
---@field debounce integer    ms after an edit before the placements are reconciled
---@field open_key string     buffer-local key (while inline is on) that opens the viewer for the image under the cursor

---@class lvim-image.Config.Decode
---@field libvips string|nil   explicit path to libvips.so (nil = auto-discover common soname)
---@field fallback boolean     when libvips is unavailable, decode via the ImageMagick CLI (magick/convert) in memory

---@type lvim-image.Config
return {
    enabled = true,
    -- Draw even on a terminal we could not probe (e.g. behind a proxy that eats query replies). Assumes the
    -- kitty protocol. Off by default so nothing is emitted into a terminal that would show it as garbage.
    force = false,
    -- "auto" picks the best detected protocol (kitty > iterm2 > sixel > ueberzug). Pin one to override.
    backend = "auto",
    -- Also register lvim-image as `vim.ui.img` (Neovim's EXPERIMENTAL native image API). OFF by default:
    -- lvim-image's own viewer / inline / attach work DIRECTLY regardless of Neovim version — this only adds an
    -- integration. When ON, the native `vim.ui.img` (and any plugin built on it) routes through lvim-image's
    -- tmux-aware `/dev/tty` backend, which the built-in `nvim_ui_send` backend cannot do under tmux. No effect
    -- on Neovim builds without `vim.ui.img`.
    provide_ui_img = false,
    -- Source formats we will try to display. PNG is passed through untouched; the rest are decoded to pixels
    -- IN MEMORY by libvips (never a temp copy on disk). Vector/pdf/video are rasterised lazily on first use.
    formats = {
        "png",
        "jpg",
        "jpeg",
        "gif",
        "bmp",
        "webp",
        "tiff",
        "tif",
        "heic",
        "avif",
        "svg",
        "pdf",
    },
    -- Max VIEWER size, as a FRACTION of the editor (≤ 1) or an absolute CELL count (> 1). The image is scaled
    -- to fit within this (aspect preserved); the popup then sizes TIGHTLY to the image + details panel, so a
    -- small image gets a small popup (no wasted space left/right).
    max_width = 0.8,
    max_height = 0.8,
    -- Gutter around the viewer's PANEL GROUP (the image + details) — an 8-element ring in nvim order
    -- { top-left, top, top-right, right, bottom-right, bottom, bottom-left, left }, or "none". It wraps ONLY the
    -- panels, NOT the title bar or the footer button bar, and applies whether or not the details are shown.
    -- Default: a blank " " gutter on the LEFT and RIGHT only.
    border = { "", "", "", " ", "", "", "", " " },
    -- Detail-row colours: palette accent NAMES (keys of `lvim-utils.colors`), NOT hardcoded hex — a colorscheme
    -- change re-tints them. Label uses one accent, value another.
    detail_label = "blue",
    detail_value = "yellow",
    decode = {
        -- Auto-discovered from a small soname list when nil (see image/decode.lua). Set an absolute path to
        -- pin a specific libvips build.
        libvips = nil,
        -- If libvips cannot be loaded, fall back to decoding through the ImageMagick CLI — `magick` (IM7) or
        -- `convert`/`identify` (IM6) — streaming pixels/PNG to stdout, still no disk cache file. Off keeps the
        -- module strictly libvips-only + PNG-passthrough.
        fallback = true,
    },
    -- Inline DOCUMENT images (markdown / html / latex): images are drawn as virtual lines under their source
    -- line. Rendering never edits the buffer text. Toggle per buffer with `:LvimImageInline`.
    inline = {
        -- Auto-render inline images when a document buffer of a `filetypes` type opens. `false` = purely
        -- on-demand (nothing renders until you run `:LvimImageInline on` in a buffer).
        enabled = true,
        -- Document filetypes that auto-enable inline rendering (when `enabled`). Markdown/HTML/LaTeX have
        -- shipped treesitter queries; other filetypes only match if a query exists for their language.
        filetypes = { "markdown", "html", "tex", "latex", "rmd", "quarto", "vimwiki", "org" },
        -- Cell box for an inline image: width as a FRACTION of the window (≤ 1) or absolute cells; height
        -- CAPPED (fraction of the window ≤ 1, or absolute cells) so a tall image can't push the whole document.
        max_width = 0.8,
        max_height = 30,
        -- Debounce (ms) after an edit before placements are reconciled — a burst of typing rebuilds once.
        debounce = 150,
        -- Buffer-local key (active only while inline is ON) that opens the full float viewer for the image on
        -- the cursor's line; off an image line it replays the key's native action, so it stays usable.
        open_key = "<CR>",
    },
}
