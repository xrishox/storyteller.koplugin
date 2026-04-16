-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Provenance: portions of this file were adapted from
-- `bookfusion.koplugin/bf_sync.lua`, a separate third-party KOReader plugin
-- source snapshot kept alongside this work for reference.
-- The adapted portions remain available under the GNU Affero General Public
-- License, version 3 or any later version. See `bookfusion.koplugin/LICENSE`.

local LuaSettings = require("luasettings")
local logger = require("logger")
local Log = require("st_log")

local Sync = {}

function Sync:new(api, settings, ui, filepath, book_meta)
    local instance = setmetatable({}, { __index = self })
    instance.api = api
    instance.settings = settings
    instance.ui = ui
    instance.filepath = filepath
    instance.book_meta = book_meta
    if ui and ui.document and not ui.document.info.has_pages then
        local Epub = require("st_epub")
        instance._epub = Epub:new(ui.document)
    end
    return instance
end

function Sync:getBookMeta(filepath)
    local DocSettings = require("docsettings")
    local sidecar_dir = DocSettings:getSidecarDir(filepath)
    local meta_path = sidecar_dir .. "/storyteller.lua"
    local ok, meta = pcall(LuaSettings.open, LuaSettings, meta_path)
    if not ok then
        return nil
    end
    local book_uuid = meta:readSetting("book_uuid")
    if not book_uuid then
        return nil
    end
    return {
        book_uuid = book_uuid,
        format = meta:readSetting("format"),
        last_sync_timestamp = meta:readSetting("last_sync_timestamp"),
        _settings = meta,
    }
end

function Sync:setBookMeta(filepath, data)
    local DocSettings = require("docsettings")
    local lfs = require("libs/libkoreader-lfs")
    local sidecar_dir = DocSettings:getSidecarDir(filepath)
    lfs.mkdir(sidecar_dir)
    local meta_path = sidecar_dir .. "/storyteller.lua"
    local meta = LuaSettings:open(meta_path)
    for key, value in pairs(data) do
        if key ~= "_settings" then
            meta:saveSetting(key, value)
        end
    end
    meta:flush()
end

function Sync:getCurrentLocator()
    local locator = {
        href = "",
        type = "application/xhtml+xml",
        locations = {},
    }

    if self.ui.document.info.has_pages then
        locator.locations.totalProgression = self.ui.paging:getLastPercent() or 0
    else
        local xpointer = self.ui.rolling:getLastProgress()
        locator.locations.totalProgression = self.ui.rolling:getLastPercent() or 0
        if self._epub and xpointer then
            local chapter_index = self._epub:getSpinePosition(xpointer)
            if chapter_index then
                locator.href = self._epub:getSpinePath(chapter_index)
                    or self._epub:getSpineHref(chapter_index)
                    or ""
                locator.locations.progression = self._epub:getPositionInChapter(xpointer) or 0
            end
            local fragment = self._epub:getFragmentForXPointer(xpointer)
            if fragment then
                locator.locations.fragments = { fragment }
            end
        end
    end

    Log:info("current_locator", locator)
    return locator
end

function Sync:buildProgressPayload(timestamp)
    local payload_timestamp = timestamp or math.floor(os.time() * 1000)
    return {
        locator = self:getCurrentLocator(),
        timestamp = payload_timestamp,
    }
end

function Sync:applyRemoteProgress(remote)
    local locator = remote and remote.locator or nil
    if not locator then
        Log:warn("apply_remote_missing_locator", remote)
        return false
    end
    Log:info("apply_remote_begin", remote)

    local Event = require("ui/event")
    local target = nil

    if not self.ui.document.info.has_pages and self._epub then
        local href = locator.href
        local locations = locator.locations or {}
        local fragments = locations.fragments or {}
        local progression = locations.progression
        local total_progression = locations.totalProgression
        local partial_cfi = locations.partialCfi
        local apply_attempts = {}

        if partial_cfi then
            table.insert(apply_attempts, {
                method = "partial_cfi",
                value = partial_cfi,
            })
            target = self._epub:resolveCfi(partial_cfi)
        end

        if not target and href and fragments[1] then
            table.insert(apply_attempts, {
                method = "fragment",
                href = href,
                fragment = fragments[1],
            })
            target = self._epub:getXPointerFromHrefAndFragment(href, fragments[1])
        end

        if not target and href and progression ~= nil then
            table.insert(apply_attempts, {
                method = "progression",
                href = href,
                progression = progression,
            })
            target = self._epub:getXPointerFromHrefAndProgression(href, progression)
        end

        if not target and href then
            table.insert(apply_attempts, {
                method = "chapter_start",
                href = href,
            })
            target = self._epub:getChapterStartXPointer(href)
        end

        Log:info("apply_remote_attempts", {
            locator = locator,
            attempts = apply_attempts,
            resolved_target = target,
            total_progression = total_progression,
        })

        if target then
            Log:info("apply_remote_xpointer", { target = target, locator = locator })
            self.ui:handleEvent(Event:new("GotoXPointer", target))
            if remote.timestamp then
                self.book_meta.last_sync_timestamp = remote.timestamp
                self:setBookMeta(self.filepath, self.book_meta)
            end
            return true
        end
    end

    local total_progression = locator.locations and locator.locations.totalProgression or nil
    if total_progression ~= nil and self.ui.document.info.has_pages then
        local total = tonumber(total_progression) or 0
        local page_count = self.ui.document.info.number_of_pages or 1
        local page = math.max(1, math.floor(total * page_count))
        Log:info("apply_remote_page", { page = page, locator = locator })
        self.ui:handleEvent(Event:new("GotoPage", page))
        if remote.timestamp then
            self.book_meta.last_sync_timestamp = remote.timestamp
            self:setBookMeta(self.filepath, self.book_meta)
        end
        return true
    end

    Log:warn("apply_remote_failed", remote)
    return false
end

function Sync:pushProgress(payload)
    if not self.book_meta or not self.book_meta.book_uuid then
        return false, "book_not_linked"
    end

    payload = payload or self:buildProgressPayload()
    local timestamp = payload.timestamp
    Log:info("push_progress_payload", {
        book_uuid = self.book_meta.book_uuid,
        filepath = self.filepath,
        payload = payload,
    })

    local ok, data = self.api:updatePosition(self.book_meta.book_uuid, payload)
    if not ok then
        Log:warn("push_progress_failed", {
            book_uuid = self.book_meta.book_uuid,
            response = data,
        })
        return false, data
    end

    if data and data.message then
        logger.dbg("Storyteller: push returned message", data.message)
        Log:warn("push_progress_conflict_or_message", {
            book_uuid = self.book_meta.book_uuid,
            response = data,
        })
        return false, data
    end

    self.book_meta.last_sync_timestamp = timestamp
    self:setBookMeta(self.filepath, self.book_meta)
    Log:info("push_progress_success", {
        book_uuid = self.book_meta.book_uuid,
        timestamp = timestamp,
    })
    return true
end

function Sync:fetchProgress()
    if not self.book_meta or not self.book_meta.book_uuid then
        return false, "book_not_linked"
    end
    local ok, data = self.api:getPosition(self.book_meta.book_uuid)
    if ok then
        Log:info("fetch_progress_success", {
            book_uuid = self.book_meta.book_uuid,
            response = data,
        })
    else
        Log:warn("fetch_progress_failed", {
            book_uuid = self.book_meta.book_uuid,
            response = data,
        })
    end
    return ok, data
end

return Sync
