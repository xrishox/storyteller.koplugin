-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Provenance: portions of this file were adapted from
-- `bookfusion.koplugin/bf_epub.lua`, a separate third-party KOReader plugin
-- The adapted portions remain available under the GNU Affero General Public
-- License, version 3 or any later version. See `bookfusion.koplugin/LICENSE`.

local Epub = {}
Epub.__index = Epub
local ok_log, Log = pcall(require, "st_log")
if not ok_log then
    Log = nil
end

local VOID_ELEMENTS = {
    area = true, base = true, br = true, col = true, embed = true,
    hr = true, img = true, input = true, link = true, meta = true,
    param = true, source = true, track = true, wbr = true,
}

function Epub.codepointToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp % 4096 / 64),
            0x80 + (cp % 64)
        )
    elseif cp < 0x110000 then
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + math.floor(cp % 262144 / 4096),
            0x80 + math.floor(cp % 4096 / 64),
            0x80 + (cp % 64)
        )
    end
    return ""
end

function Epub.utf16len(str)
    if not str then return 0 end
    local len = 0
    local i = 1
    local bytes = #str
    while i <= bytes do
        local b = str:byte(i)
        if b < 0x80 then
            i = i + 1
            len = len + 1
        elseif b < 0xE0 then
            i = i + 2
            len = len + 1
        elseif b < 0xF0 then
            i = i + 3
            len = len + 1
        else
            i = i + 4
            len = len + 2
        end
    end
    return len
end

function Epub.decodeEntities(text)
    if not text then return "" end
    text = text:gsub("&#x(%x+);", function(hex)
        return Epub.codepointToUtf8(tonumber(hex, 16))
    end)
    text = text:gsub("&#(%d+);", function(dec)
        return Epub.codepointToUtf8(tonumber(dec))
    end)
    local named = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
        nbsp = "\xC2\xA0",
        mdash = "\xE2\x80\x94", ndash = "\xE2\x80\x93",
        lsquo = "\xE2\x80\x98", rsquo = "\xE2\x80\x99",
        ldquo = "\xE2\x80\x9C", rdquo = "\xE2\x80\x9D",
        hellip = "\xE2\x80\xA6",
    }
    text = text:gsub("&(%a+);", function(name)
        return named[name] or ("&" .. name .. ";")
    end)
    return text
end

function Epub.parseHtml(html)
    local root = { tag = "root", children = {} }
    local stack = { root }
    local pos = 1
    local len = #html

    while pos <= len do
        local tag_start = html:find("<", pos, true)
        if not tag_start then
            local text = html:sub(pos)
            if #text > 0 then
                table.insert(stack[#stack].children, { text = Epub.decodeEntities(text) })
            end
            break
        end

        if tag_start > pos then
            local text = html:sub(pos, tag_start - 1)
            if #text > 0 then
                table.insert(stack[#stack].children, { text = Epub.decodeEntities(text) })
            end
        end

        local c = html:byte(tag_start + 1)
        if c == 33 then
            if html:sub(tag_start, tag_start + 3) == "<!--" then
                local close = html:find("-->", tag_start + 4, true)
                pos = close and (close + 3) or (len + 1)
            else
                local close = html:find(">", tag_start + 1, true)
                pos = close and (close + 1) or (len + 1)
            end
        elseif c == 63 then
            local close = html:find("?>", tag_start + 2, true)
            pos = close and (close + 2) or (len + 1)
        elseif c == 47 then
            local close = html:find(">", tag_start + 2, true)
            if close and #stack > 1 then
                table.remove(stack)
            end
            pos = close and (close + 1) or (len + 1)
        else
            local close = html:find(">", tag_start + 1, true)
            if close then
                local content = html:sub(tag_start + 1, close - 1)
                local self_closing = content:sub(-1) == "/"
                if self_closing then
                    content = content:sub(1, -2)
                end
                local tag_name = content:match("^(%S+)")
                if tag_name then
                    local local_name = (tag_name:match(":(.+)") or tag_name):lower()
                    local attrs = content:sub(#tag_name + 1)
                    local elem = { tag = local_name, children = {} }
                    elem.id = attrs:match('%sid="([^"]+)"')
                        or attrs:match("^id=\"([^\"]+)\"")
                        or attrs:match("%sid='([^']+)'")
                        or attrs:match("^id='([^']+)'")
                    table.insert(stack[#stack].children, elem)
                    if not self_closing and not VOID_ELEMENTS[local_name] then
                        table.insert(stack, elem)
                    end
                end
                pos = close + 1
            else
                pos = len + 1
            end
        end
    end

    return root
end

function Epub.findBody(dom)
    for _, child in ipairs(dom.children or {}) do
        if child.tag == "body" then
            return child
        end
        if child.children then
            local body = Epub.findBody(child)
            if body then return body end
        end
    end
    return nil
end

function Epub.parseXPath(path)
    local steps = {}
    local text_offset = nil
    local text_node_index = nil

    if type(path) ~= "string" or path == "" then
        return steps, text_offset, text_node_index
    end

    for part in path:gmatch("[^/]+") do
        local elem_name, elem_idx, elem_off = part:match("^([%a_][%w_%-]*)%[(%d+)%]%.(%d+)$")
        if elem_name then
            table.insert(steps, { name = elem_name:lower(), index = tonumber(elem_idx) })
            text_offset = tonumber(elem_off)
        else
            local elem_name_no_idx, elem_off_no_idx = part:match("^([%a_][%w_%-]*)%.(%d+)$")
            if elem_name_no_idx then
                table.insert(steps, { name = elem_name_no_idx:lower(), index = 1 })
                text_offset = tonumber(elem_off_no_idx)
            else
        local tn_idx, tn_off = part:match("^text%(%)%[(%d+)%]%.(%d+)$")
        if tn_idx then
            text_node_index = tonumber(tn_idx)
            text_offset = tonumber(tn_off)
        else
            local text_off = part:match("^text%(%)%.(%d+)$")
            if text_off then
                text_offset = tonumber(text_off)
            elseif part == "text()" then
                text_offset = 0
            else
                local name, idx = part:match("^([%a_][%w_%-]*)%[(%d+)%]$")
                if not name then
                    name = part:match("^([%a_][%w_%-]*)$")
                    idx = 1
                else
                    idx = tonumber(idx)
                end
                if name then
                    table.insert(steps, { name = name:lower(), index = idx })
                end
            end
        end
            end
        end
    end

    return steps, text_offset, text_node_index
end

function Epub.isInterElementWhitespace(node, parent)
    if not node.text then return false end
    if not parent or not parent.children then return false end
    if not node.text:match("^%s+$") then return false end
    for _, sibling in ipairs(parent.children) do
        if sibling.tag then return true end
    end
    return false
end

function Epub.textLength(node)
    if node.text then
        return Epub.utf16len(node.text)
    end
    local total = 0
    for _, child in ipairs(node.children or {}) do
        total = total + Epub.textLength(child)
    end
    return total
end

function Epub.xpointerToOffset(html, xpath)
    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then return nil end

    local steps, text_offset, text_node_index = Epub.parseXPath(xpath)
    if #steps == 0 then return text_offset or 0 end

    local offset = 0
    local current = body
    for _, step in ipairs(steps) do
        local target = nil
        local count = 0
        for _, child in ipairs(current.children) do
            if child.tag == step.name then
                count = count + 1
                if count == step.index then
                    target = child
                    break
                end
            end
            offset = offset + Epub.textLength(child)
        end
        if not target then return nil end
        current = target
    end

    if text_offset then
        if text_node_index then
            local tn_count = 0
            for _, child in ipairs(current.children) do
                if child.text then
                    tn_count = tn_count + 1
                    if tn_count == text_node_index then
                        offset = offset + text_offset
                        break
                    else
                        offset = offset + Epub.utf16len(child.text)
                    end
                else
                    offset = offset + Epub.textLength(child)
                end
            end
        else
            offset = offset + text_offset
        end
    end

    return offset
end

function Epub.offsetToXPath(html, target_offset)
    if not target_offset or target_offset < 0 then return nil end

    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then return nil end

    local path_parts = {}

    local function search(node, remaining)
        for i, child in ipairs(node.children) do
            if child.text then
                local text_len = Epub.utf16len(child.text)
                if Epub.isInterElementWhitespace(child, node) then
                    if remaining < text_len then
                        remaining = 0
                    else
                        remaining = remaining - text_len
                    end
                elseif remaining < text_len then
                    local tn_index = 0
                    for j = 1, #node.children do
                        if node.children[j].text
                                and not Epub.isInterElementWhitespace(node.children[j], node) then
                            tn_index = tn_index + 1
                        end
                        if j == i then break end
                    end
                    table.insert(path_parts, "text()[" .. tn_index .. "]." .. remaining)
                    return true
                else
                    remaining = remaining - text_len
                end
            elseif child.tag then
                local subtree_len = Epub.textLength(child)
                if remaining < subtree_len then
                    local same_name_idx = 0
                    for j = 1, #node.children do
                        if node.children[j].tag == child.tag then
                            same_name_idx = same_name_idx + 1
                        end
                        if node.children[j] == child then break end
                    end
                    table.insert(path_parts, child.tag .. "[" .. same_name_idx .. "]")
                    return search(child, remaining)
                end
                remaining = remaining - subtree_len
            end
        end
        return false
    end

    if search(body, target_offset) then
        return table.concat(path_parts, "/")
    end

    if target_offset > 0 and target_offset == Epub.textLength(body) then
        path_parts = {}
        local function findLast(node)
            for i = #node.children, 1, -1 do
                local child = node.children[i]
                if child.text and Epub.utf16len(child.text) > 0 then
                    local tn_index = 0
                    for j = 1, #node.children do
                        if node.children[j].text then tn_index = tn_index + 1 end
                        if j == i then break end
                    end
                    table.insert(path_parts, "text()[" .. tn_index .. "]." .. Epub.utf16len(child.text))
                    return true
                elseif child.tag and Epub.textLength(child) > 0 then
                    local same_name_idx = 0
                    for j = 1, #node.children do
                        if node.children[j].tag == child.tag then same_name_idx = same_name_idx + 1 end
                        if node.children[j] == child then break end
                    end
                    table.insert(path_parts, child.tag .. "[" .. same_name_idx .. "]")
                    return findLast(child)
                end
            end
            return false
        end
        if findLast(body) then
            return table.concat(path_parts, "/")
        end
    end

    return nil
end

function Epub.cfiToXPath(html, cfi_steps)
    local dom = Epub.parseHtml(html)
    local html_elem = nil
    for _, child in ipairs(dom.children) do
        if child.tag == "html" then
            html_elem = child
            break
        end
    end
    if not html_elem then return nil end

    local current = html_elem
    local xpath_parts = {}
    local past_body = false

    for step_str in cfi_steps:gmatch("[^/]+") do
        local clean = step_str:gsub("%[[^%]]*%]", "")
        local step_num_str, char_offset_str = clean:match("^(%d+):(%d+)$")
        local step_num = tonumber(step_num_str or clean:match("^(%d+)$"))
        if not step_num then break end

        if step_num % 2 == 0 then
            local elem_index = math.floor(step_num / 2)
            local elem_count = 0
            local target = nil
            for _, child in ipairs(current.children) do
                if child.tag then
                    elem_count = elem_count + 1
                    if elem_count == elem_index then
                        target = child
                        break
                    end
                end
            end
            if not target then return nil end

            if target.tag == "body" then
                past_body = true
            elseif past_body then
                local same_name_idx = 0
                for _, child in ipairs(current.children) do
                    if child.tag == target.tag then
                        same_name_idx = same_name_idx + 1
                    end
                    if child == target then break end
                end
                table.insert(xpath_parts, target.tag .. "[" .. same_name_idx .. "]")
                if char_offset_str then
                    table.insert(xpath_parts, "text()." .. char_offset_str)
                    break
                end
            end
            current = target
        else
            if past_body then
                local text_node_index = math.floor((step_num + 1) / 2)
                local char_offset = char_offset_str or "0"
                table.insert(xpath_parts, "text()[" .. text_node_index .. "]." .. char_offset)
            end
            break
        end
    end

    if #xpath_parts == 0 then return nil end
    return table.concat(xpath_parts, "/")
end

function Epub.getOpfPath(container_xml)
    return container_xml:match('<rootfile[^>]+full%-path="([^"]+)"')
end

function Epub.getManifestItems(opf_xml, opf_dir)
    opf_dir = opf_dir or ""
    local manifest = {}
    for attrs in opf_xml:gmatch("<item([^>]+)>") do
        local id = attrs:match('id="([^"]+)"')
        local href = attrs:match('href="([^"]+)"')
        if id and href then
            href = href:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            href = Epub.decodeEntities(href)
            manifest[id] = {
                id = id,
                href = href,
                path = opf_dir .. href,
                media_overlay = attrs:match('media%-overlay="([^"]+)"'),
                media_type = attrs:match('media%-type="([^"]+)"'),
            }
        end
    end
    return manifest
end

function Epub.getSpineItems(opf_xml, opf_dir)
    local manifest = Epub.getManifestItems(opf_xml, opf_dir)
    local spine = {}
    for idref in opf_xml:gmatch('<itemref[^>]+idref="([^"]+)"') do
        local item = manifest[idref]
        if item then
            table.insert(spine, {
                id = item.id,
                href = item.href,
                path = item.path,
                media_overlay = item.media_overlay,
                media_type = item.media_type,
            })
        end
    end

    return spine
end

function Epub.getOverlayIdsFromSmil(smil_xml, chapter_targets)
    local ids = {}
    if type(smil_xml) ~= "string" or smil_xml == "" then
        return ids
    end

    for attrs in smil_xml:gmatch("<text([^>]+)>") do
        local src = attrs:match('src="([^"]+)"')
        if src then
            src = src:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            src = Epub.decodeEntities(src)
            local href, fragment = src:match("^([^#]+)#(.+)$")
            if href and fragment then
                local normalized = Epub.normalizeHref(Epub, href)
                if chapter_targets[normalized] then
                    ids[fragment] = true
                end
            end
        end
    end

    return ids
end

function Epub.getSpineCfiStep(opf_xml)
    local pkg_content = opf_xml:match("<package[^>]*>(.*)</package>")
    if not pkg_content then return 6 end

    local depth = 0
    local elem_index = 0
    for tag in pkg_content:gmatch("<([^>]+)>") do
        if tag:sub(1, 1) == "/" then
            depth = depth - 1
        elseif tag:sub(-1) == "/" then
            if depth == 0 then
                elem_index = elem_index + 1
                local tag_name = tag:match("^(%S+)")
                local base_name = (tag_name:match(":(.+)") or tag_name):lower()
                if base_name == "spine" then
                    return elem_index * 2
                end
            end
        elseif not tag:match("^[?!]") then
            if depth == 0 then
                elem_index = elem_index + 1
                local tag_name = tag:match("^(%S+)")
                local base_name = (tag_name:match(":(.+)") or tag_name):lower()
                if base_name == "spine" then
                    return elem_index * 2
                end
            end
            depth = depth + 1
        end
    end
    return 6
end

function Epub.parseXPointer(xpointer)
    local frag_idx = xpointer:match("DocFragment%[(%d+)%]")
    if frag_idx then
        frag_idx = tonumber(frag_idx)
        local element_path = xpointer:match("DocFragment%[%d+%]/body/(.*)")
        return frag_idx, element_path
    end
    if xpointer:match("DocFragment/") then
        local element_path = xpointer:match("DocFragment/body/(.*)")
        return 1, element_path
    end
    return nil, nil
end

function Epub:new(document)
    return setmetatable({
        _document = document,
    }, self)
end

function Epub:loadSpineData()
    if self._spine_items then return true end

    local ok, container_xml = pcall(self._document.getDocumentFileContent, self._document, "META-INF/container.xml")
    if not ok or not container_xml then return false end

    local opf_path = Epub.getOpfPath(container_xml)
    if not opf_path then return false end

    local ok2, opf_xml = pcall(self._document.getDocumentFileContent, self._document, opf_path)
    if not ok2 or not opf_xml then return false end

    local opf_dir = opf_path:match("(.*/)") or ""
    local manifest = Epub.getManifestItems(opf_xml, opf_dir)
    self._spine_items = Epub.getSpineItems(opf_xml, opf_dir)
    self._spine_cfi_step = Epub.getSpineCfiStep(opf_xml)
    self._overlay_ids_by_path = {}
    for _, item in ipairs(self._spine_items or {}) do
        if item.media_overlay and manifest[item.media_overlay] then
            local smil_item = manifest[item.media_overlay]
            local ok_smil, smil_xml = pcall(
                self._document.getDocumentFileContent,
                self._document,
                smil_item.path
            )
            if ok_smil and smil_xml then
                local chapter_targets = {}
                local normalized_href = self:normalizeHref(item.href)
                local normalized_path = self:normalizeHref(item.path)
                if normalized_href then chapter_targets[normalized_href] = true end
                if normalized_path then chapter_targets[normalized_path] = true end
                self._overlay_ids_by_path[normalized_path or item.path] =
                    Epub.getOverlayIdsFromSmil(smil_xml, chapter_targets)
            elseif Log then
                Log:warn("epub_overlay_smil_load_failed", {
                    chapter_item = item,
                    smil_item = smil_item,
                })
            end
        end
    end
    if Log then
        Log:info("epub_spine_loaded", {
            opf_path = opf_path,
            opf_dir = opf_dir,
            spine_count = self._spine_items and #self._spine_items or 0,
            first_spine = self._spine_items and self._spine_items[1] or nil,
            last_spine = self._spine_items and self._spine_items[#self._spine_items] or nil,
            overlay_chapter_count = self._overlay_ids_by_path and (function()
                local count = 0
                for _ in pairs(self._overlay_ids_by_path) do
                    count = count + 1
                end
                return count
            end)() or 0,
        })
    end
    return true
end

function Epub:getChapterHtml(frag_idx)
    if not self:loadSpineData() then return nil end
    local spine_item = self._spine_items[frag_idx]
    if not spine_item then return nil end

    if not self._chapter_cache then
        self._chapter_cache = {}
    end
    if not self._chapter_cache[frag_idx] then
        local ok, html = pcall(self._document.getDocumentFileContent, self._document, spine_item.path)
        if not ok or not html then return nil end
        self._chapter_cache[frag_idx] = html
    end
    return self._chapter_cache[frag_idx]
end

function Epub:normalizeHref(href)
    if type(href) ~= "string" or href == "" then
        return nil
    end
    href = href:gsub("^/", "")
    href = href:gsub("#.*$", "")
    href = href:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return href
end

function Epub:getSpineHref(chapter_index)
    if not self:loadSpineData() then return nil end
    local item = self._spine_items[(chapter_index or 0) + 1]
    return item and item.href or nil
end

function Epub:getSpinePath(chapter_index)
    if not self:loadSpineData() then return nil end
    local item = self._spine_items[(chapter_index or 0) + 1]
    return item and item.path or nil
end

function Epub:getChapterIndexByHref(href)
    if not self:loadSpineData() then return nil end
    local target = self:normalizeHref(href)
    if not target then return nil end

    for idx, item in ipairs(self._spine_items) do
        local item_href = self:normalizeHref(item.href)
        local item_path = self:normalizeHref(item.path)
        if item_href == target or item_path == target then
            if Log then
                Log:info("epub_href_match_exact", {
                    requested_href = href,
                    normalized_href = target,
                    chapter_index = idx - 1,
                    item = item,
                })
            end
            return idx - 1
        end
    end

    for idx, item in ipairs(self._spine_items) do
        local item_href = self:normalizeHref(item.href) or ""
        local item_path = self:normalizeHref(item.path) or ""
        if item_href:sub(-#target) == target or item_path:sub(-#target) == target then
            if Log then
                Log:info("epub_href_match_suffix", {
                    requested_href = href,
                    normalized_href = target,
                    chapter_index = idx - 1,
                    item = item,
                })
            end
            return idx - 1
        end
    end

    if Log then
        Log:warn("epub_href_match_failed", {
            requested_href = href,
            normalized_href = target,
            spine_count = self._spine_items and #self._spine_items or 0,
        })
    end
    return nil
end

function Epub:buildCfi(xpointer)
    if type(xpointer) ~= "string" or xpointer == "" then return nil end
    if not self:loadSpineData() then return nil end
    local frag_idx, xpath = Epub.parseXPointer(xpointer)
    if not frag_idx or not xpath then return nil end
    local html = self:getChapterHtml(frag_idx)
    if not html then return nil end
    local item_step = frag_idx * 2
    local cfi_after = nil
    do
        local dom = Epub.parseHtml(html)
        local html_elem = nil
        for _, child in ipairs(dom.children) do
            if child.tag == "html" then
                html_elem = child
                break
            end
        end
        if not html_elem then return nil end
        local body = nil
        local elem_count = 0
        for _, child in ipairs(html_elem.children) do
            if child.tag then
                elem_count = elem_count + 1
                if child.tag == "body" then
                    body = child
                    break
                end
            end
        end
        if not body then return nil end
        local steps, text_offset, text_node_index = Epub.parseXPath(xpath)
        local cfi_parts = { tostring(elem_count * 2) }
        local current = body
        for _, step in ipairs(steps) do
            local target = nil
            local name_count = 0
            for _, child in ipairs(current.children) do
                if child.tag == step.name then
                    name_count = name_count + 1
                    if name_count == step.index then
                        target = child
                        break
                    end
                end
            end
            if not target then return nil end
            local abs_elem_count = 0
            for _, child in ipairs(current.children) do
                if child.tag then
                    abs_elem_count = abs_elem_count + 1
                end
                if child == target then break end
            end
            table.insert(cfi_parts, tostring(abs_elem_count * 2))
            current = target
        end
        if text_offset then
            local target_tn = text_node_index or 1
            local elem_before = 0
            local tn_count = 0
            for _, child in ipairs(current.children) do
                if child.tag then
                    elem_before = elem_before + 1
                elseif child.text then
                    tn_count = tn_count + 1
                    if tn_count == target_tn then
                        table.insert(cfi_parts, tostring(elem_before * 2 + 1) .. ":" .. text_offset)
                        break
                    end
                end
            end
        end
        cfi_after = "/" .. table.concat(cfi_parts, "/")
    end
    if not cfi_after then return nil end
    return "epubcfi(/" .. self._spine_cfi_step .. "/" .. item_step .. "!" .. cfi_after .. ")"
end

function Epub:resolveCfi(cfi)
    if type(cfi) ~= "string" or cfi == "" then return nil end
    local inner = cfi:match("^epubcfi%((.+)%)$")
    if not inner then return nil end

    local spine_part, after_indirection = inner:match("^/%d+/(%d+[^!]*)!/(.*)")
    if not spine_part then return nil end
    local spine_step = tonumber(spine_part:match("^(%d+)"))
    if not spine_step then return nil end
    local doc_frag_idx = math.floor(spine_step / 2)

    local chapter_html = self:getChapterHtml(doc_frag_idx)
    if not chapter_html then return nil end
    local xpath = Epub.cfiToXPath(chapter_html, after_indirection)
    if not xpath then return nil end

    return "/body/DocFragment[" .. doc_frag_idx .. "]/body/" .. xpath
end

function Epub:resolveXPointers(chapter_index, start_offset, end_offset)
    local ok_logger, logger = pcall(require, "logger")
    if not ok_logger then logger = { dbg = function() end, warn = function() end } end
    local frag_idx = chapter_index + 1
    local html = self:getChapterHtml(frag_idx)
    if not html then return nil end

    local xpath0 = Epub.offsetToXPath(html, start_offset)
    if not xpath0 then return nil end

    local pos0 = "/body/DocFragment[" .. frag_idx .. "]/body/" .. xpath0
    local pos1 = nil
    if end_offset then
        local xpath1 = Epub.offsetToXPath(html, end_offset)
        if xpath1 then
            pos1 = "/body/DocFragment[" .. frag_idx .. "]/body/" .. xpath1
        end
    end

    if self._document and self._document.getNormalizedXPointer then
        local ok0, norm0 = pcall(self._document.getNormalizedXPointer, self._document, pos0)
        if not ok0 or norm0 == false then
            logger.warn("Storyteller: CRE cannot resolve pos0:", pos0)
            return nil
        end
        pos0 = norm0
        if pos1 then
            local ok1, norm1 = pcall(self._document.getNormalizedXPointer, self._document, pos1)
            if ok1 and norm1 ~= false then
                pos1 = norm1
            else
                pos1 = nil
            end
        end
    end

    return pos0, pos1
end

function Epub:getSpinePosition(xpointer)
    if type(xpointer) ~= "string" or xpointer == "" then return nil end
    if not self:loadSpineData() then return nil end
    local frag_idx = Epub.parseXPointer(xpointer)
    if not frag_idx then return nil end
    return frag_idx - 1, #self._spine_items
end

function Epub:getPositionInChapter(xpointer)
    if type(xpointer) ~= "string" or xpointer == "" then return nil end
    local frag_idx, xpath = Epub.parseXPointer(xpointer)
    if not frag_idx then return nil end
    local html = self:getChapterHtml(frag_idx)
    if not html then return nil end
    local current_offset = Epub.xpointerToOffset(html, xpath)
    if not current_offset then return nil end
    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then return nil end
    local total = Epub.textLength(body)
    if total == 0 then return 0 end
    return current_offset / total
end

function Epub:getFragmentForXPointer(xpointer)
    if type(xpointer) ~= "string" or xpointer == "" then
        return nil
    end

    local frag_idx, xpath = Epub.parseXPointer(xpointer)
    if not frag_idx or not xpath then
        return nil
    end

    local html = self:getChapterHtml(frag_idx)
    if not html then
        return nil
    end

    local current_offset = Epub.xpointerToOffset(html, xpath)
    if current_offset == nil then
        if Log then
            Log:warn("epub_fragment_for_xpointer_missing_offset", {
                xpointer = xpointer,
                chapter_index = frag_idx - 1,
            })
        end
        return nil
    end

    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then
        return nil
    end

    local spine_item = self._spine_items and self._spine_items[frag_idx] or nil
    local overlay_ids = nil
    if spine_item and self._overlay_ids_by_path then
        overlay_ids = self._overlay_ids_by_path[self:normalizeHref(spine_item.path) or spine_item.path]
    end

    local fragments = {}
    local function collect(node, offset)
        for _, child in ipairs(node.children or {}) do
            if child.text then
                offset = offset + Epub.textLength(child)
            elseif child.tag then
                if child.id and (not overlay_ids or overlay_ids[child.id]) then
                    table.insert(fragments, {
                        id = child.id,
                        offset = offset,
                    })
                end
                offset = collect(child, offset)
            end
        end
        return offset
    end

    collect(body, 0)

    if #fragments == 0 then
        if overlay_ids then
            overlay_ids = nil
            collect(body, 0)
        end
    end

    if #fragments == 0 then
        if Log then
            Log:warn("epub_fragment_for_xpointer_no_ids", {
                xpointer = xpointer,
                chapter_index = frag_idx - 1,
                used_overlay_filter = spine_item and self._overlay_ids_by_path
                    and self._overlay_ids_by_path[self:normalizeHref(spine_item.path) or spine_item.path]
                    ~= nil or false,
            })
        end
        return nil
    end

    local best = nil
    for _, fragment in ipairs(fragments) do
        if fragment.offset <= current_offset then
            best = fragment
        else
            break
        end
    end

    if not best then
        best = fragments[1]
    end

    if Log then
        Log:info("epub_fragment_for_xpointer", {
            xpointer = xpointer,
            chapter_index = frag_idx - 1,
            current_offset = current_offset,
            fragment = best and best.id or nil,
            fragment_offset = best and best.offset or nil,
            used_overlay_filter = overlay_ids ~= nil,
        })
    end

    return best and best.id or nil
end

function Epub:getChapterStartXPointer(href)
    local chapter_index = self:getChapterIndexByHref(href)
    if chapter_index == nil then
        if Log then
            Log:warn("epub_chapter_start_missing_chapter", { href = href })
        end
        return nil
    end
    local html = self:getChapterHtml(chapter_index + 1)
    if not html then
        return nil
    end

    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then
        return nil
    end

    local total = Epub.textLength(body)
    if total > 0 then
        local target = self:resolveXPointers(chapter_index, 0)
        if Log then
            Log:info("epub_chapter_start_xpointer", {
                href = href,
                chapter_index = chapter_index,
                target = target,
            })
        end
        return target
    end

    return "/body/DocFragment[" .. (chapter_index + 1) .. "]/body"
end

function Epub:getXPointerFromHrefAndFragment(href, fragment)
    if type(fragment) ~= "string" or fragment == "" then
        return nil
    end

    local chapter_index = self:getChapterIndexByHref(href)
    if chapter_index == nil then
        return nil
    end

    local html = self:getChapterHtml(chapter_index + 1)
    if not html then
        return nil
    end

    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then
        return nil
    end

    local function findOffset(node, target_id, offset)
        offset = offset or 0
        for _, child in ipairs(node.children or {}) do
            if child.text then
                offset = offset + Epub.textLength(child)
            elseif child.tag then
                if child.id == target_id then
                    return offset
                end
                local found_offset = findOffset(child, target_id, offset)
                if found_offset ~= nil then
                    return found_offset
                end
                offset = offset + Epub.textLength(child)
            end
        end
        return nil
    end

    local offset = findOffset(body, fragment, 0)
    if offset ~= nil then
        local xpointer = self:resolveXPointers(chapter_index, offset)
        if xpointer then
            if Log then
                Log:info("epub_fragment_resolved", {
                    href = href,
                    fragment = fragment,
                    chapter_index = chapter_index,
                    offset = offset,
                    target = xpointer,
                })
            end
            return xpointer
        end
    end

    if Log then
        Log:warn("epub_fragment_resolve_failed", {
            href = href,
            fragment = fragment,
            chapter_index = chapter_index,
            found_offset = offset,
        })
    end
    return self:getChapterStartXPointer(href)
end

function Epub:getXPointerFromHrefAndProgression(href, progression)
    local chapter_index = self:getChapterIndexByHref(href)
    if chapter_index == nil then
        if Log then
            Log:warn("epub_progression_missing_chapter", {
                href = href,
                progression = progression,
            })
        end
        return nil
    end
    local html = self:getChapterHtml(chapter_index + 1)
    if not html then
        return nil
    end
    local dom = Epub.parseHtml(html)
    local body = Epub.findBody(dom)
    if not body then
        return nil
    end
    local total = Epub.textLength(body)
    if total == 0 then
        return self:getChapterStartXPointer(href)
    end
    local pct = tonumber(progression) or 0
    if pct < 0 then pct = 0 end
    if pct > 1 then pct = 1 end
    local offset = math.floor(total * pct)
    local pos0 = self:resolveXPointers(chapter_index, offset)
    if Log then
        Log:info("epub_progression_resolved", {
            href = href,
            progression = progression,
            chapter_index = chapter_index,
            chapter_text_length = total,
            offset = offset,
            target = pos0,
        })
    end
    return pos0
end

return Epub
