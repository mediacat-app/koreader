local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local _ = require("gettext")

local Screen = Device.screen
local T = ffiUtil.template

local function logMediaCatError(context, err)
    local message = tostring(err)
    local trace = debug and debug.traceback and debug.traceback(message, 2) or message
    logger.err("MediaCat " .. context .. " failed:\n" .. trace)
    return message
end

local CoverTile = InputContainer:extend{}

function CoverTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    local border = Size.border.thin
    local padding = Screen:scaleBySize(4)
    local inner_width = self.width - 2 * (border + padding)
    local inner_height = self.height - 2 * (border + padding)
    local title_height = math.min(Screen:scaleBySize(58), math.floor(inner_height / 2))
    local cover_height = inner_height - title_height
    local cover_widget

    if self.cover then
        cover_widget = ImageWidget:new{
            image = self.cover,
            image_disposable = false,
            width = inner_width,
            height = cover_height,
            scale_factor = 0,
        }
    else
        cover_widget = CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = cover_height },
            TextWidget:new{
                text = _("No cover"),
                face = Font:getFace("smallinfofont", 18),
            },
        }
    end

    local title = self.item.title or self.item.text or _("Untitled")
    if self.item.author and self.item.author ~= "" then
        title = title .. "\n" .. self.item.author
    end

    self[1] = FrameContainer:new{
        bordersize = border,
        padding = padding,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = inner_width, h = cover_height },
                cover_widget,
            },
            TextBoxWidget:new{
                text = title,
                face = Font:getFace("smallinfofont", 16),
                alignment = "center",
                width = inner_width,
                height = title_height,
                height_overflow_show_ellipsis = true,
            },
        },
    }
    self.ges_events = {
        TapSelect = {
            require("ui/gesturerange"):new{ ges = "tap", range = self.dimen },
        },
    }
end

function CoverTile:onTapSelect()
    self.on_select(self.item)
    return true
end

local CoverGrid = InputContainer:extend{
    covers_fullscreen = true,
    key_events = {
        Back = { { Device.input.group.Back } },
        PagePrevious = { { Device.input.group.PgBack } },
        PageNext = { { Device.input.group.PgFwd } },
    },
}

function CoverGrid:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local header_h = Screen:scaleBySize(62)
    local footer_h = Screen:scaleBySize(58)
    local body_h = screen_h - header_h - footer_h
    self.columns = math.max(2, math.min(4, math.floor(screen_w / Screen:scaleBySize(170))))
    self.rows = math.max(1, math.min(4, math.floor(body_h / Screen:scaleBySize(205))))
    self.tile_width = math.floor(screen_w / self.columns)
    self.tile_height = math.floor(body_h / self.rows)
    self.per_page = self.columns * self.rows
    self.page = math.max(1, math.min(self.page or 1, math.ceil(#self.items / self.per_page)))
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    local total_pages = math.max(1, math.ceil(#self.items / self.per_page))
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.items, first + self.per_page - 1)
    local button_w = Screen:scaleBySize(82)
    local title_w = screen_w - 2 * button_w
    local header = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = header_h },
        HorizontalGroup:new{
            Button:new{
                text = _("Back"),
                width = button_w,
                show_parent = self,
                callback = self.on_back,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = title_w, h = header_h },
                TextBoxWidget:new{
                    text = self.title or _("OPDS books"),
                    face = Font:getFace("infofont", 20),
                    alignment = "center",
                    width = title_w,
                    height = header_h,
                    height_overflow_show_ellipsis = true,
                },
            },
            Button:new{
                text = _("Menu"),
                width = button_w,
                show_parent = self,
                callback = self.on_menu,
            },
        },
    }

    local body = VerticalGroup:new{}
    for row = 1, self.rows do
        local row_items = HorizontalGroup:new{}
        for col = 1, self.columns do
            local index = first + (row - 1) * self.columns + col - 1
            if index <= last then
                local item = self.items[index]
                table.insert(row_items, CoverTile:new{
                    item = item,
                    cover = self.load_cover(item, self.tile_width, self.tile_height),
                    width = self.tile_width,
                    height = self.tile_height,
                    on_select = self.on_select,
                })
            else
                table.insert(row_items, WidgetContainer:new{
                    dimen = Geom:new{ w = self.tile_width, h = self.tile_height },
                })
            end
        end
        table.insert(body, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = self.tile_height },
            row_items,
        })
    end
    local unused_body_height = body_h - self.rows * self.tile_height
    if unused_body_height > 0 then
        table.insert(body, VerticalSpan:new{ width = unused_body_height })
    end

    local has_more = self.has_more
    local footer_text
    if #self.items == 0 then
        footer_text = _("No books in this catalog")
    else
        footer_text = T(_("%1–%2 of %3 books"), first, last, #self.items)
    end
    if has_more and self.page == total_pages then
        footer_text = footer_text .. "  ·  " .. _("More available")
    end
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = footer_h },
        HorizontalGroup:new{
            Button:new{
                text = _("Previous"),
                width = Screen:scaleBySize(112),
                enabled = self.page > 1,
                show_parent = self,
                callback = function() self.on_page(self.page - 1) end,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(12) },
            TextWidget:new{
                text = footer_text,
                face = Font:getFace("smallinfofont", 16),
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(12) },
            Button:new{
                text = has_more and self.page == total_pages and _("More") or _("Next"),
                width = Screen:scaleBySize(112),
                enabled = self.page < total_pages or has_more,
                show_parent = self,
                callback = function()
                    if self.page < total_pages then
                        self.on_page(self.page + 1)
                    else
                        self.on_load_more(self.page)
                    end
                end,
            },
        },
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ header, body, footer },
    }
end

function CoverGrid:onBack()
    self.on_back()
    return true
end

function CoverGrid:onPagePrevious()
    if self.page > 1 then
        self.on_page(self.page - 1)
    end
    return true
end

function CoverGrid:onPageNext()
    local total_pages = math.max(1, math.ceil(#self.items / self.per_page))
    if self.page < total_pages then
        self.on_page(self.page + 1)
    elseif self.has_more then
        self.on_load_more(self.page)
    end
    return true
end

local OPDSHome = WidgetContainer:extend{
    name = "opds_home",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/opds_home.lua",
}

function OPDSHome:init()
    -- KOReader instantiates non-document plugins in the reader as well. MediaCat
    -- should only take over when the FileManager home browser is opened.
    if not self.ui or not self.ui.file_chooser or not self.ui.registerPostInitCallback then
        return
    end

    self.settings = LuaSettings:open(self.settings_file)
    self.saved_connection = self.settings:readSetting("connection", {})
    self.login_values = self.saved_connection
    self.history = {}
    self.cover_cache = {}
    self.ui:registerPostInitCallback(function()
        UIManager:nextTick(function()
            if self.saved_connection and self.saved_connection.url then
                NetworkMgr:runWhenConnected(function()
                    self:connectToCatalog(self.saved_connection.url, _("OPDS catalog"), self.saved_connection,
                        _("Could not reconnect to the OPDS catalog. Check the URL and login."))
                end)
            else
                self:showLogin()
            end
        end)
    end)
end

function OPDSHome:showConnecting()
    local message = InfoMessage:new{ text = _("Connecting to OPDS catalog…") }
    UIManager:show(message)
    UIManager:forceRePaint()
    return message
end

function OPDSHome:connectToCatalog(feed_url, title, connection, fallback_error)
    self.connection = connection or self.connection
    logger.info("MediaCat: connection attempt started")
    local connecting
    local ok, connected = xpcall(function()
        connecting = self:showConnecting()
        return self:openCatalog(feed_url, title, false)
    end, function(err)
        return logMediaCatError("connection flow", err)
    end)

    if connecting then
        local closed, close_error = pcall(UIManager.close, UIManager, connecting)
        if not closed then
            logMediaCatError("closing connection message", close_error)
        end
    end
    if not ok then
        self.last_catalog_error = connected
        connected = false
    end
    logger.info("MediaCat: connection attempt finished (connected=" .. tostring(connected) .. ")")

    if not connected then
        logger.warn("MediaCat: connection failed:", self.last_catalog_error or fallback_error or "unknown error")
        local shown, show_error = xpcall(function()
            self:showLogin()
            UIManager:show(InfoMessage:new{
                text = self.last_catalog_error or fallback_error
                    or _("Could not read an OPDS feed. Check the URL, login, server response, and feed format."),
            })
        end, function(err)
            return logMediaCatError("showing login error", err)
        end)
        if not shown then
            self.last_catalog_error = show_error
        end
    end
    return connected
end

function OPDSHome:closeCurrentScreen()
    if self.current_screen then
        UIManager:close(self.current_screen)
        self.current_screen = nil
    end
end

function OPDSHome:getOPDSBrowserClass()
    if self.OPDSBrowserClass then
        return self.OPDSBrowserClass
    end

    -- Prefer KOReader's bundled OPDS modules and load the browser file directly;
    -- another plugin may have already cached its own `opdsbrowser` module.
    local source_path = debug.getinfo(1, "S").source:match("^@(.+)$")
    local plugins_dir = source_path and source_path:match("^(.*)/[^/]+/[^/]+$")
    local opds_plugin_path
    local opds_browser_file
    if plugins_dir then
        opds_plugin_path = plugins_dir .. "/opds.koplugin/?.lua"
        opds_browser_file = plugins_dir .. "/opds.koplugin/opdsbrowser.lua"
        local other_paths = {}
        for path in package.path:gmatch("[^;]+") do
            if path ~= opds_plugin_path then
                table.insert(other_paths, path)
            end
        end
        package.path = opds_plugin_path .. ";" .. table.concat(other_paths, ";")
    end

    local ok, class
    if opds_browser_file then
        local loader, load_error = loadfile(opds_browser_file)
        if loader then
            ok, class = pcall(loader)
        else
            ok, class = false, load_error
        end
    else
        ok, class = pcall(require, "opdsbrowser")
    end
    if ok and type(class) == "table" and type(class.parseFeed) == "function"
            and type(class.fetchFeed) == "function" then
        logger.info("MediaCat: using KOReader OPDS browser module", opds_plugin_path or "from package.path")
        self.OPDSBrowserClass = class
        return class
    end
    if ok then
        local init_info = type(class) == "table" and type(class.init) == "function"
            and debug.getinfo(class.init, "S")
        local source = init_info and init_info.source or "unknown source"
        logger.err("MediaCat: loaded OPDS browser module has no compatible feed API; source:", source)
    else
        logger.err("MediaCat: could not load OPDS browser module:", class)
    end
    UIManager:show(InfoMessage:new{
        text = _("MediaCat could not load a compatible KOReader OPDS browser module."),
    })
end

function OPDSHome:newOPDSBrowser()
    if self.opds_browser then
        self.opds_browser.root_catalog_username = self.connection.username
        self.opds_browser.root_catalog_password = self.connection.password
        return self.opds_browser
    end
    local class = self:getOPDSBrowserClass()
    if not class then
        return
    end
    local helper = class:extend{
        root_catalog_title = _("OPDS catalog"),
        root_catalog_username = self.connection.username,
        root_catalog_password = self.connection.password,
        root_catalog_raw_names = false,
        catalog_title = nil,
        downloads = {},
        _manager = { ui = self.ui, updated = false },
        file_downloaded_callback = function(file) self:offerToOpen(file) end,
        file_read_now_callback = function(file) self:openDownloadedFile(file) end,
    }
    self.opds_browser = helper
    return helper
end

function OPDSHome:getSavedCatalogs()
    local catalogs = {}
    local seen = {}
    local function addCatalog(catalog)
        if not catalog or not catalog.url then
            return
        end
        local url = self:normalizeURL(catalog.url)
        if not url then
            return
        end
        local key = url .. "\0" .. (catalog.username or "")
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(catalogs, {
            title = catalog.title or url,
            url = url,
            username = catalog.username,
            password = catalog.password,
        })
    end

    addCatalog(self.saved_connection)
    -- Also reuse catalog profiles already configured in KOReader's OPDS browsers.
    for _, filename in ipairs({ "opdsplus.lua", "opds.lua" }) do
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. filename)
        for _, catalog in ipairs(settings:readSetting("servers", {})) do
            addCatalog(catalog)
        end
    end
    return catalogs
end

function OPDSHome:showSavedCatalogs()
    local catalogs = self:getSavedCatalogs()
    if #catalogs == 0 then
        UIManager:show(InfoMessage:new{ text = _("No saved OPDS catalogs were found.") })
        self:showLogin()
        return
    end

    local items = {}
    for _, catalog in ipairs(catalogs) do
        table.insert(items, { text = catalog.title, connection = catalog })
    end
    local menu
    menu = Menu:new{
        title = _("Saved OPDS catalogs"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            UIManager:close(menu_self)
            self.current_screen = nil
            self.login_values = item.connection
            self:showLogin()
            return true
        end,
        onReturn = function()
            UIManager:close(menu)
            self.current_screen = nil
            self:showLogin()
        end,
        close_callback = function()
            if self.current_screen == menu then
                self.current_screen = nil
            end
        end,
    }
    self.current_screen = menu
    UIManager:show(menu)
end

function OPDSHome:showLogin()
    self:closeCurrentScreen()
    local values = self.login_values or self.saved_connection or {}
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MediaCat — Login"),
        fields = {
            { hint = _("OPDS URL"), text = values.url or "" },
            { hint = _("Username"), text = values.username or "" },
            { hint = _("Password"), text = values.password or "", text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Saved catalogs"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.current_screen == dialog then
                            self.current_screen = nil
                        end
                        self:showSavedCatalogs()
                    end,
                },
            },
            {
                {
                    text = _("Local files"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if self.current_screen == dialog then
                            self.current_screen = nil
                        end
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local ok, err = xpcall(function()
                            logger.info("MediaCat: login submitted")
                            local fields = dialog:getFields()
                            local feed_url, validation_error = self:normalizeURL(fields[1])
                            if not feed_url then
                                UIManager:show(InfoMessage:new{ text = validation_error })
                                return
                            end
                            local connection = {
                                url = feed_url,
                                username = fields[2] ~= "" and fields[2] or nil,
                                password = fields[3] ~= "" and fields[3] or nil,
                            }
                            self.login_values = connection
                            -- Retain the entered login across restarts, including
                            -- when the server is temporarily unreachable.
                            self.settings:saveSetting("connection", connection)
                            self.settings:flush()
                            self.saved_connection = connection
                            UIManager:close(dialog)
                            if self.current_screen == dialog then
                                self.current_screen = nil
                            end
                            NetworkMgr:runWhenConnected(function()
                                self.opds_browser = nil
                                self.current_state = nil
                                self.history = {}
                                self:connectToCatalog(feed_url, _("OPDS catalog"), connection)
                            end)
                        end, function(callback_error)
                            return logMediaCatError("login callback", callback_error)
                        end)
                        if not ok then
                            self.last_catalog_error = err
                            UIManager:show(InfoMessage:new{
                                text = T(_("MediaCat login failed: %1"), err),
                            })
                        end
                    end,
                },
            },
        },
    }
    self.current_screen = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OPDSHome:normalizeURL(value)
    value = (value or ""):match("^%s*(.-)%s*$")
    if value == "" then
        return nil, _("Enter an OPDS URL.")
    end
    if not value:match("^%a[%w+%.%-]*://") then
        value = "https://" .. value
    end
    local parsed = socket_url.parse(value)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") or not parsed.host then
        return nil, _("Enter a valid HTTP or HTTPS OPDS URL.")
    end
    return value
end

function OPDSHome:parseAtomFallback(helper, feed_url)
    local original_accept = helper.opds20_feed
    helper.opds20_feed = "application/atom+xml;profile=opds-catalog, application/atom+xml, */*;q=0.1"
    local ok, feed = xpcall(function()
        return helper:fetchFeed(feed_url)
    end, function(err)
        return logMediaCatError("Atom fallback fetch", err)
    end)
    helper.opds20_feed = original_accept
    if not ok or not feed then
        return nil
    end
    if feed:match("^%s*{") then
        local ok_json, catalog = pcall(require("json").decode, feed)
        if ok_json then
            catalog.is_opds2 = true
            return catalog
        end
        return nil
    end
    return require("opdsparser"):parse(feed)
end

function OPDSHome:readFeed(feed_url, fallback_title)
    self.last_catalog_error = nil
    local helper = self:newOPDSBrowser()
    if not helper then
        self.last_catalog_error = _("KOReader's built-in OPDS plugin is unavailable.")
        return nil
    end
    helper.catalog_title = fallback_title
    logger.info("MediaCat: fetching catalog feed")
    local ok, catalog = xpcall(function()
        return helper:parseFeed(feed_url)
    end, function(err)
        return logMediaCatError("feed fetch and parse", err)
    end)
    local function makeItems(parsed_catalog)
        if not parsed_catalog then
            return nil
        end
        local ok_items, items = xpcall(function()
            if parsed_catalog.is_opds2 then
                return helper:genItemTableFromCatalog2(parsed_catalog, feed_url)
            end
            return helper:genItemTableFromCatalog(parsed_catalog, feed_url)
        end, function(err)
            return logMediaCatError("feed normalization", err)
        end)
        if ok_items then
            return items
        end
        return nil, tostring(items)
    end

    local initial_error = not ok and tostring(catalog) or nil
    local items, item_error
    if ok then
        items, item_error = makeItems(catalog)
    end
    if items then
        logger.info("MediaCat: catalog parsed (items=" .. tostring(#items) .. ")")
        return items, helper.catalog_title or fallback_title
    end

    -- Some servers expose both formats at one URL but return an OPDS 2.0
    -- representation that this KOReader version cannot normalize. Retry only
    -- after a successful HTTP response; don't mask network/authentication errors.
    if not helper.last_fetch_error and (not ok or not catalog
            or (type(catalog) == "table" and catalog.is_opds2)) then
        local fallback_ok, fallback_catalog = xpcall(function()
            return self:parseAtomFallback(helper, feed_url)
        end, function(err)
            return logMediaCatError("Atom fallback", err)
        end)
        if fallback_ok and fallback_catalog then
            helper.catalog_title = fallback_catalog.metadata and fallback_catalog.metadata.title or fallback_title
            local fallback_items, fallback_error = makeItems(fallback_catalog)
            if fallback_items then
                return fallback_items, helper.catalog_title or fallback_title
            end
            item_error = fallback_error
        elseif not fallback_ok then
            item_error = tostring(fallback_catalog)
        end
    end

    self.last_catalog_error = helper.last_fetch_error or item_error or initial_error
        or _("The server did not return a parseable Atom or OPDS 2.0 feed.")
    return nil
end

function OPDSHome:openCatalog(feed_url, title, push_history)
    local ok, result = xpcall(function()
        local parent = self.current_state
        if push_history and parent then
            table.insert(self.history, parent)
        end
        self:closeCurrentScreen()
        local items, feed_title = self:readFeed(feed_url, title)
        if not items then
            if push_history and parent then
                table.remove(self.history)
                self.current_state = parent
                self:renderState(parent)
                UIManager:show(InfoMessage:new{ text = _("Could not open that catalog.") })
            end
            return false
        end

        self.current_state = {
            url = feed_url,
            title = feed_title or title or _("OPDS catalog"),
            items = items,
            hrefs = items.hrefs,
        }
        logger.info("MediaCat: rendering catalog screen")
        self:renderState(self.current_state)
        return true
    end, function(err)
        return logMediaCatError("opening or rendering catalog", err)
    end)
    if not ok then
        self.last_catalog_error = result
        return false
    end
    return result
end

function OPDSHome:isLeaf(state)
    if #state.items == 0 then
        return false
    end
    for _, item in ipairs(state.items) do
        if item.url then
            return false
        end
    end
    return true
end

function OPDSHome:renderState(state)
    if self:isLeaf(state) then
        self:showGrid(state, 1)
    else
        self:showCatalogMenu(state)
    end
end

function OPDSHome:showCatalogMenu(state)
    local items = {}
    for _, item in ipairs(state.items) do
        table.insert(items, item)
    end
    if state.hrefs and state.hrefs.next then
        table.insert(items, {
            text = _("Load next catalog page…"),
            is_next_catalog_page = true,
        })
    end

    local menu
    menu = Menu:new{
        title = state.title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:showOptions(menu) end,
        onMenuSelect = function(_menu_self, item)
            if item.is_next_catalog_page then
                self:loadMore(state, function() self:renderState(state) end)
            elseif item.url then
                self:openCatalog(item.url, item.text, true)
            elseif item.acquisitions and #item.acquisitions > 0 then
                self:showDownloads(item)
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("No downloadable book format was found for %1."), item.text or ""),
                })
            end
            return true
        end,
        onReturn = function()
            self:goBack()
        end,
        close_callback = function()
            if self.current_screen == menu then
                self.current_screen = nil
            end
        end,
    }
    if #self.history > 0 then
        menu.paths = { true }
        menu:updateItems(1, true)
    end
    self.current_screen = menu
    UIManager:show(menu)
end

function OPDSHome:showDownloads(item)
    if not self.opds_browser then
        return
    end
    self.opds_browser:showDownloads(item)
end

function OPDSHome:loadMore(state, on_done)
    local next_url = state.hrefs and state.hrefs.next
    if not next_url then
        return
    end
    local previous_screen = self.current_screen
    local loading = InfoMessage:new{ text = _("Loading catalog page…") }
    UIManager:show(loading)
    UIManager:forceRePaint()
    local items = self:readFeed(next_url, state.title)
    UIManager:close(loading)
    if items then
        for _, item in ipairs(items) do
            table.insert(state.items, item)
        end
        state.hrefs = items.hrefs
        if state == self.current_state then
            self.current_state = state
        end
        if previous_screen then
            UIManager:close(previous_screen)
            if self.current_screen == previous_screen then
                self.current_screen = nil
            end
        end
        on_done()
    end
end

function OPDSHome:goBack()
    self:closeCurrentScreen()
    local previous = table.remove(self.history)
    if previous then
        self.current_state = previous
        self:renderState(previous)
    else
        self.current_state = nil
        self:showLogin()
    end
end

function OPDSHome:showGrid(state, page)
    self:closeCurrentScreen()
    local loading = self:showConnectingCovers()
    local grid = CoverGrid:new{
        title = state.title,
        items = state.items,
        page = page,
        has_more = state.hrefs and state.hrefs.next,
        load_cover = function(item, width, height) return self:loadCover(item, width, height) end,
        on_select = function(item) self:showDownloads(item) end,
        on_back = function() self:goBack() end,
        on_menu = function() self:showOptions(grid) end,
        on_page = function(next_page) self:showGrid(state, next_page) end,
        on_load_more = function(current_page)
            self:loadMore(state, function()
                self:showGrid(state, current_page + 1)
            end)
        end,
    }
    UIManager:close(loading)
    self.current_screen = grid
    UIManager:show(grid, "ui")
    UIManager:forceRePaint()
end

function OPDSHome:showConnectingCovers()
    local message = InfoMessage:new{ text = _("Loading book covers…") }
    UIManager:show(message)
    UIManager:forceRePaint()
    return message
end

function OPDSHome:loadCover(item, width, height)
    local image_url = item.thumbnail or item.image
    if not image_url or not self.opds_browser then
        return
    end
    if self.cover_cache[image_url] ~= nil then
        return self.cover_cache[image_url] or nil
    end

    local data
    if self.opds_browser.getHttpClient then
        local chunks = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return self.opds_browser:getHttpClient():request{
                url = image_url,
                method = "GET",
                headers = { ["Accept-Encoding"] = "identity" },
                sink = ltn12.sink.table(chunks),
                username = self.connection.username,
                password = self.connection.password,
            }
        end)
        socketutil:reset_timeout()
        if ok and code == 200 then
            data = table.concat(chunks)
        end
    elseif self.opds_browser.fetchFeed then
        -- KOReader 2026.07.1's built-in OPDS browser exposes fetchFeed but
        -- predates getHttpClient. Keep cover loading compatible with both APIs.
        local ok, body = pcall(self.opds_browser.fetchFeed, self.opds_browser, image_url)
        if ok then
            data = body
        end
    end
    if data then
        local image = RenderImage:renderImageData(data, #data, false, width, height)
        self.cover_cache[image_url] = image or false
        return image
    end
    self.cover_cache[image_url] = false
end

function OPDSHome:showOptions(anchor_menu)
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                text = _("Edit OPDS login"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.login_values = self.connection or self.saved_connection
                    self:showLogin()
                end,
            }},
            {{
                text = _("Return to local files"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:closeCurrentScreen()
                    self.current_state = nil
                    self.history = {}
                end,
            }},
        },
        shrink_unneeded_width = true,
    }
    if anchor_menu and anchor_menu.title_bar and anchor_menu.title_bar.left_button then
        dialog.anchor = function()
            return anchor_menu.title_bar.left_button.image.dimen
        end
    end
    UIManager:show(dialog)
end

function OPDSHome:offerToOpen(file)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\n\nRead it now?"), file),
        ok_text = _("Read now"),
        ok_callback = function() self:openDownloadedFile(file) end,
    })
end

function OPDSHome:openDownloadedFile(file)
    self:closeCurrentScreen()
    self.current_state = nil
    self.history = {}
    if self.ui.document then
        self.ui:switchDocument(file)
    else
        self.ui:openFile(file)
    end
end

function OPDSHome:onSetDimensions()
    if self.current_state and self.current_screen
            and getmetatable(self.current_screen) == CoverGrid then
        UIManager:nextTick(function()
            self:showGrid(self.current_state, 1)
        end)
    end
end

return OPDSHome
