-- lvim-image.decode: turn any non-PNG raster (JPEG/GIF/WEBP/TIFF/HEIC/… and, via loaders, SVG/PDF) into
-- raw RGBA pixels IN MEMORY, using libvips through LuaJIT FFI. Nothing is ever written to disk — libvips
-- decodes to an in-memory sRGB + alpha uchar buffer that maps 1:1 onto the kitty `f=32` transmit format. This
-- is the whole point of the module's "no ImageMagick, no PNG cache" design: PNGs are passed through untouched
-- (see image.lua) and everything else is decoded here without a temp copy.
--
-- libvips' processing functions are variadic (a NULL-terminated option list); we call them with a trailing
-- `nil` to terminate with no options. `libvips.so.42` is discovered from a small soname list (overridable via
-- config.decode.libvips). The module degrades gracefully — if libvips cannot be loaded and
-- `config.decode.fallback` is on, decoding falls back to the ImageMagick CLI (`magick`/`convert`), still
-- entirely in memory (the tool streams the pixels/PNG to stdout — never a temp file); otherwise `to_rgba`
-- returns nil and the caller reports "unsupported format".
--
---@module "lvim-image.decode"

local config = require("lvim-image.config")

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")

-- Common sonames across distros / macOS. config.decode.libvips overrides with an absolute path.
local SONAMES = { "libvips.so.42", "libvips.so", "libvips.42.dylib", "libvips.dylib", "libvips-42.dll" }

-- VipsInterpretation / VipsBandFormat enum values we need.
local VIPS_INTERPRETATION_sRGB = 22
local VIPS_FORMAT_UCHAR = 0

---@type ffi.namespace*|nil
local vips = nil
---@type boolean|nil
local ready = nil

--- Load + initialise libvips once. Returns false (cached) when it is unavailable so callers fall back.
---@return boolean
local function ensure()
    if ready ~= nil then
        return ready
    end
    if not ffi_ok then
        ready = false
        return false
    end
    pcall(
        ffi.cdef,
        [[
        typedef void VipsImage;
        int   vips_init(const char* argv0);
        VipsImage* vips_image_new_from_file(const char* name, ...);
        int   vips_colourspace(VipsImage* in, VipsImage** out, int space, ...);
        int   vips_addalpha(VipsImage* in, VipsImage** out, ...);
        int   vips_cast(VipsImage* in, VipsImage** out, int format, ...);
        void* vips_image_write_to_memory(VipsImage* in, size_t* size_out);
        int   vips_pngsave_buffer(VipsImage* in, void** buf, size_t* len, ...);
        int   vips_image_get_width(VipsImage* image);
        int   vips_image_get_height(VipsImage* image);
        int   vips_image_get_bands(VipsImage* image);
        const char* vips_error_buffer(void);
        void  vips_error_clear(void);
        void  g_object_unref(void* object);
        void  g_free(void* mem);
    ]]
    )
    local names = config.decode.libvips and { config.decode.libvips } or SONAMES
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            vips = lib
            break
        end
    end
    if not vips then
        ready = false
        return false
    end
    ready = pcall(vips.vips_init, "lvim-image") and true or false
    return ready
end

--- Whether libvips-backed decoding is available on this system.
---@return boolean
function M.available()
    return ensure()
end

--- The last libvips error string (cleared as read).
---@return string
local function last_error()
    if not vips then
        return "libvips not loaded"
    end
    local msg = ffi.string(vips.vips_error_buffer())
    vips.vips_error_clear()
    return msg ~= "" and msg or "unknown libvips error"
end

---@class lvim-image.decode.Result
---@field rgba string   raw RGBA bytes, row-major, width*height*4
---@field w integer     pixel width
---@field h integer     pixel height

-- ─── external-CLI fallback (config.decode.fallback) ───────────────────────────
-- When libvips cannot be loaded, decode through the ImageMagick CLI instead — still entirely in memory (the
-- tool writes the pixels / PNG to stdout, captured here; never a temp file on disk). Used by to_rgba / to_png
-- only after ensure() has failed AND config.decode.fallback is on.

--- The ImageMagick invocation prefixes: IM7 ships one `magick` multi-tool (`magick …`, `magick identify …`);
--- IM6 ships separate `convert` / `identify` binaries. nil when ImageMagick is absent.
---@return { convert: string[], identify: string[] }?
local function magick_bins()
    if vim.fn.executable("magick") == 1 then
        return { convert = { "magick" }, identify = { "magick", "identify" } }
    end
    if vim.fn.executable("convert") == 1 and vim.fn.executable("identify") == 1 then
        return { convert = { "convert" }, identify = { "identify" } }
    end
    return nil
end

--- Run `argv`, capturing raw stdout BYTES. Returns nil + a message on any spawn failure / non-zero exit.
---@param argv string[]
---@return string? out, string? err
local function run(argv)
    local ok, res = pcall(function()
        return vim.system(argv, { text = false }):wait()
    end)
    if not ok then
        return nil, tostring(res)
    end
    if res.code ~= 0 then
        return nil, (res.stderr ~= "" and res.stderr) or ("exit " .. tostring(res.code))
    end
    return res.stdout
end

--- Decode `path` to RGBA + dimensions via ImageMagick (first frame/page only, matching the single-image
--- contract). `identify %w %h` gives the pixel size; `RGBA:-` streams the raw 8-bit RGBA that kitty `f=32` wants.
---@param path string
---@return lvim-image.decode.Result? result, string? err
local function external_rgba(path)
    local bins = magick_bins()
    if not bins then
        return nil, "libvips unavailable and ImageMagick (magick/convert) not found"
    end
    local first = path .. "[0]" -- first frame/page (GIF/PDF/…), so the buffer is exactly one image
    local dims, derr = run(vim.list_extend(bins.identify, { "-format", "%w %h", first }))
    if not dims then
        return nil, "identify failed: " .. (derr or "")
    end
    local ws, hs = dims:match("(%d+)%s+(%d+)")
    local w, h = tonumber(ws), tonumber(hs)
    if not w or not h then
        return nil, "identify: could not parse dimensions"
    end
    local rgba, cerr = run(vim.list_extend(bins.convert, { first, "-depth", "8", "RGBA:-" }))
    if not rgba then
        return nil, "convert failed: " .. (cerr or "")
    end
    -- Trust identify's WxH: keep exactly w*h*4 bytes (a short buffer would misalign the transmit).
    local need = w * h * 4
    if #rgba < need then
        return nil, ("convert: short RGBA buffer (%d < %d)"):format(#rgba, need)
    end
    return { rgba = rgba:sub(1, need), w = w, h = h }
end

--- Encode `path` to PNG bytes via ImageMagick (first frame/page), in memory.
---@param path string
---@return string? png, string? err
local function external_png(path)
    local bins = magick_bins()
    if not bins then
        return nil, "libvips unavailable and ImageMagick (magick/convert) not found"
    end
    local png, err = run(vim.list_extend(bins.convert, { path .. "[0]", "png:-" }))
    if not png then
        return nil, "png convert failed: " .. (err or "")
    end
    return png
end

--- Whether decoding of non-PNG formats is possible WITHOUT libvips — i.e. the fallback is enabled and
--- ImageMagick is present. Used by health to report the degraded-but-working path.
---@return boolean
function M.fallback_available()
    return config.decode.fallback == true and magick_bins() ~= nil
end

--- Decode `path` to RGBA pixels entirely in memory (no temp file). Normalises to sRGB, ensures a 4th (alpha)
--- band and 8-bit samples, then reads the raw buffer — exactly the `f=32` layout kitty wants.
---@param path string
---@return lvim-image.decode.Result? result, string? err
function M.to_rgba(path)
    if not ensure() then
        if config.decode.fallback then
            return external_rgba(path)
        end
        return nil, "libvips unavailable"
    end
    local v = assert(vips) -- non-nil once ensure() succeeded

    local img = v.vips_image_new_from_file(path, nil)
    if img == nil then
        return nil, "load failed: " .. last_error()
    end

    -- Chain: sRGB colourspace → ensure alpha → cast to uchar. Each step unrefs the previous image; `cur`
    -- always owns the single live VipsImage.
    local cur = img
    local function step(fn, ...)
        local out = ffi.new("VipsImage*[1]")
        if fn(cur, out, ...) ~= 0 then
            return false
        end
        v.g_object_unref(cur)
        cur = out[0]
        return true
    end

    if not step(v.vips_colourspace, VIPS_INTERPRETATION_sRGB, nil) then
        v.g_object_unref(cur)
        return nil, "colourspace failed: " .. last_error()
    end
    if v.vips_image_get_bands(cur) < 4 then
        if not step(v.vips_addalpha, nil) then
            v.g_object_unref(cur)
            return nil, "addalpha failed: " .. last_error()
        end
    end
    if not step(v.vips_cast, VIPS_FORMAT_UCHAR, nil) then
        v.g_object_unref(cur)
        return nil, "cast failed: " .. last_error()
    end

    local w = v.vips_image_get_width(cur)
    local h = v.vips_image_get_height(cur)
    local size = ffi.new("size_t[1]")
    local buf = v.vips_image_write_to_memory(cur, size)
    if buf == nil then
        v.g_object_unref(cur)
        return nil, "write_to_memory failed: " .. last_error()
    end

    local rgba = ffi.string(buf, size[0])
    v.g_free(buf)
    v.g_object_unref(cur)
    return { rgba = rgba, w = w, h = h }
end

--- Encode any libvips-readable source (JPEG/GIF/WEBP/TIFF/SVG/PDF/…) to PNG bytes IN MEMORY (no temp file).
--- Used by the escape protocols that need an ENCODED image rather than raw RGBA: iTerm2 (OSC 1337 wants a
--- complete image file) and sixel (fed to `img2sixel`). PNG sources should be read from disk directly instead.
---@param path string
---@return string? png, string? err
function M.to_png(path)
    if not ensure() then
        if config.decode.fallback then
            return external_png(path)
        end
        return nil, "libvips unavailable"
    end
    local v = assert(vips)
    local img = v.vips_image_new_from_file(path, nil)
    if img == nil then
        return nil, "load failed: " .. last_error()
    end
    local buf = ffi.new("void*[1]")
    local len = ffi.new("size_t[1]")
    local rc = v.vips_pngsave_buffer(img, buf, len, nil)
    v.g_object_unref(img)
    if rc ~= 0 or buf[0] == nil then
        return nil, "pngsave failed: " .. last_error()
    end
    local png = ffi.string(buf[0], len[0])
    v.g_free(buf[0])
    return png
end

return M
