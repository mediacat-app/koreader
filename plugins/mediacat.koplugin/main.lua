local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
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
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local mime = require("mime")
local buffer = require("string.buffer")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local time = require("ui/time")
local Trapper = require("ui/trapper")
local _ = require("gettext")

local Screen = Device.screen
local T = ffiUtil.template

local function perfNow()
    return time.monotonic()
end

local function perfElapsedMs(start_time)
    return time.to_s(time.monotonic() - start_time) * 1000
end

local function perfEndpoint(raw_url)
    if not raw_url then
        return "<nil>"
    end
    local parsed = socket_url.parse(raw_url)
    if not parsed or not parsed.host then
        return "<invalid-url>"
    end
    local path = (parsed.path or "/"):gsub("([^/]+)", function(component)
        return #component >= 24 and "<redacted>" or component
    end)
    return string.format("%s://%s%s%s", parsed.scheme or "?", parsed.host,
        parsed.port and ":" .. parsed.port or "", path)
end

local function logMediaCatPerf(format, ...)
    logger.info("MediaCat perf: " .. string.format(format, ...))
end

local function countChunkBytes(chunks)
    local bytes = 0
    for _, chunk in ipairs(chunks or {}) do
        bytes = bytes + #chunk
    end
    return bytes
end

local function logMediaCatError(context, err)
    local message = tostring(err)
    local trace = debug and debug.traceback and debug.traceback(message, 2) or message
    logger.err("MediaCat " .. context .. " failed:\n" .. trace)
    return message
end

local function getCoverGridLayout()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local header_h = Screen:scaleBySize(62)
    local footer_h = Screen:scaleBySize(58)
    local body_h = screen_h - header_h - footer_h
    local columns = math.max(2, math.min(4, math.floor(screen_w / Screen:scaleBySize(170))))
    local rows = math.max(1, math.min(4, math.floor(body_h / Screen:scaleBySize(205))))
    local tile_width = math.floor(screen_w / columns)
    local tile_height = math.floor(body_h / rows)
    return screen_w, screen_h, header_h, footer_h, body_h, columns, rows,
        tile_width, tile_height, columns * rows
end

local function fetchCoverBatch(tasks, on_progress, purpose)
    local batch_started = perfNow()
    local ok, async = pcall(require, "httpasync")
    if not ok then
        logMediaCatPerf("cover_parallel purpose=%s outcome=unavailable require_ms=%.3f",
            purpose or "unspecified", perfElapsedMs(batch_started))
        return nil, async
    end
    local headers_by_url = {}
    local task_indices = {}
    for _, task in ipairs(tasks) do
        headers_by_url[task.url] = task.headers
        task_indices[task.url] = task.perf_index
    end
    local downloaded = {}
    local fetched, fetch_error = pcall(async.fetch_many, tasks, {
        concurrency = 8,
        get_url = function(task) return task.url end,
        fetch = function(image_url)
            local request_started = perfNow()
            local success, data, content_type = async.fetch_url(image_url, 0, headers_by_url[image_url])
            local http_status = not success and type(data) == "string" and data:match("HTTP error (%d+)")
                or (success and "not_exposed_by_httpasync" or "transport_error")
            logMediaCatPerf("cover_request purpose=%s mode=parallel index=%s endpoint=%s http_status=%s bytes=%d request_ms=%.3f outcome=%s content_type=%s",
                purpose or "unspecified", tostring(task_indices[image_url] or "?"),
                perfEndpoint(image_url), tostring(http_status), success and type(data) == "string" and #data or 0,
                perfElapsedMs(request_started), success and "ok" or "failed", tostring(content_type or "unknown"))
            return success, data, content_type
        end,
        on_success = function(task, data)
            downloaded[task.url] = data
        end,
        on_failure = function(task, err)
            logger.dbg("MediaCat: cover fetch failed", task.url, err)
            downloaded[task.url] = false
        end,
        on_progress = on_progress,
    })
    if not fetched then
        logMediaCatPerf("cover_parallel purpose=%s outcome=failed request_count=%d total_ms=%.3f",
            purpose or "unspecified", #tasks, perfElapsedMs(batch_started))
        return nil, fetch_error
    end
    logMediaCatPerf("cover_parallel purpose=%s outcome=ok request_count=%d total_ms=%.3f",
        purpose or "unspecified", #tasks, perfElapsedMs(batch_started))
    return downloaded
end

local ConnectingScreen = InputContainer:extend{
    covers_fullscreen = true,
}

function ConnectingScreen:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            TextWidget:new{
                text = _("Connecting to MediaCat…"),
                face = Font:getFace("infofont", 22),
            },
        },
    }
end

function ConnectingScreen:onHome()
    return true
end

local CoverTile = InputContainer:extend{}

function CoverTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    local border = 0
    local padding = Screen:scaleBySize(2)
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

    local cover_area = cover_widget
    if self.downloaded_file then
        local badge_diameter = Screen:scaleBySize(28)
        local badge_border = Screen:scaleBySize(1)
        local badge = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = badge_border,
            color = Blitbuffer.COLOR_BLACK,
            radius = math.floor(badge_diameter / 2),
            padding = 0,
            width = badge_diameter,
            height = badge_diameter,
            CenterContainer:new{
                dimen = Geom:new{
                    w = badge_diameter - 2 * badge_border,
                    h = badge_diameter - 2 * badge_border,
                },
                TextWidget:new{
                    text = "↓",
                    face = Font:getFace("infofont", 18),
                },
            },
        }
        local badge_size = badge:getSize()
        local image_width, image_height = inner_width, cover_height
        if self.cover then
            cover_widget:getSize()
            image_width = cover_widget:getCurrentWidth()
            image_height = cover_widget:getCurrentHeight()
        end
        local image_x = math.floor((inner_width - image_width) / 2)
        local image_y = math.floor((cover_height - image_height) / 2)
        badge.overlap_offset = {
            image_x + image_width - badge_size.w - Screen:scaleBySize(2),
            image_y + image_height - badge_size.h - Screen:scaleBySize(2),
        }
        cover_area = OverlapGroup:new{
            allow_mirroring = false,
            dimen = Geom:new{ w = inner_width, h = cover_height },
            cover_widget,
            badge,
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
                cover_area,
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
    self.on_select(self.item, self.downloaded_file)
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

function CoverGrid:paintTo(bb, x, y)
    local paint_started = self.perf_paint_pending and perfNow() or nil
    InputContainer.paintTo(self, bb, x, y)
    if paint_started then
        self.perf_paint_pending = false
        logMediaCatPerf("grid_widget_paint page=%d paint_ms=%.3f",
            self.page or 1, perfElapsedMs(paint_started))
    end
end

function CoverGrid:init()
    local screen_w, screen_h, header_h, footer_h, body_h, columns, rows,
        tile_width, tile_height, per_page = getCoverGridLayout()
    self.columns = columns
    self.rows = rows
    self.tile_width = tile_width
    self.tile_height = tile_height
    self.per_page = per_page
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
            WidgetContainer:new{ dimen = Geom:new{ w = button_w, h = header_h } },
            CenterContainer:new{
                dimen = Geom:new{ w = title_w, h = header_h },
                TextBoxWidget:new{
                    text = self.title or _("MediaCat"),
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
                local visible_index = index - first + 1
                local cover_started = perfNow()
                local cover = self.load_cover(item)
                local cover_load_ms = perfElapsedMs(cover_started)
                local lookup_started = perfNow()
                local downloaded_file = self.find_downloaded_file(item)
                local lookup_ms = perfElapsedMs(lookup_started)
                local tile_started = perfNow()
                local tile = CoverTile:new{
                    item = item,
                    cover = cover,
                    downloaded_file = downloaded_file,
                    width = self.tile_width,
                    height = self.tile_height,
                    on_select = self.on_select,
                }
                logMediaCatPerf("grid_tile page=%d visible_index=%d item_index=%d cover_source=%s cached_or_local_load_ms=%.3f download_lookup_ms=%.3f widget_create_ms=%.3f",
                    self.page or 1, visible_index, index,
                    item.local_path and "local" or (item.thumbnail or item.image) and "remote" or "none",
                    cover_load_ms, lookup_ms, perfElapsedMs(tile_started))
                table.insert(row_items, tile)
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
        footer_text = self.empty_message or _("No books in this catalog")
    else
        if self.total_count then
            footer_text = T(_("%1–%2 of %3 books"), first, last, self.total_count)
        elseif has_more then
            footer_text = T(_("%1–%2 of %3 books loaded"), first, last, #self.items)
        else
            footer_text = T(_("%1–%2 of %3 books"), first, last, #self.items)
        end
    end
    local footer_margin = Screen:scaleBySize(8)
    local navigation_button_width = Screen:scaleBySize(112)
    local footer_text_width = math.max(0, screen_w - 2 * footer_margin - 2 * navigation_button_width)
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = footer_h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = footer_margin },
            Button:new{
                text = _("Previous"),
                width = navigation_button_width,
                enabled = self.page > 1,
                show_parent = self,
                callback = function() self.on_page(self.page - 1) end,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = footer_text_width, h = footer_h },
                TextWidget:new{
                    text = footer_text,
                    face = Font:getFace("smallinfofont", 16),
                },
            },
            Button:new{
                text = _("Next"),
                width = navigation_button_width,
                enabled = self.page < total_pages,
                show_parent = self,
                callback = function() self.on_page(self.page + 1) end,
            },
            HorizontalSpan:new{ width = footer_margin },
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
    if self.can_go_back then
        self.on_back()
    end
    return true
end

function CoverGrid:onHome()
    -- Keep the catalog as the forced home view. The FileManager's separate
    -- top-edge swipe zone still opens the normal KOReader menu.
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
    end
    return true
end

local MediaCatMenu = Menu:extend{}

function MediaCatMenu:onHome()
    return true
end

function MediaCatMenu:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        -- The full-screen Menu would normally close on a south swipe. Route
        -- the gesture to FileManager's configured menu zones instead, so a
        -- top-edge swipe opens KOReader's normal menu without leaving MediaCat.
        if self.ui and self.ui.menu then
            self.ui.menu:onGesture(ges_ev)
        end
        return true
    end
    return Menu.onSwipe(self, arg, ges_ev)
end

local OPDSHome = WidgetContainer:extend{
    name = "mediacat",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/mediacat.lua",
}

function OPDSHome:init()
    -- FileManager creates plugin instances before setupLayout() creates its
    -- file chooser, so check for it from the post-init callback instead. KOReader
    -- also instantiates non-document plugins in ReaderUI, where it will be absent.
    if not self.ui or not self.ui.registerPostInitCallback then
        return
    end

    self.settings = LuaSettings:open(self.settings_file)
    self.saved_connection = self.settings:readSetting("connection", {})
    self.login_values = self.saved_connection
    self.history = {}
    self.cover_cache = {}
    self.ui:registerPostInitCallback(function()
        if not self.ui.file_chooser then
            return
        end
        UIManager:nextTick(function()
            if self.saved_connection and self.saved_connection.url then
                NetworkMgr:runWhenConnected(function()
                    self:connectToCatalog(self.saved_connection.url, _("MediaCat"), self.saved_connection,
                        _("Could not reconnect to MediaCat. Check the URL and login."))
                end)
            else
                self:showLogin()
            end
        end)
    end)
end

function OPDSHome:showConnecting()
    local message = ConnectingScreen:new{}
    UIManager:show(message, "full")
    UIManager:forceRePaint()
    return message
end

function OPDSHome:connectToCatalog(feed_url, title, connection, fallback_error)
    self.connection = connection or self.connection
    logger.info("MediaCat: connection attempt started")
    local previous_block_timeout = socketutil.LARGE_BLOCK_TIMEOUT
    local previous_total_timeout = socketutil.LARGE_TOTAL_TIMEOUT
    socketutil.LARGE_BLOCK_TIMEOUT = 5
    socketutil.LARGE_TOTAL_TIMEOUT = 5
    local connecting
    local ok, connected = xpcall(function()
        connecting = self:showConnecting()
        return self:openCatalog(feed_url, title, false)
    end, function(err)
        return logMediaCatError("connection flow", err)
    end)
    socketutil.LARGE_BLOCK_TIMEOUT = previous_block_timeout
    socketutil.LARGE_TOTAL_TIMEOUT = previous_total_timeout

    if not ok then
        self.last_catalog_error = connected
        connected = false
    end
    logger.info("MediaCat: connection attempt finished (connected=" .. tostring(connected) .. ")")

    if not connected then
        logger.warn("MediaCat: connection failed:", self.last_catalog_error or fallback_error or "unknown error")
        local shown, show_error = xpcall(function()
            self:showConnectionFailure()
        end, function(err)
            return logMediaCatError("showing connection failure choices", err)
        end)
        if not shown then
            self.last_catalog_error = show_error
        end
    end
    if connecting then
        local closed, close_error = pcall(UIManager.close, UIManager, connecting)
        if not closed then
            logMediaCatError("closing connection screen", close_error)
        end
    end
    return connected
end

function OPDSHome:showConnectionFailure()
    self.history = {}
    self.current_state = {
        items = {},
        is_offline = true,
        empty_message = _("MediaCat is not reachable"),
    }
    self:renderState(self.current_state)

    local dialog
    dialog = ButtonDialog:new{
        title = _("MediaCat is unavailable"),
        buttons = {
            {{
                text = _("Connect to another instance"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.login_values = self.connection or self.saved_connection
                    self:showLogin()
                end,
            }},
            {{
                text = _("Downloaded Books"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showDownloadedBooks()
                end,
            }},
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
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
        root_catalog_title = _("MediaCat"),
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
    menu = MediaCatMenu:new{
        ui = self.ui,
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
                    text = _("Downloaded Books"),
                    callback = function()
                        UIManager:close(dialog)
                        if self.current_screen == dialog then
                            self.current_screen = nil
                        end
                        self:showDownloadedBooks()
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
                                self:connectToCatalog(feed_url, _("MediaCat"), connection)
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
    local read_started = perfNow()
    self.last_catalog_error = nil
    local helper = self:newOPDSBrowser()
    if not helper then
        self.last_catalog_error = _("KOReader's built-in OPDS plugin is unavailable.")
        logMediaCatPerf("feed_read endpoint=%s outcome=unavailable total_ms=%.3f",
            perfEndpoint(feed_url), perfElapsedMs(read_started))
        return nil
    end
    helper.catalog_title = fallback_title
    logger.info("MediaCat: fetching catalog feed")
    local helper_parse_started = perfNow()
    local ok, catalog = xpcall(function()
        return helper:parseFeed(feed_url)
    end, function(err)
        return logMediaCatError("feed fetch and parse", err)
    end)
    logMediaCatPerf("feed_helper_parse endpoint=%s outcome=%s total_ms=%.3f",
        perfEndpoint(feed_url), ok and catalog and "ok" or "failed",
        perfElapsedMs(helper_parse_started))
    local function makeItems(parsed_catalog)
        if not parsed_catalog then
            return nil
        end
        local normalize_started = perfNow()
        local ok_items, items = xpcall(function()
            if parsed_catalog.is_opds2 then
                return helper:genItemTableFromCatalog2(parsed_catalog, feed_url)
            end
            return helper:genItemTableFromCatalog(parsed_catalog, feed_url)
        end, function(err)
            return logMediaCatError("feed normalization", err)
        end)
        if ok_items then
            local feed = parsed_catalog.feed or parsed_catalog
            local metadata = parsed_catalog.metadata
            items.total_count = tonumber(metadata and metadata.numberOfItems)
                or tonumber(feed["opensearch:totalResults"])
            logMediaCatPerf("feed_normalize endpoint=%s format=%s outcome=ok item_count=%d total_ms=%.3f",
                perfEndpoint(feed_url), parsed_catalog.is_opds2 and "opds2" or "atom",
                #items, perfElapsedMs(normalize_started))
            return items
        end
        logMediaCatPerf("feed_normalize endpoint=%s format=%s outcome=failed total_ms=%.3f",
            perfEndpoint(feed_url), parsed_catalog.is_opds2 and "opds2" or "atom",
            perfElapsedMs(normalize_started))
        return nil, tostring(items)
    end

    local initial_error = not ok and tostring(catalog) or nil
    local items, item_error
    if ok then
        items, item_error = makeItems(catalog)
    end
    if items then
        logger.info("MediaCat: catalog parsed (items=" .. tostring(#items) .. ")")
        logMediaCatPerf("feed_read endpoint=%s outcome=ok item_count=%d total_ms=%.3f",
            perfEndpoint(feed_url), #items, perfElapsedMs(read_started))
        return items, helper.catalog_title or fallback_title
    end

    -- Some servers expose both formats at one URL but return an OPDS 2.0
    -- representation that this KOReader version cannot normalize. Retry only
    -- after a successful HTTP response; don't mask network/authentication errors.
    if not helper.last_fetch_error and (not ok or not catalog
            or (type(catalog) == "table" and catalog.is_opds2)) then
        local fallback_started = perfNow()
        local fallback_ok, fallback_catalog = xpcall(function()
            return self:parseAtomFallback(helper, feed_url)
        end, function(err)
            return logMediaCatError("Atom fallback", err)
        end)
        logMediaCatPerf("feed_atom_fallback endpoint=%s outcome=%s total_ms=%.3f",
            perfEndpoint(feed_url), fallback_ok and fallback_catalog and "ok" or "failed",
            perfElapsedMs(fallback_started))
        if fallback_ok and fallback_catalog then
            helper.catalog_title = fallback_catalog.metadata and fallback_catalog.metadata.title or fallback_title
            local fallback_items, fallback_error = makeItems(fallback_catalog)
            if fallback_items then
                logMediaCatPerf("feed_read endpoint=%s outcome=ok_via_fallback item_count=%d total_ms=%.3f",
                    perfEndpoint(feed_url), #fallback_items, perfElapsedMs(read_started))
                return fallback_items, helper.catalog_title or fallback_title
            end
            item_error = fallback_error
        elseif not fallback_ok then
            item_error = tostring(fallback_catalog)
        end
    end

    self.last_catalog_error = helper.last_fetch_error or item_error or initial_error
        or _("The server did not return a parseable Atom or OPDS 2.0 feed.")
    logMediaCatPerf("feed_read endpoint=%s outcome=failed total_ms=%.3f",
        perfEndpoint(feed_url), perfElapsedMs(read_started))
    return nil
end

function OPDSHome:openCatalog(feed_url, title, push_history)
    local open_started = perfNow()
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
            title = feed_title or title or _("MediaCat"),
            items = items,
            hrefs = items.hrefs,
            total_count = items.total_count,
        }
        logger.info("MediaCat: rendering catalog screen")
        self:renderState(self.current_state)
        return true
    end, function(err)
        return logMediaCatError("opening or rendering catalog", err)
    end)
    if not ok then
        self.last_catalog_error = result
        logMediaCatPerf("catalog_open endpoint=%s outcome=exception total_ms=%.3f",
            perfEndpoint(feed_url), perfElapsedMs(open_started))
        return false
    end
    logMediaCatPerf("catalog_open endpoint=%s outcome=%s total_ms=%.3f",
        perfEndpoint(feed_url), result and "ok" or "failed",
        perfElapsedMs(open_started))
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

function OPDSHome:getDownloadedBooks()
    local download_dir
    if self.opds_browser and self.opds_browser.getCurrentDownloadDir then
        local ok, path = pcall(self.opds_browser.getCurrentDownloadDir, self.opds_browser)
        if ok then
            download_dir = path
        end
    end
    download_dir = download_dir or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("lastdir")
    if not download_dir or lfs.attributes(download_dir, "mode") ~= "directory" then
        return {}
    end

    local ok, iter, directory = pcall(lfs.dir, download_dir)
    if not ok then
        logger.warn("MediaCat: could not read downloaded books directory", download_dir, iter)
        return {}
    end

    local books = {}
    local prefix = download_dir:sub(-1) == "/" and "" or "/"
    for filename in iter, directory do
        if filename ~= "." and filename ~= ".." and filename:sub(1, 1) ~= "." then
            local path = download_dir .. prefix .. filename
            local attributes = lfs.attributes(path)
            if attributes and attributes.mode == "file" and DocumentRegistry:hasProvider(path) then
                local props = {}
                if self.ui.bookinfo then
                    local got_props, value = pcall(self.ui.bookinfo.getDocProps,
                        self.ui.bookinfo, path, nil, true)
                    if got_props and type(value) == "table" then
                        props = value
                    end
                end
                local title = props.display_title or filename:gsub("%.[^%.]+$", "")
                local author = props.authors
                table.insert(books, {
                    title = title,
                    author = author,
                    text = author and (title .. " - " .. author) or title,
                    local_path = path,
                })
            end
        end
    end
    table.sort(books, function(a, b)
        return a.title:lower() < b.title:lower()
    end)
    return books
end

function OPDSHome:showDownloadedBooks()
    local books = self:getDownloadedBooks()
    self:closeCurrentScreen()
    self.history = {}
    self.current_state = {
        items = books,
        total_count = #books,
        is_offline = true,
        empty_message = _("No downloaded books were found"),
    }
    self:renderState(self.current_state)
end

function OPDSHome:renderState(state)
    if state.is_offline or self:isLeaf(state) then
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
    menu = MediaCatMenu:new{
        ui = self.ui,
        title = _("MediaCat"),
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

function OPDSHome:getDownloadInfo(item)
    local browser = self.opds_browser
    if not browser then
        return
    end
    local filename = browser:getFileName(item)
    local first_download
    for _, acquisition in ipairs(item.acquisitions or {}) do
        local filetype
        if not acquisition.count and acquisition.type ~= "borrow" then
            filetype = browser.getFiletype(acquisition)
        end
        if filetype then
            local path = browser:getLocalDownloadPath(filename, filetype, acquisition.href)
            if lfs.attributes(path) then
                return path, acquisition
            end
            first_download = first_download or { path = path, acquisition = acquisition }
        end
    end
    if first_download then
        return nil, first_download.acquisition, first_download.path
    end
end

function OPDSHome:findDownloadedFile(item)
    if item.local_path then
        return item.local_path
    end
    local path = self:getDownloadInfo(item)
    return path
end

function OPDSHome:confirmDownloadAndOpen(item)
    local ConfirmBox = require("ui/widget/confirmbox")
    local existing_file, acquisition, path = self:getDownloadInfo(item)
    if existing_file then
        self:openDownloadedFile(existing_file)
        return
    end
    if not acquisition then
        UIManager:show(InfoMessage:new{
            text = T(_("No downloadable book format was found for %1."), item.title or item.text or ""),
        })
        return
    end

    local title = item.title or item.text or _("Untitled")
    local author = item.author or _("Unknown Author")
    UIManager:show(ConfirmBox:new{
        text = T(_("%1 by %2 is not currently on your device. Download and open now?"), title, author),
        ok_text = _("Yes"),
        cancel_text = _("No"),
        ok_callback = function()
            NetworkMgr:runWhenConnected(function()
                self.opds_browser:checkDownloadFile(path, acquisition.href,
                    self.connection.username, self.connection.password,
                    function(file) self:openDownloadedFile(file) end,
                    function(file) self:openDownloadedFile(file) end)
            end)
        end,
    })
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
        state.total_count = items.total_count or state.total_count
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
    local previous = table.remove(self.history)
    if previous then
        self:closeCurrentScreen()
        self.current_state = previous
        self:renderState(previous)
    end
end

function OPDSHome:showGrid(state, page)
    local grid_started = perfNow()
    local setup_started = perfNow()
    self:closeCurrentScreen()
    local layout = { getCoverGridLayout() }
    local per_page = layout[10]
    local total_pages = math.max(1, math.ceil(#state.items / per_page))
    page = math.max(1, math.min(page or 1, total_pages))
    local first = (page - 1) * per_page + 1
    local last = math.min(#state.items, first + per_page - 1)
    local page_items = {}
    local has_uncached_cover = false
    for index = first, last do
        local item = state.items[index]
        table.insert(page_items, item)
        local image_url = item.thumbnail or item.image
        if image_url and self.cover_cache[image_url] == nil then
            has_uncached_cover = true
        end
    end
    local visible_setup_ms = perfElapsedMs(setup_started)
    logMediaCatPerf("grid_page_start page=%d loaded_items=%d visible_items=%d visible_uncached=%s setup_ms=%.3f",
        page, #state.items, #page_items, tostring(has_uncached_cover), visible_setup_ms)
    local loading
    if has_uncached_cover then
        local cover_stage_started = perfNow()
        self:fetchCovers(page_items, function()
            if not loading then
                loading = self:showConnectingCovers()
            end
        end)
        logMediaCatPerf("grid_visible_covers page=%d stage_ms=%.3f",
            page, perfElapsedMs(cover_stage_started))
    end
    local has_more = not state.grid_exhausted and ((#(state.grid_pending_items or {}) > 0)
        or (state.hrefs and state.hrefs.next ~= nil))
    local widget_build_started = perfNow()
    local grid = CoverGrid:new{
        title = _("MediaCat"),
        can_go_back = #self.history > 0,
        items = state.items,
        page = page,
        total_count = state.total_count,
        empty_message = state.empty_message,
        has_more = has_more,
        load_cover = function(item, width, height) return self:loadCover(item, width, height) end,
        find_downloaded_file = function(item) return self:findDownloadedFile(item) end,
        on_select = function(item, file)
            if file then
                self:openDownloadedFile(file)
            else
                self:confirmDownloadAndOpen(item)
            end
        end,
        on_back = function() self:goBack() end,
        on_menu = function() self:showOptions(grid) end,
        on_page = function(next_page) self:showGrid(state, next_page) end,
        perf_paint_pending = true,
    }
    logMediaCatPerf("grid_widget_build page=%d visible_items=%d total_ms=%.3f",
        page, #page_items, perfElapsedMs(widget_build_started))
    if loading then
        UIManager:close(loading)
    end
    self.current_screen = grid
    local show_started = perfNow()
    UIManager:show(grid, "ui")
    local ui_show_ms = perfElapsedMs(show_started)
    local repaint_started = perfNow()
    UIManager:forceRePaint()
    local repaint_ms = perfElapsedMs(repaint_started)
    local refresh_wait_ms = 0
    if Device:hasEinkScreen() then
        local refresh_wait_started = perfNow()
        UIManager:waitForVSync()
        refresh_wait_ms = perfElapsedMs(refresh_wait_started)
    end
    logMediaCatPerf("grid_screen_ready page=%d ui_show_ms=%.3f paint_and_refresh_submit_ms=%.3f eink_refresh_wait_ms=%.3f total_ms=%.3f",
        page, ui_show_ms, repaint_ms, refresh_wait_ms, perfElapsedMs(grid_started))

    -- OPDS feeds choose their own response size and expose the next page as a
    -- link. Build ten grid pages at a time, retaining any surplus entries from
    -- a feed response for the next batch. Load the first batch after the first
    -- screen is painted, then start each later batch on the ninth page so its
    -- covers can be prefetched while the user views page ten.
    local batch_size = per_page * 10
    local target_count
    if page == 1 and #state.items < batch_size then
        target_count = batch_size
    elseif page % 10 == 9 then
        target_count = (math.floor((page - 1) / 10) + 2) * batch_size
    end
    if target_count and has_more and not state.grid_loading and #state.items < target_count then
        UIManager:nextTick(function()
            if self.current_state == state and self.current_screen == grid then
                self:loadGridBatch(state, target_count, page)
            end
        end)
    end

    local next_first = last + 1
    if next_first <= #state.items then
        local next_items = {}
        local next_last = math.min(#state.items, next_first + per_page - 1)
        for index = next_first, next_last do
            table.insert(next_items, state.items[index])
        end
        UIManager:nextTick(function()
            if self.current_state == state and self.current_screen == grid then
                Trapper:wrap(function()
                    self:prefetchCovers(next_items)
                end)
            end
        end)
    end
end

function OPDSHome:loadGridBatch(state, target_count, page)
    if state.grid_loading or self.current_state ~= state then
        return
    end

    state.grid_loading = true
    UIManager:preventStandby()
    local browser = self.opds_browser
    local connection = self.connection or {}
    local connection_url = connection.url
    local connection_username = connection.username
    local connection_password = connection.password

    local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_, child_write_fd)
        local ok, result = xpcall(function()
            local added_items = {}
            local pending_items = state.grid_pending_items or {}
            local hrefs = state.hrefs
            local total_count = state.total_count
            local requested_urls = state.grid_requested_urls or {}
            local exhausted = state.grid_exhausted
            local load_error

            if state.url then
                requested_urls[state.url] = true
            end
            while #state.items + #added_items < target_count do
                local needed = target_count - #state.items - #added_items
                while needed > 0 and #pending_items > 0 do
                    table.insert(added_items, table.remove(pending_items, 1))
                    needed = needed - 1
                end
                if #state.items + #added_items >= target_count then
                    break
                end

                local next_url = hrefs and hrefs.next
                if not next_url then
                    exhausted = true
                    break
                end
                if requested_urls[next_url] then
                    logger.warn("MediaCat: repeated OPDS next link while loading grid results", next_url)
                    exhausted = true
                    break
                end
                requested_urls[next_url] = true

                local items = self:readFeed(next_url, state.title)
                if not items then
                    requested_urls[next_url] = nil
                    load_error = self.last_catalog_error or "could not load the next OPDS page"
                    break
                end
                hrefs = items.hrefs
                total_count = items.total_count or total_count
                for _, item in ipairs(items) do
                    table.insert(pending_items, item)
                end
                if #items == 0 and not (hrefs and hrefs.next) then
                    exhausted = true
                end
            end

            local cookies
            if self.opds_browser and self.opds_browser.getHttpClient then
                local client = self.opds_browser:getHttpClient()
                cookies = client.cookie_jar and client.cookie_jar.cookies
            end
            return {
                added_items = added_items,
                pending_items = pending_items,
                hrefs = hrefs,
                total_count = total_count,
                requested_urls = requested_urls,
                exhausted = exhausted,
                cookies = cookies,
                error = load_error,
            }
        end, debug.traceback)
        if not ok then
            result = { error = result }
        end
        local encoded, serialized = pcall(buffer.encode, result)
        if not encoded then
            serialized = buffer.encode({ error = tostring(serialized) })
        end
        ffiUtil.writeToFD(child_write_fd, serialized, true)
    end, true)

    if not pid then
        state.grid_loading = false
        UIManager:allowStandby()
        logger.warn("MediaCat: could not start background grid fetch:", parent_read_fd)
        return
    end
    state.grid_loading_pid = pid

    local function finish(result)
        state.grid_loading = false
        state.grid_loading_pid = nil
        UIManager:allowStandby()

        if type(result) ~= "table" then
            logger.warn("MediaCat: background grid fetch returned no result")
            return
        end
        if result.error then
            logger.warn("MediaCat: could not load the next grid batch:", result.error)
            self.last_catalog_error = result.error
        end

        local changed = false
        for _, item in ipairs(result.added_items or {}) do
            table.insert(state.items, item)
            changed = true
        end
        state.grid_pending_items = result.pending_items or {}
        state.hrefs = result.hrefs
        state.total_count = result.total_count or state.total_count
        state.grid_requested_urls = result.requested_urls or state.grid_requested_urls
        if result.exhausted ~= state.grid_exhausted then
            changed = true
        end
        state.grid_exhausted = result.exhausted

        if result.cookies and self.opds_browser == browser and self.connection
                and self.connection.url == connection_url
                and self.connection.username == connection_username
                and self.connection.password == connection_password then
            local client = browser:getHttpClient()
            if client.cookie_jar then
                client.cookie_jar.cookies = result.cookies
            end
        end

        if changed and self.current_state == state and self.current_screen
                and getmetatable(self.current_screen) == CoverGrid then
            local current_page = self.current_screen.page or page
            self:showGrid(state, current_page)
        end
    end

    local function pollBackgroundFetch()
        local available = ffiUtil.getNonBlockingReadSize(parent_read_fd)
        local completed = ffiUtil.isSubProcessDone(pid)
        if completed or (available and available > 0) then
            local serialized = ffiUtil.readAllFromFD(parent_read_fd)
            if not completed then
                local function collectBackgroundFetch()
                    if not ffiUtil.isSubProcessDone(pid) then
                        UIManager:scheduleIn(0.2, collectBackgroundFetch)
                    end
                end
                UIManager:scheduleIn(0.2, collectBackgroundFetch)
            end
            local ok, result = pcall(buffer.decode, serialized)
            if not ok then
                logger.warn("MediaCat: could not decode background grid fetch result:", result)
                finish(nil)
            else
                finish(result)
            end
            return
        end
        UIManager:scheduleIn(0.2, pollBackgroundFetch)
    end
    UIManager:scheduleIn(0.1, pollBackgroundFetch)
end

function OPDSHome:showConnectingCovers()
    local overlay_started = perfNow()
    local message = InfoMessage:new{ text = _("Loading book covers…") }
    local show_started = perfNow()
    UIManager:show(message)
    local ui_show_ms = perfElapsedMs(show_started)
    local repaint_started = perfNow()
    UIManager:forceRePaint()
    logMediaCatPerf("cover_loading_overlay ui_show_ms=%.3f paint_and_refresh_submit_ms=%.3f total_ms=%.3f",
        ui_show_ms, perfElapsedMs(repaint_started), perfElapsedMs(overlay_started))
    return message
end

function OPDSHome:loadCover(item)
    if item.local_path then
        local cache_key = "local:" .. item.local_path
        local cached_cover = self.cover_cache[cache_key]
        if cached_cover ~= nil then
            return cached_cover or nil
        end
        local cover
        if self.ui.bookinfo then
            local ok, image = pcall(self.ui.bookinfo.getCoverImage,
                self.ui.bookinfo, nil, item.local_path)
            if ok then
                cover = image
            else
                logger.warn("MediaCat: could not load downloaded book cover", item.local_path, image)
            end
        end
        self.cover_cache[cache_key] = cover or false
        return cover
    end
    local image_url = item.thumbnail or item.image
    if not image_url then
        return
    end
    local cached_cover = self.cover_cache[image_url]
    if cached_cover ~= nil then
        return cached_cover or nil
    end
end

function OPDSHome:fetchCoverData(image_url)
    local request_started = perfNow()
    if self.opds_browser.getHttpClient then
        local chunks = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code, response_headers, request_status = pcall(function()
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
        local request_ms = perfElapsedMs(request_started)
        local body_join_ms = 0
        local data
        if ok and code == 200 then
            local join_started = perfNow()
            data = table.concat(chunks)
            body_join_ms = perfElapsedMs(join_started)
        end
        local bytes = data and #data or countChunkBytes(chunks)
        local status = ok and (code or request_status or "no_status") or "transport_error"
        logMediaCatPerf("cover_request mode=sequential endpoint=%s status=%s bytes=%d request_ms=%.3f body_join_ms=%.3f total_ms=%.3f outcome=%s",
            perfEndpoint(image_url), tostring(status), bytes,
            request_ms, body_join_ms, perfElapsedMs(request_started), data and "ok" or "failed")
        return data
    elseif self.opds_browser.fetchFeed then
        local ok, body, status = pcall(self.opds_browser.fetchFeed, self.opds_browser, image_url)
        local bytes = type(body) == "string" and #body or 0
        logMediaCatPerf("cover_request mode=opdsclient endpoint=%s status=%s bytes=%d fetch_and_body_join_ms=%.3f outcome=%s",
            perfEndpoint(image_url), tostring(status or (ok and "ok" or "error")), bytes,
            perfElapsedMs(request_started), ok and type(body) == "string" and "ok" or "failed")
        return ok and body or nil
    end
    logMediaCatPerf("cover_request endpoint=%s outcome=no_http_client total_ms=%.3f",
        perfEndpoint(image_url), perfElapsedMs(request_started))
end

local function isSameOrigin(left_url, right_url)
    local left = socket_url.parse(left_url)
    local right = socket_url.parse(right_url)
    if not left or not right or not left.host or not right.host then
        return false
    end
    local left_port = tonumber(left.port) or (left.scheme == "https" and 443 or 80)
    local right_port = tonumber(right.port) or (right.scheme == "https" and 443 or 80)
    return left.scheme == right.scheme and left.host:lower() == right.host:lower()
        and left_port == right_port
end

function OPDSHome:makeCoverFetchTasks(items, purpose)
    local planning_started = perfNow()
    local tasks = {}
    local seen = {}
    local client = self.opds_browser.getHttpClient and self.opds_browser:getHttpClient()
    local cookie_jar = client and client.cookie_jar
    local image_candidates = 0
    local cached = 0
    local duplicate_urls = 0
    for item_index, item in ipairs(items) do
        local image_url = item.thumbnail or item.image
        if image_url then
            image_candidates = image_candidates + 1
            if self.cover_cache[image_url] ~= nil then
                cached = cached + 1
            elseif seen[image_url] then
                duplicate_urls = duplicate_urls + 1
            else
                seen[image_url] = true
                local headers = { ["Accept-Encoding"] = "identity" }
                if cookie_jar then
                    local cookie = cookie_jar:headerFor(image_url)
                    if cookie then headers.Cookie = cookie end
                end
                if self.connection.username and self.connection.password
                        and isSameOrigin(self.connection.url, image_url) then
                    headers.Authorization = "Basic " .. mime.b64(
                        self.connection.username .. ":" .. self.connection.password)
                end
                table.insert(tasks, { url = image_url, headers = headers, perf_index = item_index })
            end
        end
    end
    logMediaCatPerf("cover_tasks purpose=%s items=%d image_candidates=%d cached=%d duplicate_urls=%d requests=%d planning_ms=%.3f",
        purpose or "unspecified", #items, image_candidates, cached, duplicate_urls,
        #tasks, perfElapsedMs(planning_started))
    return tasks
end

function OPDSHome:cacheCoverDownloads(tasks, downloaded, purpose)
    local decode_batch_started = perfNow()
    local decoded_count = 0
    local failed_count = 0
    for task_index, task in ipairs(tasks) do
        local data = downloaded and downloaded[task.url]
        if data then
            -- Keep the decoded image at its native dimensions so ImageWidget can
            -- fit it into the tile without changing the cover's aspect ratio.
            local decode_started = perfNow()
            local decode_ok, image = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
            logMediaCatPerf("cover_decode purpose=%s index=%s endpoint=%s bytes=%d decode_ms=%.3f outcome=%s",
                purpose or "unspecified", tostring(task.perf_index or task_index),
                perfEndpoint(task.url), #data, perfElapsedMs(decode_started), decode_ok and image and "ok" or "failed")
            if not decode_ok then
                error(image, 0)
            end
            self.cover_cache[task.url] = image or false
            if image then decoded_count = decoded_count + 1 else failed_count = failed_count + 1 end
        else
            logMediaCatPerf("cover_decode purpose=%s index=%s endpoint=%s bytes=0 decode_ms=0 outcome=not_downloaded",
                purpose or "unspecified", tostring(task.perf_index or task_index), perfEndpoint(task.url))
            self.cover_cache[task.url] = false
            failed_count = failed_count + 1
        end
    end
    logMediaCatPerf("cover_decode_batch purpose=%s requests=%d decoded=%d failed=%d total_ms=%.3f",
        purpose or "unspecified", #tasks, decoded_count, failed_count,
        perfElapsedMs(decode_batch_started))
end

function OPDSHome:fetchCovers(items, on_slow)
    local visible_started = perfNow()
    local tasks = self:makeCoverFetchTasks(items, "visible")
    if #tasks == 0 then
        logMediaCatPerf("cover_visible outcome=cache_hit_or_no_images total_ms=%.3f",
            perfElapsedMs(visible_started))
        return
    end

    local start_time = time.now()
    local loading_shown = false
    local function on_progress(completed, total)
        if on_slow and not loading_shown and completed < total
                and time.now() - start_time >= time.s(0.5) then
            loading_shown = true
            on_slow()
        end
        return true
    end
    local downloaded, err = fetchCoverBatch(tasks, on_progress, "visible")
    if not downloaded then
        logger.warn("MediaCat: parallel cover fetching failed; retrying sequentially:", err)
        local fallback_started = perfNow()
        downloaded = {}
        for _, task in ipairs(tasks) do
            downloaded[task.url] = self:fetchCoverData(task.url) or false
        end
        logMediaCatPerf("cover_sequential_fallback requests=%d total_ms=%.3f",
            #tasks, perfElapsedMs(fallback_started))
    end
    self:cacheCoverDownloads(tasks, downloaded, "visible")
    logMediaCatPerf("cover_visible outcome=complete requests=%d total_ms=%.3f",
        #tasks, perfElapsedMs(visible_started))
end

function OPDSHome:prefetchCovers(items)
    local prefetch_started = perfNow()
    local tasks = self:makeCoverFetchTasks(items, "prefetch")
    if #tasks == 0 then
        logMediaCatPerf("cover_prefetch outcome=cache_hit_or_no_images total_ms=%.3f",
            perfElapsedMs(prefetch_started))
        return
    end
    local has_async = pcall(require, "httpasync")
    if not has_async then
        logMediaCatPerf("cover_prefetch outcome=skipped reason=httpasync_unavailable requests=%d total_ms=%.3f",
            #tasks, perfElapsedMs(prefetch_started))
        return
    end
    local completed, downloaded = Trapper:dismissableRunInSubprocess(function()
        local results = fetchCoverBatch(tasks, nil, "prefetch")
        return results or {}
    end)
    if completed and type(downloaded) == "table" then
        self:cacheCoverDownloads(tasks, downloaded, "prefetch")
    end
    logMediaCatPerf("cover_prefetch outcome=%s requests=%d total_ms=%.3f",
        completed and "complete" or "cancelled", #tasks, perfElapsedMs(prefetch_started))
end

function OPDSHome:showOptions(anchor_menu)
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                text = _("Downloaded Books"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showDownloadedBooks()
                end,
            }},
            {{
                text = _("Connect to another MediaCat"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.login_values = self.connection or self.saved_connection
                    self:showLogin()
                end,
            }},
            {{
                text = _("Restart KOReader"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    UIManager:askForRestart(_("Restart KOReader now?"))
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
