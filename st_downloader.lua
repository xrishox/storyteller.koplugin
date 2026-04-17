-- SPDX-License-Identifier: AGPL-3.0-or-later

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Downloader = {}

function Downloader.getDownloadDir(settings)
    local dir = settings:getDownloadDir()
    if dir then
        return dir
    end
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir and home_dir ~= "" then
        return home_dir
    end
    local DataStorage = require("datastorage")
    return G_reader_settings:readSetting("download_dir") or DataStorage:getDataDir()
end

function Downloader.buildFilename(book, format_name)
    local title = book.title or "book"
    title = title:gsub("[^%w%s%-_]", ""):gsub("%s+", " ")
    if #title > 100 then
        title = title:sub(1, 100)
    end
    return ("%s.%s"):format(title, "epub")
end

function Downloader.getAvailableFormat(book, preferred_format)
    if preferred_format == "readaloud" and book.readaloud then
        return "readaloud"
    end
    if preferred_format == "ebook" and book.ebook then
        return "ebook"
    end
    if book.readaloud then
        return "readaloud"
    end
    if book.ebook then
        return "ebook"
    end
    return nil
end

function Downloader.confirmDownload(api, settings, book, on_complete)
    local ButtonDialog = require("ui/widget/buttondialog")
    local BD = require("ui/bidi")
    local format_name = Downloader.getAvailableFormat(book, settings:getPreferredFormat())
    local download_dir = Downloader.getDownloadDir(settings)

    if not format_name then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("This book has no downloadable EPUB format."),
            timeout = 3,
        })
        return
    end

    local function titleText()
        return T(_("Download \"%1\" as %2?\n\nFolder: %3"),
            book.title or _("Untitled"),
            format_name,
            BD.dirpath(download_dir))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = titleText(),
        buttons = {
            {
                {
                    text = _("Choose folder"),
                    callback = function()
                        require("ui/downloadmgr"):new{
                            onConfirm = function(path)
                                download_dir = path
                                settings:setDownloadDir(path)
                                dialog:setTitle(titleText())
                            end,
                        }:chooseDir(download_dir)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dialog)
                        Downloader.downloadBook(api, settings, book, format_name, download_dir, on_complete)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Downloader.downloadBook(api, settings, book, format_name, download_dir, on_complete)
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")
    local Sync = require("st_sync")
    local lfs = require("libs/libkoreader-lfs")

    NetworkMgr:runWhenOnline(function()
        lfs.mkdir(download_dir)
        local filepath = download_dir .. "/" .. Downloader.buildFilename(book, format_name)
        local ok, response = api:downloadFile(book.uuid, format_name, filepath)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Download failed."),
            })
            return
        end

        Sync:setBookMeta(filepath, {
            book_uuid = book.uuid,
            format = format_name,
            downloaded_hash = response and response["x-storyteller-hash"] or nil,
        })

        if on_complete then
            on_complete(filepath)
        end

        UIManager:show(InfoMessage:new{
            text = T(_("Downloaded to:\n%1"), filepath),
            timeout = 5,
        })
    end)
end

return Downloader
