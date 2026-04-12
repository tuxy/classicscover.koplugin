-- classicscover.koplugin/main.lua
--
-- Flow:
--   1. Hold a book in the file browser.
--   2. Tap "Classics Cover" in the hold menu.
--   3. Pick a background image from the backgrounds folder.
--   4. Confirm/edit title and author (auto-filled from book metadata).
--   5. POST background + title + author to the Flask server.
--   6. The returned PNG is saved as the book's custom cover.
--
-- Tools > Classics Cover Generator:
--   - Set backgrounds folder  (default: <koreader>/backgrounds/)
--   - Change server URL
--   - About

local InfoMessage      = require("ui/widget/infomessage")
local InputDialog      = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr       = require("ui/network/manager")
local PathChooser      = require("ui/widget/pathchooser")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local Event            = require("ui/event")
local ffiutil          = require("ffi/util")
local lfs              = require("libs/libkoreader-lfs")
local T                = ffiutil.template
local _                = require("gettext")

local COVER_SERVER_URL = "https://dwigunakd.pythonanywhere.com/generate"
local _bg_folder       = nil
local DEFAULT_TITLE_FONT_SIZE = 70
local DEFAULT_AUTHOR_FONT_SIZE = 52
local TMP_COVER_PATH = "/tmp/penguincover-cover.png"

local PenguinCover = WidgetContainer:extend{
    name        = "penguincover",
    is_doc_only = false,
}

-- Settings helpers ------------------------------------------------------------

local function getKoreaderDir()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then return DS:getDataDir() end
    return (os.getenv("KOREADER_DIR") or "/mnt/onboard/.adds/koreader")
end

local function getBackgroundsFolder()
    if _bg_folder then return _bg_folder end
    local saved = G_reader_settings:readSetting("penguincover_bg_folder")
    _bg_folder = (saved and saved ~= "") and saved
                 or (getKoreaderDir() .. "/backgrounds")
    return _bg_folder
end

local function setBackgroundsFolder(path)
    _bg_folder = (path and path ~= "") and path or nil
    G_reader_settings:saveSetting("penguincover_bg_folder", _bg_folder or "")
end

local function getServerUrl()
    local saved = G_reader_settings:readSetting("penguincover_server_url")
    if saved and saved ~= "" then COVER_SERVER_URL = saved end
    return COVER_SERVER_URL
end

local function setServerUrl(url)
    COVER_SERVER_URL = url
    G_reader_settings:saveSetting("penguincover_server_url", url)
end

local function isValidServerUrl(url)
    return type(url) == "string" and url:match("^https?://[%w%-%._~:/%?#%[%]@!$&%'%(%)%*%+,;=]+$")
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

-- Image helpers ---------------------------------------------------------------

local IMAGE_EXTS = { jpg=true, jpeg=true, png=true, webp=true, bmp=true }

local function isImage(name)
    local ext = name:match("%.([^%.]+)$")
    return ext and IMAGE_EXTS[ext:lower()]
end

local function listImages(folder)
    local list = {}
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok then return list end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and isImage(entry) then
            list[#list+1] = { name = entry, path = folder .. "/" .. entry }
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
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

-- HTTP multipart POST ---------------------------------------------------------

local function buildMultipart(boundary, fields, file)
    local p = {}
    for _, f in ipairs(fields) do
        p[#p+1] = "--" .. boundary .. "\r\n"
            .. "Content-Disposition: form-data; name=\"" .. f.name .. "\"\r\n\r\n"
            .. f.value .. "\r\n"
    end
    if file then
        p[#p+1] = "--" .. boundary .. "\r\n"
            .. "Content-Disposition: form-data; name=\"" .. file.name
            .. "\"; filename=\"" .. file.filename .. "\"\r\n"
            .. "Content-Type: " .. file.content_type .. "\r\n\r\n"
        p[#p+1] = file.data
        p[#p+1] = "\r\n"
    end
    p[#p+1] = "--" .. boundary .. "--\r\n"
    return table.concat(p)
end

local function httpPost(url, body, content_type)
    local ok1, http  = pcall(require, "socket.http")
    local ok2, ltn12 = pcall(require, "ltn12")
    if not (ok1 and ok2) then return nil, "LuaSocket not available" end
    local chunks = {}
    http.TIMEOUT = 30
    local _, code = http.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Content-Type"]   = content_type,
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(chunks),
    }
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code) .. ": " .. table.concat(chunks)
    end
    return table.concat(chunks), nil
end

local function getFontSizeField(name, value)
    if not value then
        return nil
    end
    return { name = name, value = tostring(value) }
end

-- Core: generate and apply cover ----------------------------------------------

local function generateAndApplyCover(file_path, title, author, bg_path)
    local f = io.open(bg_path, "rb")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot open background image:\n%1"), bg_path), timeout = 4 })
        return
    end
    local bg_data = f:read("*a")
    f:close()

    if #bg_data == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Background image is empty."), timeout = 3 })
        return
    end

    local ext  = (bg_path:match("%.([^%.]+)$") or "jpg"):lower()
    local mime = (ext == "png")  and "image/png"
              or (ext == "webp") and "image/webp"
              or "image/jpeg"

    local spinner = InfoMessage:new{
        text = _("Generating Classics cover..."), timeout = 0 }
    UIManager:show(spinner)
    UIManager:forceRePaint()

    local fields = {
        { name = "title", value = title },
        { name = "author", value = author },
    }
    local title_font_size = getTitleFontSize()
    local author_font_size = getAuthorFontSize()
    local title_field = getFontSizeField("title_font_size", title_font_size)
    local author_field = getFontSizeField("author_font_size", author_font_size)
    if title_field then
        fields[#fields + 1] = title_field
    end
    if author_field then
        fields[#fields + 1] = author_field
    end

    local boundary = "PenguinBoundary" .. tostring(os.time()) .. tostring(math.random(1000, 9999))
    local body     = buildMultipart(boundary, fields,
        { name="image", filename=ffiutil.basename(bg_path),
          content_type=mime, data=bg_data })
    local ct = "multipart/form-data; boundary=" .. boundary

    local response, err = httpPost(getServerUrl(), body, ct)
    UIManager:close(spinner)

    if err or not response or #response < 100 then
        UIManager:show(InfoMessage:new{
            text = T(_("Cover generation failed:\n%1"), err or "Empty response"),
            timeout = 5 })
        return
    end

    local out = io.open(TMP_COVER_PATH, "wb")
    if not out then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot save temporary cover:\n%1"), TMP_COVER_PATH), timeout = 4 })
        return
    end
    out:write(response)
    out:close()

    local DocSettings = require("docsettings")
    local ds = DocSettings:open(file_path)
    if not ds:flushCustomCover(file_path, TMP_COVER_PATH) then
        os.remove(TMP_COVER_PATH)
        UIManager:show(InfoMessage:new{
            text = _("Cover was generated, but KOReader could not store it as a custom cover."),
            timeout = 5 })
        return
    end
    ds:getCustomCoverFile(true)
    os.remove(TMP_COVER_PATH)

    invalidateThumbnail(file_path)
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file_path))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))

    UIManager:show(InfoMessage:new{
        text = _("Classics cover applied!"), timeout = 3 })

    local FM = require("apps/filemanager/filemanager")
    if FM.instance then FM.instance:onRefresh() end
end

-- UI Step 2: confirm title / author -------------------------------------------

local function showEditDialog(file_path, title, author, bg_path)
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
                    local t = (fields[1] or title):match("^%s*(.-)%s*$")
                    local a = (fields[2] or author):match("^%s*(.-)%s*$")
                    UIManager:close(dlg)
                    NetworkMgr:runWhenOnline(function()
                        generateAndApplyCover(file_path, t, a, bg_path)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- UI Step 1: background image picker ------------------------------------------

local function showBackgroundPicker(file_path, title, author)
    local folder = getBackgroundsFolder()

    if lfs.attributes(folder, "mode") ~= "directory" then
        lfs.mkdir(folder)
        UIManager:show(InfoMessage:new{
            text = T(_(
                "Backgrounds folder created:\n%1\n\n"
                .. "Add JPG/PNG images there, then try again.\n"
                .. "Change folder: Tools > Classics Cover Generator"
            ), folder),
            timeout = 6 })
        return
    end

    local images = listImages(folder)
    if #images == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_(
                "No images found in:\n%1\n\n"
                .. "Add JPG or PNG files there.\n"
                .. "Change folder: Tools > Classics Cover Generator"
            ), folder),
            timeout = 5 })
        return
    end

    local picker = PathChooser:new{
        title = _("Select Background Image"),
        path = folder,
        select_directory = false,
        select_file = true,
        show_files = true,
        detailed_file_info = false,
        file_filter = function(filename)
            return isImage(filename)
        end,
        onConfirm = function(bg_path)
            showEditDialog(file_path, title, author, bg_path)
        end,
    }
    UIManager:show(picker)
end

-- Entry point -----------------------------------------------------------------

local function onGenerateCover(file_path)
    local title, author = getBookMeta(file_path)
    showBackgroundPicker(file_path, title, author)
end

-- Plugin lifecycle ------------------------------------------------------------

function PenguinCover:init()
    getServerUrl()
    getBackgroundsFolder()
    getTitleFontSize()
    getAuthorFontSize()
    if not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
    self:_registerFileDialogButton()
end

function PenguinCover:onTeardown()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.removeFileDialogButtons then
        FileManager:removeFileDialogButtons("penguin_cover")
        FileManager._penguincover_button_registered = nil
    end
end

function PenguinCover:_registerFileDialogButton()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or FileManager._penguincover_button_registered then
        return
    end
    FileManager._penguincover_button_registered = true

    local DocumentRegistry = require("document/documentregistry")
    FileManager:addFileDialogButtons("penguin_cover", function(file, is_file)
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
                onGenerateCover(file)
            end,
        }}
    end)
end

-- Tools menu ------------------------------------------------------------------

function PenguinCover:addToMainMenu(menu_items)
    menu_items.penguin_cover = {
        text           = _("Classics Cover Generator"),
        sorting_hint   = "tools",
        sub_item_table = {

            -- Set backgrounds folder
            {
                text           = _("Set backgrounds folder"),
                keep_menu_open = true,
                callback       = function()
                    local inp
                    inp = InputDialog:new{
                        title       = _("Backgrounds folder"),
                        input       = getBackgroundsFolder(),
                        input_hint  = _("/path/to/your/backgrounds"),
                        description = _(
                            "Folder with JPG/PNG background images.\n"
                            .. "Empty = reset to default (<koreader>/backgrounds/)."
                        ),
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(inp) end,
                            },
                            {
                                text     = _("Reset default"),
                                callback = function()
                                    setBackgroundsFolder("")
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = T(_("Reset. Default:\n%1"),
                                                    getKoreaderDir() .. "/backgrounds"),
                                        timeout = 3 })
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local path = inp:getInputText():match("^%s*(.-)%s*$")
                                    if path == "" then
                                        setBackgroundsFolder("")
                                        UIManager:close(inp)
                                        return
                                    end
                                    if lfs.attributes(path, "mode") ~= "directory" then
                                        if not lfs.mkdir(path) then
                                            UIManager:show(InfoMessage:new{
                                                text    = T(_("Cannot create:\n%1"), path),
                                                timeout = 4 })
                                            return
                                        end
                                    end
                                    setBackgroundsFolder(path)
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = T(_("Folder set to:\n%1"), path),
                                        timeout = 3 })
                                end,
                            },
                        }},
                    }
                    UIManager:show(inp)
                    inp:onShowKeyboard()
                end,
            },

            -- Title font size
            {
                text           = _("Set title font size"),
                keep_menu_open = true,
                callback       = function()
                    local inp
                    inp = InputDialog:new{
                        title       = _("Title font size"),
                        input       = tostring(getTitleFontSize() or ""),
                        input_hint  = _("Leave empty for default"),
                        description = T(_(
                            "Optional size for the book title text.\n"
                            .. "Default size: %1.\n"
                            .. "Empty = use the server default layout."
                        ), DEFAULT_TITLE_FONT_SIZE),
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(inp) end,
                            },
                            {
                                text     = _("Reset default"),
                                callback = function()
                                    setTitleFontSize(nil)
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = _("Title font size reset to server default."),
                                        timeout = 3 })
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local raw = inp:getInputText():match("^%s*(.-)%s*$")
                                    if raw == "" then
                                        setTitleFontSize(nil)
                                        UIManager:close(inp)
                                        return
                                    end

                                    local size = tonumber(raw)
                                    if not size or size <= 0 then
                                        UIManager:show(InfoMessage:new{
                                            text    = _("Enter a positive number for the title font size."),
                                            timeout = 4 })
                                        return
                                    end

                                    size = math.floor(size)
                                    setTitleFontSize(size)
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = T(_("Title font size set to %1."), size),
                                        timeout = 3 })
                                end,
                            },
                        }},
                    }
                    UIManager:show(inp)
                    inp:onShowKeyboard()
                end,
            },

            -- Author font size
            {
                text           = _("Set author font size"),
                keep_menu_open = true,
                callback       = function()
                    local inp
                    inp = InputDialog:new{
                        title       = _("Author font size"),
                        input       = tostring(getAuthorFontSize() or ""),
                        input_hint  = _("Leave empty for default"),
                        description = T(_(
                            "Optional size for the author text.\n"
                            .. "Default size: %1.\n"
                            .. "Empty = use the server default layout."
                        ), DEFAULT_AUTHOR_FONT_SIZE),
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(inp) end,
                            },
                            {
                                text     = _("Reset default"),
                                callback = function()
                                    setAuthorFontSize(nil)
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = _("Author font size reset to server default."),
                                        timeout = 3 })
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local raw = inp:getInputText():match("^%s*(.-)%s*$")
                                    if raw == "" then
                                        setAuthorFontSize(nil)
                                        UIManager:close(inp)
                                        return
                                    end

                                    local size = tonumber(raw)
                                    if not size or size <= 0 then
                                        UIManager:show(InfoMessage:new{
                                            text    = _("Enter a positive number for the author font size."),
                                            timeout = 4 })
                                        return
                                    end

                                    size = math.floor(size)
                                    setAuthorFontSize(size)
                                    UIManager:close(inp)
                                    UIManager:show(InfoMessage:new{
                                        text    = T(_("Author font size set to %1."), size),
                                        timeout = 3 })
                                end,
                            },
                        }},
                    }
                    UIManager:show(inp)
                    inp:onShowKeyboard()
                end,
            },

            -- Change server URL
            {
                text           = _("Change server URL"),
                keep_menu_open = true,
                callback       = function()
                    local inp
                    inp = InputDialog:new{
                        title      = _("Cover server URL"),
                        input      = getServerUrl(),
                        input_hint = "https://example.com/generate",
                        buttons    = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(inp) end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local url = inp:getInputText():match("^%s*(.-)%s*$")
                                    if url ~= "" then
                                        if not isValidServerUrl(url) then
                                            UIManager:show(InfoMessage:new{
                                                text    = _("Enter a valid http:// or https:// server URL."),
                                                timeout = 4 })
                                            return
                                        end
                                        setServerUrl(url)
                                        UIManager:show(InfoMessage:new{
                                            text    = T(_("URL saved:\n%1"), url),
                                            timeout = 3 })
                                    end
                                    UIManager:close(inp)
                                end,
                            },
                        }},
                    }
                    UIManager:show(inp)
                    inp:onShowKeyboard()
                end,
            },

            -- About
            {
                text     = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_(
                            "Classics Cover Generator\n\n"
                            .. "Hold a book > Classics Cover\n"
                            .. "Pick a background image, confirm\n"
                            .. "title/author, cover is applied.\n\n"
                            .. "Backgrounds folder:\n%1\n\n"
                            .. "Server:\n%2"
                        ), getBackgroundsFolder(), getServerUrl()),
                    })
                end,
            },
        },
    }
end

return PenguinCover
