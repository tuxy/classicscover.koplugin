-- classicscover.koplugin/main.lua
--
-- Flow:
--   1. Hold a book in the file browser.
--   2. Tap "Classics Cover" in the hold menu.
--   3. Confirm/edit title and author (auto-filled from book metadata).
--   4. The cover is rendered on the device: a random gradient background,
--      the black bottom panel, the CLASSICS strip and the title/author.
--   5. The PNG is saved as the book's custom cover.
--
-- Tools > Classics Cover Generator:
--   - Set title font size
--   - Set author font size
--   - About

local InfoMessage      = require("ui/widget/infomessage")
local InputDialog      = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local Event            = require("ui/event")
local ffiutil          = require("ffi/util")
local lfs              = require("libs/libkoreader-lfs")
local T                = ffiutil.template
local _                = require("gettext")

local CoverRenderer    = require("cover_renderer")

local DEFAULT_TITLE_FONT_SIZE = 70
local DEFAULT_AUTHOR_FONT_SIZE = 52
local MIN_FONT_SIZE = 12
local MAX_FONT_SIZE = 160

local TITLE_FONT_FILE = "/assets/fonts/EBGaramond-Italic.ttf"
local AUTHOR_FONT_FILE = "/assets/fonts/JosefinSans-SemiBold.ttf"
local LOGO_FILE = "/assets/logo.png"

-- Optional fallback fonts for characters the two cover fonts do not contain.
-- These are the fonts bundled with KOReader; missing files are simply skipped.
local FALLBACK_FONT_FILES = {
    "fonts/noto/NotoSans-Regular.ttf",
    "fonts/noto/NotoSansCJKsc-Regular.otf",
    "fonts/noto/NotoSansArabicUI-Regular.ttf",
    "fonts/noto/NotoSansDevanagariUI-Regular.ttf",
    "fonts/noto/NotoSansBengaliUI-Regular.ttf",
    "fonts/noto/NotoNaskhArabic-Regular.ttf",
}

local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)[/\\][^/\\]+$") or "."

local ClassicsCover = WidgetContainer:extend{
    name        = "classicscover",
    is_doc_only = false,
}

-- Settings helpers ------------------------------------------------------------

local function getKoreaderDir()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then return DS:getDataDir() end
    return (os.getenv("KOREADER_DIR") or "/mnt/onboard/.adds/koreader")
end

local function getOptionalFontSize(setting_key)
    local saved = G_reader_settings:readSetting(setting_key)
    if saved == nil or saved == "" then
        return nil
    end

    local size = tonumber(saved)
    if size and size > 0 then
        return math.floor(size)
    end

    G_reader_settings:saveSetting(setting_key, "")
    return nil
end

local function setOptionalFontSize(setting_key, size)
    if size == nil or size == "" then
        G_reader_settings:saveSetting(setting_key, "")
        return
    end

    G_reader_settings:saveSetting(setting_key, tostring(math.floor(size)))
end

local function getTitleFontSize()
    return getOptionalFontSize("penguincover_title_font_size")
end

local function setTitleFontSize(size)
    setOptionalFontSize("penguincover_title_font_size", size)
end

local function getAuthorFontSize()
    return getOptionalFontSize("penguincover_author_font_size")
end

local function setAuthorFontSize(size)
    setOptionalFontSize("penguincover_author_font_size", size)
end

local function getFallbackFonts()
    local root = getKoreaderDir()
    local fonts = {}
    for _, rel in ipairs(FALLBACK_FONT_FILES) do
        local path = root .. "/" .. rel
        if lfs.attributes(path, "mode") == "file" then
            fonts[#fonts + 1] = path
        end
    end
    return fonts
end

local function getTempCoverPath()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        local cache_dir = DS:getDataDir() .. "/cache"
        if lfs.attributes(cache_dir, "mode") == "directory" then
            return cache_dir .. "/classicscover-cover.png"
        end
    end
    return "/tmp/classicscover-cover.png"
end

local function normalizeText(s)
    -- Same whitespace normalisation as the old server: " ".join(value.split()).
    return (s or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Book metadata ---------------------------------------------------------------

local function getBookMeta(file_path)
    local title, author = "", ""

    -- 1) BookInfoManager cache (fast, no file open)
    local ok1, BIM = pcall(require, "bookinfomanager")
    if ok1 and BIM then
        local info = BIM:getBookInfo(file_path)
        if info then
            title  = info.title   or ""
            author = info.authors or ""
        end
    end

    -- 2) DocSettings sidecar
    if title == "" then
        local DocSettings = require("docsettings")
        if DocSettings:hasSidecarFile(file_path) then
            local ds    = DocSettings:open(file_path)
            local props = ds:readSetting("doc_props")
            if props then
                title  = props.title   or ""
                author = props.authors or props.author or ""
            end
        end
    end

    -- 3) Open the document (slow, last resort)
    if title == "" then
        local DR  = require("document/documentregistry")
        local doc = DR:openDocument(file_path)
        if doc then
            local props = doc:getProps()
            if props then
                title  = props.title   or ""
                author = props.authors or props.author or ""
            end
            doc:close()
        end
    end

    title  = (title  or ""):match("^%s*(.-)%s*$")
    author = (author or ""):match("^%s*(.-)%s*$")
    if title == "" then
        title = ffiutil.basename(file_path):gsub("%.[^%.]+$", "")
    end
    return title, author
end

local function invalidateThumbnail(file_path)
    local ok, BIM = pcall(require, "bookinfomanager")
    if ok and BIM then BIM:deleteBookInfo(file_path) end
end

-- Core: render and apply cover ------------------------------------------------

local function generateAndApplyCover(plugin_dir, file_path, title, author)
    local out_path = getTempCoverPath()

    local spinner = InfoMessage:new{
        text = _("Generating Classics cover..."), timeout = 0 }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local info, err = CoverRenderer.render{
        title            = title,
        author           = author,
        title_font_path  = plugin_dir .. TITLE_FONT_FILE,
        author_font_path = plugin_dir .. AUTHOR_FONT_FILE,
        logo_path        = plugin_dir .. LOGO_FILE,
        title_font_size  = getTitleFontSize(),
        author_font_size = getAuthorFontSize(),
        fallback_fonts   = getFallbackFonts(),
        output_path      = out_path,
    }

    UIManager:close(spinner)

    if not info then
        os.remove(out_path)
        UIManager:show(InfoMessage:new{
            text    = T(_("Cover generation failed:\n%1"), err or _("Unknown error")),
            timeout = 6 })
        return
    end

    local DocSettings = require("docsettings")
    local ds = DocSettings:open(file_path)
    if not ds:flushCustomCover(file_path, out_path) then
        os.remove(out_path)
        UIManager:show(InfoMessage:new{
            text = _("Cover was generated, but KOReader could not store it as a custom cover."),
            timeout = 5 })
        return
    end
    ds:getCustomCoverFile(true)
    os.remove(out_path)

    invalidateThumbnail(file_path)
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file_path))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))

    UIManager:show(InfoMessage:new{
        text = _("Classics cover applied!"), timeout = 3 })

    local FM = require("apps/filemanager/filemanager")
    if FM.instance then FM.instance:onRefresh() end
end

-- UI: confirm title / author --------------------------------------------------

local function showEditDialog(plugin_dir, file_path, title, author)
    local dlg
    dlg = MultiInputDialog:new{
        title  = _("Confirm Book Details"),
        fields = {
            { description = _("Title"),  text = title,  hint = _("Book title") },
            { description = _("Author"), text = author, hint = _("Author name") },
        },
        buttons = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Generate"),
                is_enter_default = true,
                callback         = function()
                    local fields = dlg:getFields()
                    local t = normalizeText(fields[1] or title)
                    local a = normalizeText(fields[2] or author)
                    if t == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("Title is required."), timeout = 3 })
                        return
                    end
                    if a == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("Author is required."), timeout = 3 })
                        return
                    end
                    UIManager:close(dlg)
                    generateAndApplyCover(plugin_dir, file_path, t, a)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Entry point -----------------------------------------------------------------

local function onGenerateCover(plugin_dir, file_path)
    local title, author = getBookMeta(file_path)
    showEditDialog(plugin_dir, file_path, title, author)
end

-- Plugin lifecycle ------------------------------------------------------------

function ClassicsCover:init()
    self.plugin_dir = self.path or PLUGIN_DIR
    getTitleFontSize()
    getAuthorFontSize()
    if not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
    self:_registerFileDialogButton()
end

function ClassicsCover:onTeardown()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.removeFileDialogButtons then
        FileManager:removeFileDialogButtons("classics_cover")
        FileManager._classicscover_button_registered = nil
    end
end

function ClassicsCover:_registerFileDialogButton()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or FileManager._classicscover_button_registered then
        return
    end
    FileManager._classicscover_button_registered = true

    local DocumentRegistry = require("document/documentregistry")
    FileManager:addFileDialogButtons("classics_cover", function(file, is_file)
        if not is_file or not DocumentRegistry:hasProvider(file) then
            return nil
        end
        return {{
            text = _("Classics Cover"),
            callback = function()
                local fc = FileManager.instance and FileManager.instance.file_chooser
                if fc and fc.file_dialog then
                    UIManager:close(fc.file_dialog)
                end
                onGenerateCover(self.plugin_dir, file)
            end,
        }}
    end)
end

-- Tools menu ------------------------------------------------------------------

local function showFontSizeDialog(setting_key, title, description, setter)
    local inp
    inp = InputDialog:new{
        title       = title,
        input       = tostring(getOptionalFontSize(setting_key) or ""),
        input_hint  = _("Leave empty for default"),
        description = description,
        buttons = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(inp) end,
            },
            {
                text     = _("Reset default"),
                callback = function()
                    setter(nil)
                    UIManager:close(inp)
                    UIManager:show(InfoMessage:new{
                        text    = _("Reset to the default size."),
                        timeout = 3 })
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local raw = inp:getInputText():match("^%s*(.-)%s*$")
                    if raw == "" then
                        setter(nil)
                        UIManager:close(inp)
                        return
                    end

                    local size = tonumber(raw)
                    if not size or size < MIN_FONT_SIZE or size > MAX_FONT_SIZE then
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Enter a number between %1 and %2."),
                                        MIN_FONT_SIZE, MAX_FONT_SIZE),
                            timeout = 4 })
                        return
                    end

                    size = math.floor(size)
                    setter(size)
                    UIManager:close(inp)
                    UIManager:show(InfoMessage:new{
                        text    = T(_("Font size set to %1."), size),
                        timeout = 3 })
                end,
            },
        }},
    }
    UIManager:show(inp)
    inp:onShowKeyboard()
end

function ClassicsCover:addToMainMenu(menu_items)
    menu_items.classicscover = {
        text           = _("Classics Cover Generator"),
        sorting_hint   = "tools",
        sub_item_table = {

            -- Title font size
            {
                text           = _("Set title font size"),
                keep_menu_open = true,
                callback       = function()
                    showFontSizeDialog("penguincover_title_font_size",
                        _("Title font size"),
                        T(_(
                            "Size of the book title on the cover, in pixels.\n"
                            .. "Default: %1. Range: %2 to %3.\n"
                            .. "Empty = default."
                        ), DEFAULT_TITLE_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE),
                        setTitleFontSize)
                end,
            },

            -- Author font size
            {
                text           = _("Set author font size"),
                keep_menu_open = true,
                callback       = function()
                    showFontSizeDialog("penguincover_author_font_size",
                        _("Author font size"),
                        T(_(
                            "Size of the author name on the cover, in pixels.\n"
                            .. "Default: %1. Range: %2 to %3.\n"
                            .. "Empty = default."
                        ), DEFAULT_AUTHOR_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE),
                        setAuthorFontSize)
                end,
            },

            -- About
            {
                text     = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_(
                            "Classics Cover Generator\n\n"
                            .. "Generates a Classics-style cover entirely on this device:\n"
                            .. "a random gradient background, the Classics strip, and the\n"
                            .. "book's title and author. No network connection is needed.\n\n"
                            .. "Hold a book > Classics Cover, confirm the title/author,\n"
                            .. "then tap Generate.\n\n"
                            .. "Title font size: %1\n"
                            .. "Author font size: %2"
                        ), getTitleFontSize() or DEFAULT_TITLE_FONT_SIZE,
                           getAuthorFontSize() or DEFAULT_AUTHOR_FONT_SIZE),
                    })
                end,
            },
        },
    }
end

return ClassicsCover
