-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Provenance: portions of this file were adapted from
-- `bookfusion.koplugin/main.lua`, a separate third-party KOReader plugin
-- source snapshot kept alongside this work for reference.
-- The adapted portions remain available under the GNU Affero General Public
-- License, version 3 or any later version. See `bookfusion.koplugin/LICENSE`.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local Log = require("st_log")

local Storyteller = WidgetContainer:extend{
    name = "storyteller",
    is_doc_only = false,
}

function Storyteller:init()
    local Settings = require("st_settings")
    local Api = require("st_api")

    self.st_settings = Settings:new()
    self.api = Api:new(self.st_settings)
    self.ui.menu:registerToMainMenu(self)
    Log:info("plugin_init", {
        server_url = self.st_settings:getServerUrl(),
        logged_in = self.st_settings:isLoggedIn(),
        log_path = Log:getPath(),
    })
end

function Storyteller:addToMainMenu(menu_items)
    menu_items.storyteller = {
        text = _("Storyteller"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:buildMenuTable()
        end,
    }
end

function Storyteller:buildMenuTable()
    local has_doc = self.ui.document ~= nil

    if self.st_settings:isLoggedIn() then
        return {
            {
                text = _("Browse books"),
                callback = function()
                    self:onBrowseBooks()
                end,
            },
            {
                text = _("Push reading position"),
                enabled_func = function()
                    return has_doc
                end,
                callback = function()
                    self:onPushProgress()
                end,
            },
            {
                text = _("Fetch reading position"),
                enabled_func = function()
                    return has_doc
                end,
                callback = function()
                    self:onFetchProgress()
                end,
            },
            {
                text = _("Auto-sync"),
                checked_func = function()
                    return self.st_settings:getSyncEnabled()
                end,
                callback = function()
                    self:toggleAutoSync()
                end,
                separator = true,
            },
            {
                text = _("Unlink device"),
                callback = function()
                    self:onUnlinkDevice()
                end,
            },
        }
    end

    return {
        {
            text = _("Set server URL"),
            callback = function()
                self:promptServerUrl(function() end)
            end,
        },
        {
            text = _("Link device"),
            callback = function()
                self:onLinkDevice()
            end,
        },
    }
end

function Storyteller:promptServerUrl(on_done)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")

    local dialog
    dialog = InputDialog:new{
        title = _("Storyteller server URL"),
        input = self.st_settings:getServerUrl() or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputValue()
                        value = self.api:normalizeUrl(value)
                        self.st_settings:setServerUrl(value)
                        Log:info("server_url_set", { server_url = value })
                        UIManager:close(dialog)
                        if on_done then
                            on_done(value)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Storyteller:onLinkDevice()
    local server_url = self.st_settings:getServerUrl()
    if not server_url or server_url == "" then
        self:promptServerUrl(function(value)
            if value and value ~= "" then
                self:startDeviceCodeFlow()
            end
        end)
        return
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:startDeviceCodeFlow()
    end)
end

function Storyteller:startDeviceCodeFlow()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    local ok, data = self.api:requestDeviceCode()
    if not ok or not data then
        Log:warn("device_link_start_failed", data)
        UIManager:show(InfoMessage:new{
            text = _("Failed to start Storyteller device linking."),
        })
        return
    end
    Log:info("device_link_started", data)

    self._device_code = data.device_code
    self._poll_interval = data.interval or 5
    self._poll_expires_at = os.time() + (data.expires_in or 600)

    self._auth_dialog = InfoMessage:new{
        text = T(_("Visit:\n%1\n\nEnter code:\n%2\n\nWaiting for authorization…"),
            data.verification_uri or "",
            data.user_code or ""),
        timeout = data.expires_in or 600,
    }
    UIManager:show(self._auth_dialog)
    self:schedulePoll()
end

function Storyteller:schedulePoll()
    local UIManager = require("ui/uimanager")
    self._poll_task = function()
        self:pollForToken()
    end
    UIManager:scheduleIn(self._poll_interval, self._poll_task)
end

function Storyteller:pollForToken()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    if os.time() >= self._poll_expires_at then
        self:dismissAuthDialog()
        UIManager:show(InfoMessage:new{
            text = _("Device code expired. Please try again."),
        })
        return
    end

    local ok, data = self.api:pollForToken(self._device_code)
    if ok and data and data.access_token then
        self.st_settings:setToken(data.access_token)
        local user_ok, user_data = self.api:getCurrentUser()
        if user_ok and user_data and user_data.username then
            self.st_settings:setUsername(user_data.username)
        end
        Log:info("device_link_success", {
            username = user_data and user_data.username or nil,
        })
        self:dismissAuthDialog()
        UIManager:show(InfoMessage:new{
            text = _("Device linked successfully!"),
            timeout = 3,
        })
        return
    end

    if type(data) == "table" then
        if data.error == "authorization_pending" then
            Log:info("device_link_pending")
            self:schedulePoll()
            return
        elseif data.error == "slow_down" then
            Log:warn("device_link_slow_down", data)
            self._poll_interval = self._poll_interval + 5
            self:schedulePoll()
            return
        elseif data.error == "expired_token" then
            Log:warn("device_link_expired", data)
            self:dismissAuthDialog()
            UIManager:show(InfoMessage:new{
                text = _("Device code expired. Please try again."),
            })
            return
        elseif data.error == "access_denied" then
            Log:warn("device_link_denied", data)
            self:dismissAuthDialog()
            UIManager:show(InfoMessage:new{
                text = _("Authorization was denied."),
            })
            return
        end
    end

    Log:warn("device_link_poll_unknown", data)
    self:schedulePoll()
end

function Storyteller:dismissAuthDialog()
    local UIManager = require("ui/uimanager")
    if self._auth_dialog then
        UIManager:close(self._auth_dialog)
        self._auth_dialog = nil
    end
    if self._poll_task then
        UIManager:unschedule(self._poll_task)
        self._poll_task = nil
    end
    self._device_code = nil
end

function Storyteller:onUnlinkDevice()
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local username = self.st_settings:getUsername()

    UIManager:show(ConfirmBox:new{
        text = username and T(_("Unlink Storyteller device for %1?"), username)
            or _("Unlink this device from Storyteller?"),
        ok_text = _("Unlink"),
        ok_callback = function()
            self.st_settings:clearAuth()
            Log:info("device_unlinked")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Device unlinked."),
                timeout = 3,
            })
        end,
    })
end

function Storyteller:onBrowseBooks()
    local Browser = require("st_browser")
    Browser:new(self.api, self.st_settings):show()
end

function Storyteller:getCurrentSync()
    if not self.ui.document or not self.ui.doc_settings then
        return nil
    end
    local filepath = self.ui.document.file
    if not filepath then
        return nil
    end
    local Sync = require("st_sync")
    local book_meta = Sync:getBookMeta(filepath)
    if not book_meta or not book_meta.book_uuid then
        return nil
    end
    return Sync:new(self.api, self.st_settings, self.ui, filepath, book_meta)
end

function Storyteller:toggleAutoSync()
    local enabled = not self.st_settings:getSyncEnabled()
    self.st_settings:setSyncEnabled(enabled)
    Log:info("autosync_toggled", { enabled = enabled })

    if not self.ui.document then
        return
    end

    if enabled then
        self:enableSync(true)
    else
        self:disableSync()
    end
end

function Storyteller:onReaderReady()
    if not self.st_settings:isLoggedIn() then
        Log:info("autosync_skip_not_logged_in")
        return
    end
    if not self.st_settings:getSyncEnabled() then
        Log:info("autosync_skip_disabled")
        return
    end
    self:enableSync(true)
end

function Storyteller:enableSync(initial)
    if self.sync then
        return
    end
    if not self.ui.document then
        return
    end

    local Sync = require("st_sync")
    local filepath = self.ui.document.file
    self.book_meta = filepath and Sync:getBookMeta(filepath) or nil
    self.sync = Sync:new(self.api, self.st_settings, self.ui, filepath, self.book_meta)

    if self.book_meta and self.book_meta.book_uuid then
        Log:info("autosync_enabled", {
            filepath = filepath,
            book_uuid = self.book_meta.book_uuid,
            initial = initial == true,
        })
        self.onPageUpdate = self._onPageUpdate
        if initial then
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                self:fetchIfRemoteNewer("reader_ready")
            end)
        end
    else
        Log:info("autosync_no_storyteller_book", { filepath = filepath })
        self.sync = nil
        self.book_meta = nil
    end
end

function Storyteller:disableSync()
    if self._progress_push_task then
        local UIManager = require("ui/uimanager")
        UIManager:unschedule(self._progress_push_task)
        self._progress_push_task = nil
    end
    self.onPageUpdate = nil
    self.sync = nil
    self.book_meta = nil
    self._pending_progress_payload = nil
    Log:info("autosync_disabled")
end

function Storyteller:_onPageUpdate(page)
    if not self.sync or not self.book_meta or not self.book_meta.book_uuid then
        return
    end
    if page == nil or page == self._last_page then
        return
    end
    self._last_page = page
    self._pending_progress_payload = self.sync:buildProgressPayload(
        math.floor(os.time() * 1000)
    )
    Log:info("autosync_progress_captured", {
        page = page,
        payload = self._pending_progress_payload,
    })
    self:scheduleProgressPush()
end

function Storyteller:scheduleProgressPush()
    local UIManager = require("ui/uimanager")
    if self._progress_push_task then
        UIManager:unschedule(self._progress_push_task)
    end
    self._progress_push_task = function()
        self._progress_push_task = nil
        self:pushProgressIfPossible("scheduled")
    end
    UIManager:scheduleIn(5, self._progress_push_task)
    Log:info("autosync_progress_scheduled")
end

function Storyteller:pushProgressIfPossible(reason)
    if not self.sync or not self.book_meta or not self.book_meta.book_uuid then
        return false
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        Log:warn("autosync_push_skipped_offline", { reason = reason })
        return false
    end
    local payload = self._pending_progress_payload
    local ok, result = pcall(self.sync.pushProgress, self.sync, payload)
    Log:info("autosync_push_result", {
        reason = reason,
        ok = ok and result == true,
        pcall_ok = ok,
        result = ok and result or tostring(result),
        used_captured_payload = payload ~= nil,
    })
    if ok and result == true then
        self._pending_progress_payload = nil
    end
    return ok and result == true
end

function Storyteller:fetchIfRemoteNewer(reason)
    if not self.sync or not self.book_meta or not self.book_meta.book_uuid then
        return false
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        Log:warn("autosync_fetch_skipped_offline", { reason = reason })
        return false
    end

    local ok, data = self.sync:fetchProgress()
    if not ok or not data or not data.locator then
        Log:warn("autosync_fetch_failed", { reason = reason, response = data })
        return false
    end

    local remote_timestamp = data.timestamp
    local local_timestamp = self.book_meta.last_sync_timestamp
    if remote_timestamp and local_timestamp and remote_timestamp <= local_timestamp then
        Log:info("autosync_fetch_not_newer", {
            reason = reason,
            remote_timestamp = remote_timestamp,
            local_timestamp = local_timestamp,
        })
        return false
    end

    local applied = self.sync:applyRemoteProgress(data)
    Log:info("autosync_fetch_applied", {
        reason = reason,
        applied = applied,
        remote_timestamp = remote_timestamp,
        local_timestamp = local_timestamp,
    })
    return applied
end

function Storyteller:onCloseDocument()
    self.onPageUpdate = nil

    local UIManager = require("ui/uimanager")
    local had_pending_progress = self._progress_push_task ~= nil
    if self._progress_push_task then
        UIManager:unschedule(self._progress_push_task)
        self._progress_push_task = nil
    end

    if had_pending_progress then
        self:pushProgressIfPossible("close_document")
    end

    self.sync = nil
    self.book_meta = nil
    self._last_page = nil
    self._pending_progress_payload = nil
    Log:info("autosync_close_document", { had_pending_progress = had_pending_progress })
end

function Storyteller:onSuspend()
    if self._progress_push_task then
        local UIManager = require("ui/uimanager")
        UIManager:unschedule(self._progress_push_task)
        self._progress_push_task = nil
        self:pushProgressIfPossible("suspend")
    end
end

function Storyteller:onResume()
    if not self.st_settings:getSyncEnabled() then
        return
    end
    if not self.sync or not self.book_meta or not self.book_meta.book_uuid then
        return
    end
    self:fetchIfRemoteNewer("resume")
end

function Storyteller:onPushProgress()
    local sync = self:getCurrentSync()
    if not sync then
        self:showNotStorytellerBookMessage()
        return
    end

    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")

    local msg = InfoMessage:new{ text = _("Pushing reading position…") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    NetworkMgr:runWhenOnline(function()
        local ok = sync:pushProgress()
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{
            text = ok and _("Reading position pushed.") or _("Failed to push reading position."),
            timeout = 2,
        })
    end)
end

function Storyteller:onFetchProgress()
    local sync = self:getCurrentSync()
    if not sync then
        self:showNotStorytellerBookMessage()
        return
    end

    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")

    local msg = InfoMessage:new{ text = _("Fetching reading position…") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    NetworkMgr:runWhenOnline(function()
        local ok, data = sync:fetchProgress()
        UIManager:close(msg)
        if ok and data and data.locator then
            local applied = sync:applyRemoteProgress(data)
            UIManager:show(InfoMessage:new{
                text = applied and _("Remote position applied.")
                    or _("Remote position fetched, but could not be restored precisely."),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch reading position."),
                timeout = 2,
            })
        end
    end)
end

function Storyteller:showNotStorytellerBookMessage()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("This book was not downloaded from Storyteller."),
        timeout = 3,
    })
end

return Storyteller
