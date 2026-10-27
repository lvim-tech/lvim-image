-- Reading an image's size without decoding it, and fitting it to a grid of cells.
--
-- util.lua is "kept dependency-free so the sizing math never needs libvips" -- it parses PNG, GIF
-- and JPEG headers inline. That makes it exactly testable: a header is a handful of bytes, so the
-- cases below BUILD one and ask. The JPEG walk is the interesting one: it steps over marker
-- segments to the SOFn frame header, so a file with a comment or an EXIF block before the frame
-- must still answer, and height comes before width in that header.

local util = require("lvim-image.util")
local placement = require("lvim-image.placement")

--- A big-endian u16 as two bytes.
---@param n integer
---@return string
local function be16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

--- A big-endian u32 as four bytes.
---@param n integer
---@return string
local function be32(n)
    return string.char(
        math.floor(n / 0x1000000) % 256,
        math.floor(n / 0x10000) % 256,
        math.floor(n / 0x100) % 256,
        n % 256
    )
end

--- A minimal PNG header: signature, the IHDR length + tag, then width and height.
---@param w integer
---@param h integer
---@return string
local function png(w, h)
    return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
end

--- A minimal GIF header: the signature then width and height as LITTLE-endian u16.
---@param w integer
---@param h integer
---@param sig? string
---@return string
local function gif(w, h, sig)
    local function le16(n)
        return string.char(n % 256, math.floor(n / 256) % 256)
    end
    return (sig or "GIF89a") .. le16(w) .. le16(h) .. "\247\0\0"
end

--- A minimal JPEG: SOI, any number of `segments`, then an SOFn frame carrying height and width.
---@param w integer
---@param h integer
---@param segments? string[]  raw marker segments to put BEFORE the frame header
---@param sof? integer        the SOFn marker byte (0xC0 by default)
---@return string
local function jpeg(w, h, segments, sof)
    local out = { "\255\216" }
    for _, seg in ipairs(segments or {}) do
        out[#out + 1] = seg
    end
    -- SOFn: marker, segment length, precision, height, width, components
    local body = "\8" .. be16(h) .. be16(w) .. "\3"
    out[#out + 1] = "\255" .. string.char(sof or 0xC0) .. be16(#body + 2) .. body
    return table.concat(out)
end

--- A marker segment of `marker` with `payload` bytes (its own length field included).
---@param marker integer
---@param payload string
---@return string
local function segment(marker, payload)
    return "\255" .. string.char(marker) .. be16(#payload + 2) .. payload
end

describe("lvim-image: a raster's size, from its header alone")

it("a PNG answers from its IHDR", function()
    eq({ w = 800, h = 600 }, util.bytes_dim(png(800, 600)))
    eq({ w = 1, h = 1 }, util.bytes_dim(png(1, 1)))
    eq({ w = 4096, h = 2160 }, util.bytes_dim(png(4096, 2160)), "a u32 width, not a u16")
end)

it("a PNG whose IHDR is not where it should be is not a PNG we can read", function()
    local broken = "\137PNG\r\n\26\n" .. be32(13) .. "IDAT" .. be32(10) .. be32(10)
    eq(nil, util.bytes_dim(broken))
end)

it("a GIF answers from its little-endian header", function()
    eq({ w = 300, h = 200 }, util.bytes_dim(gif(300, 200)))
    eq({ w = 300, h = 200 }, util.bytes_dim(gif(300, 200, "GIF87a")), "both signatures are GIFs")
    eq(nil, util.bytes_dim(gif(300, 200, "GIF90a")), "and nothing else is")
end)

it("a JPEG is walked to its frame header", function()
    eq({ w = 640, h = 480 }, util.bytes_dim(jpeg(640, 480)))
end)

it("a JPEG with segments before the frame is still read", function()
    local head = jpeg(1024, 768, {
        segment(0xE0, "JFIF\0" .. ("\0"):rep(10)), -- APP0
        segment(0xE1, "Exif\0\0" .. ("x"):rep(64)), -- APP1 / EXIF
        segment(0xFE, "a comment"), -- COM
    })
    eq({ w = 1024, h = 768 }, util.bytes_dim(head), "the walk has to step over everything before the frame")
end)

it("every SOF variant that carries dimensions is read, and the ones that do not are skipped", function()
    for _, sof in ipairs({ 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC9, 0xCD, 0xCF }) do
        eq({ w = 320, h = 240 }, util.bytes_dim(jpeg(320, 240, {}, sof)), ("SOF marker %02X"):format(sof))
    end
    -- 0xC4 is a Huffman table, not a frame: a file whose only C-range marker is one has no size here.
    local only_dht = "\255\216" .. segment(0xC4, ("\0"):rep(20))
    eq(nil, util.bytes_dim(only_dht))
end)

it("height comes before width in a JPEG frame, and swapping them would show", function()
    local head = jpeg(100, 900)
    eq({ w = 100, h = 900 }, util.bytes_dim(head), "a portrait image must not read as landscape")
end)

it("something that is not an image answers with nothing", function()
    eq(nil, util.bytes_dim("not an image at all"))
    eq(nil, util.bytes_dim(""))
    eq(nil, util.bytes_dim("\255\216"), "a JPEG signature with no frame is not a size")
end)

it("the same header read from a file gives the same answer", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/subject.png"
    local fd = assert(io.open(path, "wb"))
    fd:write(png(123, 456))
    fd:close()

    eq({ w = 123, h = 456 }, util.file_dim(path))
    eq(nil, util.file_dim(dir .. "/does-not-exist.png"))
end)

describe("lvim-image: pixels to cells")

it("a pixel box rounds UP to whole cells, so nothing is clipped short", function()
    local cols, rows = util.pixels_to_cells(100, 100, 10, 20)
    eq(10, cols)
    eq(5, rows)

    cols, rows = util.pixels_to_cells(101, 101, 10, 20)
    eq(11, cols, "a fractional column still needs a whole cell")
    eq(6, rows)
end)

it("anything visible occupies at least one cell", function()
    local cols, rows = util.pixels_to_cells(1, 1, 10, 20)
    eq(1, cols)
    eq(1, rows)
end)

it("a zero cell size cannot divide by zero", function()
    local cols, rows = util.pixels_to_cells(100, 100, 0, 0)
    eq(100, cols, "a cell of zero pixels is treated as one")
    eq(100, rows)
end)

describe("lvim-image: fitting a box of cells")

it("a box that already fits is left alone", function()
    local cols, rows = util.fit(10, 5, 80, 24)
    eq(10, cols)
    eq(5, rows)
end)

it("a box is never upscaled to fill the window", function()
    local cols, rows = util.fit(4, 2, 200, 100)
    eq(4, cols, "a small image stays its natural size")
    eq(2, rows)
end)

it("shrinking preserves the aspect ratio", function()
    local cols, rows = util.fit(100, 50, 50, 100)
    eq(50, cols, "width is the binding limit")
    eq(25, rows, "and the height follows it")

    cols, rows = util.fit(100, 50, 1000, 10)
    eq(20, cols, "height is the binding limit")
    eq(10, rows)
end)

it("a fitted box never collapses to nothing", function()
    local cols, rows = util.fit(1000, 1, 10, 10)
    eq(10, cols)
    eq(1, rows, "a one-cell-high image stays visible")
end)

it("a degenerate size is one cell, not an error", function()
    eq({ 1, 1 }, { util.fit(0, 0, 80, 24) })
    eq({ 1, 1 }, { util.fit(-5, 10, 80, 24) })
end)

describe("lvim-image: the kitty placeholder table")

it("the diacritic table is the kitty spec's, in order and without repeats", function()
    -- The row/column of every image cell is encoded as an index into this table, so a duplicate or
    -- an out-of-order entry silently puts a cell in the wrong place.
    local dia = placement._diacritics
    if dia == nil then
        skip("the diacritic table", "placement does not expose it")
        return
    end
    eq(297, #dia, "kitty's rowcolumn-diacritics.txt carries 297 entries")
    local seen = {}
    for i, cp in ipairs(dia) do
        truthy(type(cp) == "number" and cp > 0, "entry " .. i .. " is not a codepoint")
        eq(nil, seen[cp], ("codepoint %04X appears twice"):format(cp))
        seen[cp] = true
        if i > 1 then
            truthy(cp > dia[i - 1], ("entry %d (%04X) does not come after %04X"):format(i, cp, dia[i - 1]))
        end
    end
end)
