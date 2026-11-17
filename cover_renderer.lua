--[[--
On-device cover renderer for the Classics Cover plugin.

This ports the layout of the original Flask/Pillow renderer to KOReader:
a random two-dimensional gradient fills the top of the cover, followed by the
black bottom panel, the white "CLASSICS <logo> EDITION" strip, the author name
in orange and the title in white.

Everything is drawn into a BlitBuffer with FreeType/LodePNG, so no server and
no external image tooling is involved.

The public entry point is CoverRenderer.render{...}, which writes a PNG file.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Freetype = require("ffi/freetype")
local ffi = require("ffi")
local logger = require("logger")

local ColorRGB32 = Blitbuffer.ColorRGB32
local TYPE_BBRGB32 = Blitbuffer.TYPE_BBRGB32

local CoverRenderer = {}

-- Cover geometry (identical to the original server-side renderer) -------------

local COVER_W = 1236
local COVER_H = 1648
local BLACK_H = 580
local STRIP_H = 110
local RULE_H = 3
local PADDING = 80
local BLACK_Y = COVER_H - BLACK_H        -- 1068
local STRIP_Y = BLACK_Y - STRIP_H        -- 958
local STRIP_CY = STRIP_Y + STRIP_H / 2   -- 1013

local DEFAULT_TITLE_FONT_SIZE = 70
local DEFAULT_AUTHOR_FONT_SIZE = 52
local MIN_FONT_SIZE = 12
local MAX_FONT_SIZE = 160

local STRIP_FONT_SIZE = 36
local STRIP_TEXT_SPACING = 10
local AUTHOR_TEXT_SPACING = 8
local TITLE_TEXT_SPACING = 2
local AUTHOR_LINE_GAP = 24
local TITLE_LINE_GAP = 32
local AUTHOR_TOP_OFFSET = 160

local COLOR_BLACK = ColorRGB32(0, 0, 0, 255)
local COLOR_WHITE = ColorRGB32(255, 255, 255, 255)
local COLOR_AUTHOR = ColorRGB32(230, 103, 37, 255)

local SMALL_WORDS = {
    a = true, an = true, the = true, ["and"] = true, but = true,
    ["or"] = true, ["for"] = true, nor = true, on = true, at = true,
    to = true, by = true, ["in"] = true, of = true, up = true,
    as = true, is = true,
}

local TWO_PI = math.pi * 2

-- Small helpers ----------------------------------------------------------------

local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function round(n)
    return math.floor(n + 0.5)
end

-- Unicode case helpers ---------------------------------------------------------
-- The original renderer used Python's Unicode-aware str.upper()/lower().
-- utf8proc is bundled with KOReader, so use it when available and fall back to
-- Lua's byte-oriented functions otherwise.

local Utf8Proc
pcall(function() Utf8Proc = require("ffi/utf8proc") end)

local function lower(s)
    if Utf8Proc then
        local ok, res = pcall(Utf8Proc.lowercase_dumb, s)
        if ok and res then return res end
    end
    return s:lower()
end

local function upper(s)
    if Utf8Proc then
        local ok, res = pcall(Utf8Proc.uppercase_dumb, s)
        if ok and res then return res end
    end
    return s:upper()
end

-- Decode one UTF-8 character at byte position i.
-- Returns the character string, its codepoint and the next byte position.
local function nextChar(s, i)
    local b = s:byte(i)
    if not b then return nil end
    if b < 0x80 then
        return s:sub(i, i), b, i + 1
    end

    local len, cp
    if b >= 0xC2 and b <= 0xDF then
        len, cp = 2, b - 0xC0
    elseif b >= 0xE0 and b <= 0xEF then
        len, cp = 3, b - 0xE0
    elseif b >= 0xF0 and b <= 0xF4 then
        len, cp = 4, b - 0xF0
    else
        return "\239\191\189", 0xFFFD, i + 1
    end

    for k = 1, len - 1 do
        local c = s:byte(i + k)
        if not c or c < 0x80 or c > 0xBF then
            return "\239\191\189", 0xFFFD, i + 1
        end
        cp = cp * 64 + (c - 0x80)
    end

    -- Reject overlong encodings, surrogates and out-of-range codepoints.
    if (len == 2 and cp < 0x80)
            or (len == 3 and cp < 0x800)
            or (len == 4 and cp < 0x10000)
            or cp > 0x10FFFF
            or (cp >= 0xD800 and cp <= 0xDFFF) then
        return "\239\191\189", 0xFFFD, i + 1
    end

    return s:sub(i, i + len - 1), cp, i + len
end

local function capitalizeWord(word)
    local ch, _, next_i = nextChar(word, 1)
    if not ch then return word end
    return upper(ch) .. lower(word:sub(next_i))
end

-- Mirrors Python's str.split() + capitalize() behaviour used by the server.
local function smartTitle(text)
    local out = {}
    local first = true
    for word in text:gmatch("%S+") do
        local lower_word = lower(word)
        if first or not SMALL_WORDS[lower_word] then
            out[#out + 1] = capitalizeWord(word)
        else
            out[#out + 1] = lower_word
        end
        first = false
    end
    return table.concat(out, " ")
end

-- Random gradient --------------------------------------------------------------

local function randomSeed()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(4)
        f:close()
        if bytes and #bytes == 4 then
            local n = 0
            for i = 1, 4 do
                n = n * 256 + bytes:byte(i)
            end
            return math.floor(n % 2147483647)
        end
    end
    return math.floor((os.time() + os.clock() * 1000000) % 2147483647)
end

local function hsvToRgb(h, s, v)
    h = h % 360
    local c = v * s
    local hp = h / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b
    if hp < 1 then
        r, g, b = c, x, 0
    elseif hp < 2 then
        r, g, b = x, c, 0
    elseif hp < 3 then
        r, g, b = 0, c, x
    elseif hp < 4 then
        r, g, b = 0, x, c
    elseif hp < 5 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    local m = v - c
    return (r + m) * 255, (g + m) * 255, (b + m) * 255
end

-- Build a random, deliberately harmonious three-stop gradient.
local function randomGradient()
    local monochrome = math.random() < 0.22
    local h0 = math.random() * 360
    local sign = math.random() < 0.5 and 1 or -1
    local h1 = h0 + sign * (18 + math.random() * 62)
    local h2
    if math.random() < 0.3 then
        h2 = h0 + 180 + (math.random() - 0.5) * 40
    else
        h2 = h1 + sign * (10 + math.random() * 50)
    end

    local s0 = monochrome and (0.04 + math.random() * 0.08) or (0.28 + math.random() * 0.30)
    local s1 = monochrome and (0.03 + math.random() * 0.07) or (0.24 + math.random() * 0.28)
    local s2 = monochrome and (0.02 + math.random() * 0.06) or (0.20 + math.random() * 0.26)

    local v0 = 0.14 + math.random() * 0.20
    local v1 = 0.40 + math.random() * 0.20
    local v2 = 0.68 + math.random() * 0.28

    -- Half of the covers run light -> dark instead of dark -> light.
    if math.random() < 0.5 then
        h0, h2 = h2, h0
        s0, s2 = s2, s0
        v0, v2 = v2, v0
    end

    local r0, g0, b0 = hsvToRgb(h0, s0, v0)
    local r1, g1, b1 = hsvToRgb(h1, s1, v1)
    local r2, g2, b2 = hsvToRgb(h2, s2, v2)

    return {
        stops = {
            { r0, g0, b0 },
            { r1, g1, b1 },
            { r2, g2, b2 },
        },
        angle = math.random() * TWO_PI,
    }
end

-- Paint a three-stop linear gradient. The colours are interpolated in RGB,
-- like the original renderer's background, but generated procedurally.
local function drawGradient(bb, gradient)
    local w, h = bb:getWidth(), bb:getHeight()
    local cos, sin = math.cos(gradient.angle), math.sin(gradient.angle)
    local cx, cy = (w - 1) / 2, (h - 1) / 2
    local ext = ((w - 1) * math.abs(cos) + (h - 1) * math.abs(sin)) / 2
    if ext <= 0 then ext = 1 end

    local c0, c1, c2 = gradient.stops[1], gradient.stops[2], gradient.stops[3]
    local d01r, d01g, d01b = c1[1] - c0[1], c1[2] - c0[2], c1[3] - c0[3]
    local d12r, d12g, d12b = c2[1] - c1[1], c2[2] - c1[2], c2[3] - c1[3]

    local pixels = ffi.cast("uint32_t*", bb.data)
    local pixel_stride = bb.pixel_stride
    local little_endian = ffi.abi("le")

    for y = 0, h - 1 do
        local row = y * pixel_stride
        local y_part = (y - cy) * sin
        for x = 0, w - 1 do
            local t = 0.5 + 0.5 * ((x - cx) * cos + y_part) / ext
            if t < 0 then t = 0 elseif t > 1 then t = 1 end

            local r, g, b
            if t < 0.5 then
                local u = t * 2
                r = c0[1] + d01r * u
                g = c0[2] + d01g * u
                b = c0[3] + d01b * u
            else
                local u = (t - 0.5) * 2
                r = c1[1] + d12r * u
                g = c1[2] + d12g * u
                b = c1[3] + d12b * u
            end

            r = math.floor(r + 0.5)
            g = math.floor(g + 0.5)
            b = math.floor(b + 0.5)

            if little_endian then
                pixels[row + x] = r + g * 256 + b * 65536 + 4278190080
            else
                pixels[row + x] = r * 16777216 + g * 65536 + b * 256 + 255
            end
        end
    end
end

-- Fonts and text ---------------------------------------------------------------
--
-- The original renderer used Pillow with the fonts shipped in assets/fonts/.
-- To keep the exact same pixel sizes we bypass Font:getFace() (which scales
-- sizes by the screen size/DPI) and instantiate FreeType faces directly.

local function newFace(path, px)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, px)
    if not ok or not ftsize then
        logger.warn("ClassicsCover: cannot load font", path, ftsize)
        return nil
    end
    return {
        path = path,
        size = px,
        orig_size = px,
        ftsize = ftsize,
        hash = path .. "@" .. px,
        glyphs = {},
    }
end

local function getFallbackFace(ctx, px, codepoint)
    local cache = ctx.fallback_faces[px]
    if not cache then
        cache = {}
        ctx.fallback_faces[px] = cache
    end
    for i, path in ipairs(ctx.fallback_fonts) do
        local face = cache[i]
        if face == nil then
            face = newFace(path, px) or false
            cache[i] = face
        end
        if face and face.ftsize:hasGlyph(codepoint) then
            return face
        end
    end
    return nil
end

local function getGlyph(face, codepoint, ctx)
    local cached = face.glyphs[codepoint]
    if cached ~= nil then
        return cached or nil
    end

    local glyph
    if face.ftsize:hasGlyph(codepoint) then
        glyph = face.ftsize:renderGlyph(codepoint)
    else
        local fallback = getFallbackFace(ctx, face.size, codepoint)
        if fallback then
            glyph = fallback.ftsize:renderGlyph(codepoint)
        else
            -- Draw the font's .notdef glyph, just like Pillow does.
            glyph = face.ftsize:renderGlyph(codepoint)
        end
    end

    face.glyphs[codepoint] = glyph or false
    return glyph
end

-- Advance width of a string, plus the extra letter spacing the server applied
-- after every non-space character.
local function textWidth(face, text, spacing, ctx)
    local width, non_spaces = 0, 0
    local i = 1
    while i <= #text do
        local ch, codepoint, next_i = nextChar(text, i)
        if not ch then break end
        local glyph = getGlyph(face, codepoint, ctx)
        if glyph then
            width = width + glyph.ax
        end
        if ch ~= " " then
            non_spaces = non_spaces + 1
        end
        i = next_i
    end
    return width + non_spaces * spacing
end

-- Distance from the baseline to the top/bottom of the string's ink.
-- This is Pillow's font.getbbox(text): y0 == ascent - top, y1 == ascent + bottom.
local function textInk(face, text, ctx)
    local top, bottom = 0, 0
    local i = 1
    while i <= #text do
        local _, codepoint, next_i = nextChar(text, i)
        if not next_i then break end
        local glyph = getGlyph(face, codepoint, ctx)
        if glyph then
            if glyph.t > top then top = glyph.t end
            local glyph_bottom = glyph.bb:getHeight() - glyph.t
            if glyph_bottom > bottom then bottom = glyph_bottom end
        end
        i = next_i
    end
    return top, bottom
end

-- colorblitFrom() collapses the colour to its grayscale value (it was designed
-- for e-ink framebuffers). Use the RGB32 variant when available so that the
-- orange author text stays orange on colour screens.
local HAS_RGB32_COLOR_BLIT = Blitbuffer.BlitBufferRGB32
    and Blitbuffer.BlitBufferRGB32.colorblitFromRGB32 ~= nil

-- Draw a line with the same per-character extra spacing as the server.
local function drawText(bb, x, baseline, face, text, spacing, text_color, ctx)
    local pen = 0
    local i = 1
    while i <= #text do
        local ch, codepoint, next_i = nextChar(text, i)
        if not ch then break end
        local glyph = getGlyph(face, codepoint, ctx)
        if glyph then
            local gw, gh = glyph.bb:getWidth(), glyph.bb:getHeight()
            if gw > 0 and gh > 0 then
                local dest_x = math.floor(x + pen + glyph.l)
                local dest_y = math.floor(baseline - glyph.t)
                if HAS_RGB32_COLOR_BLIT then
                    bb:colorblitFromRGB32(glyph.bb, dest_x, dest_y,
                        0, 0, gw, gh, text_color)
                else
                    bb:colorblitFrom(glyph.bb, dest_x, dest_y,
                        0, 0, gw, gh, text_color)
                end
            end
            pen = pen + glyph.ax
        end
        if ch ~= " " then
            pen = pen + spacing
        end
        i = next_i
    end
    return pen
end

-- Greedy word wrapping on rendered width, as in the original renderer.
-- A word wider than the available line is split between characters instead of
-- being drawn off the cover.
local function breakLongWord(word, face, max_width, spacing, ctx)
    local chunks = {}
    local current = ""
    local i = 1
    while i <= #word do
        local ch, _, next_i = nextChar(word, i)
        if not ch then break end
        local candidate = current .. ch
        if current == "" or textWidth(face, candidate, spacing, ctx) <= max_width then
            current = candidate
        else
            chunks[#chunks + 1] = current
            current = ch
        end
        i = next_i
    end
    if current ~= "" then
        chunks[#chunks + 1] = current
    end
    return chunks
end

local function wrapText(text, face, max_width, spacing, ctx)
    local lines = {}
    local current = nil
    for word in text:gmatch("%S+") do
        local candidate = current and (current .. " " .. word) or word
        if textWidth(face, candidate, spacing, ctx) <= max_width then
            current = candidate
        else
            if current then
                lines[#lines + 1] = current
            end
            if textWidth(face, word, spacing, ctx) > max_width then
                local chunks = breakLongWord(word, face, max_width, spacing, ctx)
                for i = 1, #chunks - 1 do
                    lines[#lines + 1] = chunks[i]
                end
                current = chunks[#chunks]
            else
                current = word
            end
        end
    end
    if current then
        lines[#lines + 1] = current
    end
    return lines
end

-- Logo ------------------------------------------------------------------------

-- Decode the logo and resize it to the strip, preserving straight alpha.
-- A box filter is used because it is a downscale (128x128 -> 50x50).
local function loadLogo(path, target_h)
    local ok, Png = pcall(require, "ffi/png")
    if not ok then
        return nil, nil, "PNG decoder unavailable"
    end
    local called, decoded, img = pcall(Png.decodeFromFile, path, 4)
    if not called or not decoded or not img then
        return nil, nil, tostring(img or "cannot decode logo")
    end

    local src_w, src_h = img.width, img.height
    local target_w = math.floor(src_w * target_h / src_h)
    local src = ffi.cast("uint8_t*", img.data)

    local dst = Blitbuffer.new(target_w, target_h, TYPE_BBRGB32)
    local pixels = ffi.cast("ColorRGB32*", dst.data)
    local pixel_stride = dst.pixel_stride

    for dy = 0, target_h - 1 do
        local sy0 = math.floor(dy * src_h / target_h)
        local sy1 = math.floor((dy + 1) * src_h / target_h)
        if sy1 <= sy0 then sy1 = sy0 + 1 end
        for dx = 0, target_w - 1 do
            local sx0 = math.floor(dx * src_w / target_w)
            local sx1 = math.floor((dx + 1) * src_w / target_w)
            if sx1 <= sx0 then sx1 = sx0 + 1 end

            local alpha_sum, red_sum, green_sum, blue_sum, count = 0, 0, 0, 0, 0
            for sy = sy0, sy1 - 1 do
                local row = sy * src_w * 4
                for sx = sx0, sx1 - 1 do
                    local offset = row + sx * 4
                    local a = src[offset + 3]
                    if a > 0 then
                        red_sum = red_sum + src[offset] * a
                        green_sum = green_sum + src[offset + 1] * a
                        blue_sum = blue_sum + src[offset + 2] * a
                        alpha_sum = alpha_sum + a
                    end
                    count = count + 1
                end
            end

            local r, g, b = 0, 0, 0
            if alpha_sum > 0 then
                r = red_sum / alpha_sum
                g = green_sum / alpha_sum
                b = blue_sum / alpha_sum
            end
            pixels[dy * pixel_stride + dx] = ColorRGB32(
                round(r), round(g), round(b), round(alpha_sum / count))
        end
    end

    ffi.C.free(img.data)
    return dst, target_w
end

-- Cover composition ------------------------------------------------------------

local function drawCover(cover, opts, gradient, ctx)
    -- Background gradient (only the area above the white strip).
    local background = Blitbuffer.new(COVER_W, STRIP_Y, TYPE_BBRGB32)
    drawGradient(background, gradient)
    cover:blitFrom(background, 0, 0, 0, 0, COVER_W, STRIP_Y)
    background:free()

    -- Black bottom panel and white strip with its two rules.
    cover:paintRectRGB32(0, BLACK_Y, COVER_W, BLACK_H, COLOR_BLACK)
    cover:paintRectRGB32(0, STRIP_Y, COVER_W, STRIP_H, COLOR_WHITE)
    cover:paintRectRGB32(0, STRIP_Y, COVER_W, RULE_H, COLOR_BLACK)
    cover:paintRectRGB32(0, STRIP_Y + STRIP_H - RULE_H, COVER_W, RULE_H, COLOR_BLACK)

    -- Strip: CLASSICS <logo> EDITION
    local strip_face = newFace(opts.author_font_path, STRIP_FONT_SIZE)
    if not strip_face then
        return nil, "Cannot load strip font."
    end

    local logo_h = STRIP_H - 60
    local logo_bb, logo_w, logo_err = loadLogo(opts.logo_path, logo_h)
    if not logo_bb then
        return nil, "Cannot load logo: " .. tostring(logo_err)
    end

    local left_text = "CLASSICS"
    local right_text = " EDITION"
    local gap = 30
    local left_w = textWidth(strip_face, left_text, STRIP_TEXT_SPACING, ctx)
    local right_w = textWidth(strip_face, right_text, STRIP_TEXT_SPACING, ctx)
    local total_w = left_w + gap + logo_w + gap + right_w
    local start_x = (COVER_W - total_w) / 2

    local strip_top, strip_bottom = textInk(strip_face, "A", ctx)
    local strip_ink = strip_top + strip_bottom
    local _, strip_ascent = strip_face.ftsize:getHeightAndAscender()
    local strip_baseline = STRIP_CY - strip_ink / 2 + strip_ascent

    drawText(cover, start_x, strip_baseline, strip_face, left_text,
        STRIP_TEXT_SPACING, COLOR_BLACK, ctx)

    local logo_x = math.floor(start_x + left_w + gap)
    local logo_y = math.floor(STRIP_CY - logo_h / 2)
    cover:alphablitFrom(logo_bb, logo_x, logo_y, 0, 0, logo_w, logo_h)
    logo_bb:free()

    local right_x = logo_x + logo_w + gap
    drawText(cover, right_x, strip_baseline, strip_face, right_text,
        STRIP_TEXT_SPACING, COLOR_BLACK, ctx)

    -- Author (uppercase, orange).
    local author_face = newFace(opts.author_font_path, opts.author_font_size)
    if not author_face then
        return nil, "Cannot load author font."
    end
    local author_text = upper(opts.author or "")
    local author_lines = wrapText(author_text, author_face,
        COVER_W - PADDING * 2, AUTHOR_TEXT_SPACING, ctx)
    -- The original renderer used bbox("A") (cap height) for the author's
    -- line pitch, and bbox("Ag") only for the title's pitch.
    local author_top, author_bottom = textInk(author_face, "A", ctx)
    local author_font_h = author_top + author_bottom

    local author_y = BLACK_Y + AUTHOR_TOP_OFFSET
    for _, line in ipairs(author_lines) do
        local line_w = textWidth(author_face, line, AUTHOR_TEXT_SPACING, ctx)
        local line_top = textInk(author_face, line, ctx)
        drawText(cover, (COVER_W - line_w) / 2, author_y + line_top,
            author_face, line, AUTHOR_TEXT_SPACING,
            COLOR_AUTHOR, ctx)
        author_y = author_y + author_font_h + AUTHOR_LINE_GAP
    end

    -- Title (italic, white, centered in the remaining black area).
    -- If a long title would not fit, shrink it just enough to fit instead of
    -- letting it run off the bottom of the cover.
    local title_text = smartTitle(opts.title or "")
    local area_top = author_y + 10
    local area_bottom = COVER_H - 10
    local available_h = area_bottom - area_top
    if available_h < 1 then available_h = 1 end

    local title_size = opts.title_font_size
    local title_face, title_lines, title_font_h, total_title_h
    for _ = 1, 6 do
        title_face = newFace(opts.title_font_path, title_size)
        if not title_face then
            return nil, "Cannot load title font."
        end
        title_lines = wrapText(title_text, title_face,
            COVER_W - PADDING * 2, TITLE_TEXT_SPACING, ctx)
        local title_top, title_bottom = textInk(title_face, "Ag", ctx)
        title_font_h = title_top + title_bottom
        local line_count = #title_lines
        total_title_h = line_count * title_font_h + (line_count - 1) * TITLE_LINE_GAP
        if total_title_h <= available_h or title_size <= MIN_FONT_SIZE then
            break
        end
        local new_size = math.floor(title_size * available_h / total_title_h * 0.97)
        if new_size >= title_size then
            new_size = title_size - 1
        end
        title_size = math.max(MIN_FONT_SIZE, new_size)
    end

    local start_y
    if total_title_h > available_h then
        start_y = area_top
    else
        start_y = area_top + (available_h - total_title_h) / 2
    end

    for _, line in ipairs(title_lines) do
        local line_w = textWidth(title_face, line, TITLE_TEXT_SPACING, ctx)
        local line_top = textInk(title_face, line, ctx)
        drawText(cover, (COVER_W - line_w) / 2, start_y + line_top,
            title_face, line, TITLE_TEXT_SPACING,
            COLOR_WHITE, ctx)
        start_y = start_y + title_font_h + TITLE_LINE_GAP
    end

    return true
end

-- Public API -------------------------------------------------------------------

--- Render a Classics cover to a PNG file.
--
-- @tparam table opts
--   title               (string) book title
--   author              (string) author name
--   title_font_path     (string) path to the title TTF/OTF
--   author_font_path    (string) path to the author TTF/OTF
--   logo_path           (string) path to the logo PNG
--   title_font_size     (int)    optional, defaults to 70
--   author_font_size    (int)    optional, defaults to 52
--   fallback_fonts      (table)  optional list of fallback font paths
--   output_path         (string) destination PNG path
--   seed                (int)    optional, for reproducible results
-- @treturn table|nil info on success (seed and gradient), nil plus a message on failure
function CoverRenderer.render(opts)
    if not opts or not opts.output_path then
        return nil, "No output path provided."
    end
    if not opts.title_font_path or not opts.author_font_path or not opts.logo_path then
        return nil, "Missing font or logo path."
    end

    -- Never let a stale file from a previous failed run pass the checks below.
    os.remove(opts.output_path)

    local seed = opts.seed or randomSeed()
    math.randomseed(seed)
    local gradient = randomGradient()

    local cover = Blitbuffer.new(COVER_W, COVER_H, TYPE_BBRGB32)
    local ctx = {
        fallback_fonts = opts.fallback_fonts or {},
        fallback_faces = {},
    }

    local ok, err = drawCover(cover, {
        title = opts.title or "",
        author = opts.author or "",
        title_font_path = opts.title_font_path,
        author_font_path = opts.author_font_path,
        logo_path = opts.logo_path,
        title_font_size = clamp(opts.title_font_size or DEFAULT_TITLE_FONT_SIZE,
            MIN_FONT_SIZE, MAX_FONT_SIZE),
        author_font_size = clamp(opts.author_font_size or DEFAULT_AUTHOR_FONT_SIZE,
            MIN_FONT_SIZE, MAX_FONT_SIZE),
    }, gradient, ctx)

    if not ok then
        cover:free()
        return nil, err
    end

    local written, write_err = pcall(cover.writePNG, cover, opts.output_path)
    cover:free()
    if not written then
        return nil, tostring(write_err)
    end

    local file = io.open(opts.output_path, "rb")
    if not file then
        return nil, "PNG could not be written."
    end
    local size = file:seek("end")
    file:close()
    if not size or size == 0 then
        os.remove(opts.output_path)
        return nil, "PNG is empty."
    end

    return {
        seed = seed,
        gradient = gradient,
        size = size,
    }
end

return CoverRenderer
