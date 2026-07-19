# lvim-image

Display images **inside Neovim** across all terminal graphics protocols (kitty, iTerm2, sixel, ueberzugpp) —
part of the **lvim-tech** set. Non-PNG sources (JPEG / GIF / WEBP / TIFF / SVG / PDF / …) are decoded to pixels
**in memory** via libvips (or, if libvips is unavailable, an optional ImageMagick-CLI fallback) — no PNG copies
written to disk. It ships:

- a standalone floating **viewer** (`:LvimImage`) — a titled surface with the image, a toggleable details
  panel, and a footer bar;
- **inline document images** (`:LvimImageInline`) — images drawn as virtual lines under their source line in
  markdown / HTML / LaTeX (via shipped treesitter queries), never editing the buffer text;
- an **`attach`** entry point used by file-buffers and picker previews to render an image into any window.

## Requirements

Requires **Neovim >= 0.12.x**, [lvim-utils](https://github.com/lvim-tech/lvim-utils) (base) and
[lvim-ui](https://github.com/lvim-tech/lvim-ui) (the floating viewer builds on its surface toolkit). A terminal
with a graphics protocol (kitty / iTerm2 / sixel / ueberzugpp). For non-PNG formats, **libvips** (optionally
`gs` / `rsvg-convert` for PDF / SVG), or **ImageMagick** (`magick`/`convert`) as the `decode.fallback`. Run
`:checkhealth lvim-image` to see what is detected.

## Protocol support

The protocol is auto-detected (override with `backend`). What each one can do differs by the terminal model:

| Protocol   | Terminals                                         | Viewer / attach | Inline images | Extra tool  |
| ---------- | ------------------------------------------------- | --------------- | ------------- | ----------- |
| `kitty`    | kitty, ghostty, WezTerm                           | yes             | yes           | —           |
| `ueberzug` | any X11/Wayland session                           | yes             | no            | `ueberzugpp`|
| `iterm2`   | iTerm2, WezTerm, Konsole                          | yes (static)    | no            | —           |
| `sixel`    | foot, contour, mlterm, xterm +sixel, WezTerm, …   | yes (static)    | no            | `img2sixel` |

- **kitty** uses unicode placeholders — the image is tied to buffer cells the terminal repaints as they scroll,
  so both the viewer AND inline document images track perfectly. Best experience.
- **ueberzug** draws in a separate overlay window layered over the terminal (a `ueberzugpp` daemon), so it
  survives redraws and is repositioned on relayout. The universal fallback where kitty is unavailable.
- **iterm2 / sixel** draw straight into the terminal grid at the cursor, so a static float viewer shows the
  image but a repaint of that region clears it — great for the viewer, not for scrolling **inline** images.
  Sixel needs `img2sixel` (libsixel) on `PATH`.

Inline document images therefore require **kitty**; on the other protocols `:LvimImageInline` is a no-op while
the `:LvimImage` viewer still works. `:checkhealth lvim-image` reports the active protocol and any missing tool.

## Neovim `vim.ui.img` integration

Neovim ships an experimental native image API, `vim.ui.img`. Its built-in backend writes via `nvim_ui_send`
with no tmux passthrough, so `:checkhealth img` reports *not supported* inside tmux and images don't display
there. Set `provide_ui_img = true` and lvim-image registers itself as `vim.ui.img` — the native API (and any
plugin built on it) then routes through lvim-image's tmux-aware `/dev/tty` backend and works under tmux. It is
opt-in and additive: lvim-image's own `:LvimImage` / inline / `attach` work directly regardless. (Like the
native backend it is screen-positional — for content-anchored images use the plugin's own inline path.)

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
    -- Also register lvim-image as Neovim's native `vim.ui.img` (opt-in). The direct API is unaffected; when on,
    -- the native image API (and plugins built on it) route through lvim-image's tmux-aware /dev/tty backend.
    provide_ui_img = false,
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
        fallback = true, -- if libvips can't load, decode via the ImageMagick CLI (magick/convert) in memory (no disk cache)
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
})
```

## License

BSD-3-Clause.
