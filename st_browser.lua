-- SPDX-License-Identifier: AGPL-3.0-or-later

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local T = require("ffi/util").template
local Log = require("st_log")

local Browser = {}

function Browser:new(api, settings)
    local instance = setmetatable({}, { __index = self })
    instance.api = api
    instance.settings = settings
    return instance
end

function Browser:show()
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")

    self.menu = Menu:new{
        title = _("Storyteller"),
        item_table = {
            { text = _("Loading…"), dim = true },
        },
        onMenuSelect = function(_, item)
            if not item then
                return
            elseif item.open_root then
                self:showRoot()
            elseif item.open_currently_reading then
                self:openCurrentlyReading()
            elseif item.open_all_books then
                self:openAllBooks()
            elseif item.open_collections then
                self:openCollections()
            elseif item.open_series then
                self:openSeries()
            elseif item.collection then
                self:openCollectionBooks(item.collection)
            elseif item.series then
                self:openSeriesBooks(item.series)
            elseif item.book then
                self:onSelectBook(item.book)
            end
        end,
        close_callback = function()
            UIManager:close(self.menu)
            self.menu = nil
        end,
    }
    UIManager:show(self.menu)

    NetworkMgr:runWhenOnline(function()
        local books_ok, books = self.api:listBooks()
        local collections_ok, collections = self.api:listCollections()
        local series_ok, series = self.api:listSeries()

        if not books_ok or not collections_ok or not series_ok then
            Log:warn("browser_load_failed", {
                books_ok = books_ok,
                collections_ok = collections_ok,
                series_ok = series_ok,
            })
            UIManager:show(InfoMessage:new{
                text = _("Failed to load Storyteller library data."),
            })
            return
        end

        self.books = self:filterDownloadableBooks(books or {})
        self.collections = collections or {}
        self.series = series or {}
        self:showRoot()
    end)
end

function Browser:filterDownloadableBooks(books)
    local items = {}
    for _, book in ipairs(books) do
        if book.uuid and (book.readaloud or book.ebook) then
            table.insert(items, book)
        end
    end
    return items
end

function Browser:getAuthorLine(book)
    if not book.authors or #book.authors == 0 then
        return nil
    end

    local names = {}
    for _, author in ipairs(book.authors) do
        if author.name then
            table.insert(names, author.name)
        end
    end

    if #names == 0 then
        return nil
    end

    return table.concat(names, ", ")
end

function Browser:getCountLabel(count)
    if count == 1 then
        return _("1 book")
    end
    return T(_("%1 books"), count)
end

function Browser:switchView(title, items)
    if self.menu then
        self.menu:switchItemTable(title, items)
    end
end

function Browser:showRoot()
    self:switchView(_("Storyteller"), self:buildRootItems())
end

function Browser:buildRootItems()
    local currently_reading_count = #self:getCurrentlyReadingBooks()
    local book_count = self.books and #self.books or 0
    local collection_count = self.collections and #self.collections or 0
    local series_count = self.series and #self.series or 0

    return {
        {
            text = _("Currently Reading"),
            mandatory = self:getCountLabel(currently_reading_count),
            open_currently_reading = true,
        },
        {
            text = _("All books"),
            mandatory = self:getCountLabel(book_count),
            open_all_books = true,
        },
        {
            text = _("Collections"),
            mandatory = self:getCountLabel(collection_count),
            open_collections = true,
        },
        {
            text = _("Series"),
            mandatory = self:getCountLabel(series_count),
            open_series = true,
        },
    }
end

function Browser:openCurrentlyReading()
    local books = self:getCurrentlyReadingBooks()
    self:switchView(_("Currently Reading"), self:buildBookItems(books, true))
end

function Browser:openAllBooks()
    local books = {}
    for _, book in ipairs(self.books or {}) do
        table.insert(books, book)
    end
    table.sort(books, function(a, b)
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    self:switchView(_("All books"), self:buildBookItems(books, true))
end

function Browser:openCollections()
    self:switchView(_("Collections"), self:buildCollectionItems())
end

function Browser:openSeries()
    self:switchView(_("Series"), self:buildSeriesItems())
end

function Browser:openCollectionBooks(collection)
    local books = self:getBooksForCollection(collection.uuid)
    table.sort(books, function(a, b)
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    self:switchView(collection.name or _("Collection"), self:buildBookItems(books, true))
end

function Browser:openSeriesBooks(series)
    local books = self:getBooksForSeries(series.uuid)
    books = self:sortBooksForSeries(series.uuid, books)
    self:switchView(series.name or _("Series"), self:buildBookItems(books, true))
end

function Browser:buildBackItem()
    return {
        text = _("Back"),
        open_root = true,
    }
end

function Browser:buildBookItems(books, include_back)
    local items = {}
    for _, book in ipairs(books) do
        table.insert(items, {
            text = book.title or _("Untitled"),
            mandatory = self:getAuthorLine(book),
            book = book,
        })
    end

    if #books == 0 then
        if include_back then
            table.insert(items, 1, self:buildBackItem())
        end
        table.insert(items, { text = _("No downloadable books found."), dim = true })
        return items
    end

    if include_back then
        table.insert(items, 1, self:buildBackItem())
    end
    return items
end

function Browser:buildCollectionItems()
    local items = {}
    for _, collection in ipairs(self.collections or {}) do
        local books = self:getBooksForCollection(collection.uuid)
        table.insert(items, {
            text = collection.name or _("Untitled"),
            mandatory = self:getCountLabel(#books),
            collection = collection,
        })
    end

    if #items == 0 then
        items = { self:buildBackItem(), { text = _("No collections found."), dim = true } }
        return items
    end

    table.sort(items, function(a, b)
        return (a.text or ""):lower() < (b.text or ""):lower()
    end)
    table.insert(items, 1, self:buildBackItem())
    return items
end

function Browser:buildSeriesItems()
    local items = {}
    for _, series in ipairs(self.series or {}) do
        local books = self:getBooksForSeries(series.uuid)
        table.insert(items, {
            text = series.name or _("Untitled"),
            mandatory = self:getCountLabel(#books),
            series = series,
        })
    end

    if #items == 0 then
        items = { self:buildBackItem(), { text = _("No series found."), dim = true } }
        return items
    end

    table.sort(items, function(a, b)
        return (a.text or ""):lower() < (b.text or ""):lower()
    end)
    table.insert(items, 1, self:buildBackItem())
    return items
end

function Browser:getBooksForCollection(collection_uuid)
    local filtered = {}
    for _, book in ipairs(self.books or {}) do
        for _, collection in ipairs(book.collections or {}) do
            if collection.uuid == collection_uuid then
                table.insert(filtered, book)
                break
            end
        end
    end
    return filtered
end

function Browser:getBooksForSeries(series_uuid)
    local filtered = {}
    for _, book in ipairs(self.books or {}) do
        for _, series in ipairs(book.series or {}) do
            if series.uuid == series_uuid then
                table.insert(filtered, book)
                break
            end
        end
    end
    return filtered
end

function Browser:getCurrentlyReadingBooks()
    local filtered = {}
    for _, book in ipairs(self.books or {}) do
        if book.status and book.status.name == "Reading" then
            table.insert(filtered, book)
        end
    end

    table.sort(filtered, function(a, b)
        local ts_a = a.position and a.position.timestamp or 0
        local ts_b = b.position and b.position.timestamp or 0
        if ts_a ~= ts_b then
            return ts_a > ts_b
        end
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)

    return filtered
end

function Browser:getSeriesRelation(book, series_uuid)
    for _, series in ipairs(book.series or {}) do
        if series.uuid == series_uuid then
            return series
        end
    end
    return nil
end

function Browser:sortBooksForSeries(series_uuid, books)
    table.sort(books, function(a, b)
        local rel_a = self:getSeriesRelation(a, series_uuid) or {}
        local rel_b = self:getSeriesRelation(b, series_uuid) or {}
        local pos_a = tonumber(rel_a.position)
        local pos_b = tonumber(rel_b.position)

        if pos_a ~= nil and pos_b ~= nil and pos_a ~= pos_b then
            return pos_a < pos_b
        end
        if pos_a ~= nil and pos_b == nil then
            return true
        end
        if pos_a == nil and pos_b ~= nil then
            return false
        end

        return (a.title or ""):lower() < (b.title or ""):lower()
    end)

    return books
end

function Browser:onSelectBook(book)
    local Downloader = require("st_downloader")
    Downloader.confirmDownload(self.api, self.settings, book)
end

return Browser
