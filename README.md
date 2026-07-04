# lvim-image

Display images **inside Neovim** across all terminal graphics protocols (kitty, iTerm2, sixel, ueberzugpp) —
part of the **lvim-tech** set. Non-PNG sources (JPEG / GIF / WEBP / TIFF / SVG / PDF / …) are decoded to pixels
**in memory** via libvips — no ImageMagick required and no PNG copies written to disk. It ships:

- a standalone floating **viewer** (`:LvimImage`) — a titled surface with the image, a toggleable details
  panel, and a footer bar;
- **inline document images** (`:LvimImageInline`) — images drawn as virtual lines under their source line in
  markdown / HTML / LaTeX (via shipped treesitter queries), never editing the buffer text;
- an **`attach`** entry point used by file-buffers and picker previews to render an image into any window.

## Requirements

Requires **Neovim >= 0.12.x**, [lvim-utils](https://github.com/lvim-tech/lvim-utils) (base) and
[lvim-ui](https://github.com/lvim-tech/lvim-ui) (the floating viewer builds on its surface toolkit). A terminal
with a graphics protocol (kitty / iTerm2 / sixel / ueberzugpp). For non-PNG formats, **libvips** (optionally
`gs` / `rsvg-convert` for PDF / SVG). Run `:checkhealth lvim-image` to see what is detected.

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-image" },
})
require("lvim-image").setup({})
```

## Usage

`setup()` runs terminal detection and registers the commands (the API also works without an explicit
`setup()` — it self-initialises on first use).

```vim
:LvimImage [path]          " open the floating viewer (default: the current file)
:LvimImageInline [on|off|toggle]  " toggle inline document images in the current buffer
```

```lua
local image = require("lvim-image")
image.show("/path/to/pic.png") -- open the float viewer
image.is_image(path) -- boolean: a displayable image (by extension)
image.attach(buf, win, src, opts) -- render into an existing buffer + window (previews)
image.info() -- the detected terminal + capabilities (also :checkhealth lvim-image)
```

## Configuration

`setup()` merges your options into the live config in place (a shorter override list replaces the default
wholesale). The full default config:

```lua
require("lvim-image").setup({
    enabled = true, -- master switch
    -- Draw even on a terminal we could not probe (assumes the kitty protocol). Off = emit nothing unless detected.
    force = false,
    -- "auto" picks the best detected protocol (kitty > iterm2 > sixel > ueberzug). Pin one to override.
    backend = "auto",
    -- Source formats to try. PNG is passed through untouched; the rest are decoded to pixels IN MEMORY by libvips.
    formats = { "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "tif", "heic", "avif", "svg", "pdf" },
    -- Max VIEWER size: a fraction of the editor (<=1) or an absolute cell count (>1). Aspect preserved; the
    -- popup then sizes tightly to the image + details panel.
    max_width = 0.8,
    max_height = 0.8,
    -- Gutter around the viewer's PANEL GROUP (image + details) — an 8-element ring in nvim order, or "none".
    -- Default: a blank " " gutter on the LEFT and RIGHT only.
    border = { "", "", "", " ", "", "", "", " " },
    -- Detail-row colours: palette accent NAMES (keys of lvim-utils.colors), not hardcoded hex.
    detail_label = "blue",
    detail_value = "yellow",
    decode = {
        libvips = nil, -- explicit path to libvips.so (nil = auto-discover a common soname)
        fallback = true, -- if libvips can't load, pipe `magick`/`vips` stdout into memory (still no disk cache)
    },
    -- Inline DOCUMENT images (markdown / html / latex): drawn as virtual lines under the source line.
    inline = {
        enabled = true, -- auto-render when a document buffer of a `filetypes` type opens (false = on-demand)
        filetypes = { "markdown", "html", "tex", "latex", "rmd", "quarto", "vimwiki", "org" },
        max_width = 0.8, -- inline cell width: fraction of the window (<=1) or absolute cells
        max_height = 30, -- inline cell-height CAP (fraction of the window <=1, or absolute cells)
        debounce = 150, -- ms after an edit before placements are reconciled
        open_key = "<CR>", -- buffer-local key (while inline is on) to open the viewer for the image under the cursor
    },
    debug = {
        request = false, -- log every graphics escape written
        decode = false, -- log the decode path taken (passthrough / libvips / fallback)
        placement = false, -- log placement geometry
    },
})
```

## License

BSD-3-Clause.
