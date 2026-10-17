-- Chapters: chapter detection and spoiler-safe text extraction.
-- Approach adapted from xray.koplugin (ultimatejimmy): flatten the TOC,
-- locate the chapter containing the current page, and extract its text.

local Chapters = {}

-- Flatten KOReader's nested TOC tree into a plain ordered list.
local function flattenTOC(nodes, flat_list)
    flat_list = flat_list or {}
    if not nodes then return flat_list end
    for _, node in ipairs(nodes) do
        if type(node) == "table" then
            table.insert(flat_list, node)
            if #node > 0 then
                flattenTOC(node, flat_list)
            elseif node.sub_item_table then
                flattenTOC(node.sub_item_table, flat_list)
            elseif node.children then
                flattenTOC(node.children, flat_list)
            end
        end
    end
    return flat_list
end

-- Current reading position (page number), across reflowable and paged docs.
function Chapters.getCurrentPage(ui)
    if ui.rolling then
        local ok, p = pcall(function()
            if ui.rolling.current_page then return ui.rolling.current_page end
            if ui.rolling.getCurrentPos then return ui.rolling:getCurrentPos() end
        end)
        if ok and p and tonumber(p) then return tonumber(p) end
    end
    if ui.paging then
        local ok, p = pcall(function() return ui.paging.current_page end)
        if ok and p and tonumber(p) then return tonumber(p) end
    end
    return 1
end

-- Ordered list of chapter nodes that have page numbers.
function Chapters.getChapterList(ui)
    local ok, raw_toc = pcall(function() return ui.document:getToc() end)
    if not ok or not raw_toc then return {} end
    local flat = {}
    for _, node in ipairs(flattenTOC(raw_toc)) do
        if type(node) == "table" and tonumber(node.page) then
            table.insert(flat, node)
        end
    end
    return flat
end

function Chapters.findNodeByTitle(ui, title)
    local list = Chapters.getChapterList(ui)
    for i, node in ipairs(list) do
        if node.title == title then
            return node, list[i + 1]
        end
    end
    return nil
end

-- Find the chapter for "current" or "previous".
-- Returns: index, chapter_node, next_chapter_node (or nils when no TOC).
function Chapters.findChapter(ui, which)
    local flat = Chapters.getChapterList(ui)
    if #flat == 0 then return nil end
    local pos = Chapters.getCurrentPage(ui)
    local idx = 1
    for i, node in ipairs(flat) do
        if tonumber(node.page) <= pos then idx = i end
    end
    if which == "previous" then idx = math.max(1, idx - 1) end
    return idx, flat[idx], flat[idx + 1]
end

-- Cut a string to max_bytes without splitting a UTF-8 code point.
local function safeByteCut(s, max_bytes)
    if #s <= max_bytes then return s end
    local cut = max_bytes
    while cut > 0 do
        local b = s:byte(cut)
        if b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- Take the last max_bytes of a string without splitting a UTF-8 code point.
local function safeByteTail(s, max_bytes)
    if #s <= max_bytes then return s end
    local start = #s - max_bytes + 1
    while start <= #s do
        local b = s:byte(start)
        if b < 0x80 or b >= 0xC0 then break end
        start = start + 1
    end
    return s:sub(start)
end

-- Shrink long text to a byte budget, keeping the beginning and the end.
local function fitBudget(text, max_bytes)
    if #text <= max_bytes then return text end
    local head = safeByteCut(text, math.floor(max_bytes * 0.55))
    local tail = safeByteTail(text, math.floor(max_bytes * 0.40))
    return head .. "\n\n[...text omitted...]\n\n" .. tail
end

function Chapters.getBookInfo(ui)
    local title, author
    pcall(function()
        local props = ui.doc_props
        if props then title, author = props.title, props.authors end
    end)
    if not title then
        pcall(function()
            local props = ui.document:getProps()
            if props then title, author = props.title, props.authors end
        end)
    end
    return {
        title = title or "Unknown book",
        author = author or "Unknown author",
    }
end

-- Extract chapter text, never including content past the reader's position.
-- budget caps the returned bytes (default 12000).
function Chapters.getChapterText(ui, chapter, next_chapter, which, budget)
    local text = ""
    local is_reflowable = ui.rolling ~= nil
    local current_page = Chapters.getCurrentPage(ui)

    if is_reflowable then
        if ui.document.getTextFromXPointer and chapter.xpointer then
            local ok, res = pcall(function()
                return ui.document:getTextFromXPointer(chapter.xpointer)
            end)
            if ok and res and #res > 100 then text = res end
        end
        if #text < 100 and ui.document.getTextFromPositions then
            local ok, res = pcall(function()
                return ui.document:getTextFromPositions(current_page, current_page + 200)
            end)
            if ok and res and #res > 100 then text = res end
        end
        -- Spoiler guard: for the chapter being read, keep only the fraction
        -- of the text corresponding to the fraction of the chapter read.
        if which == "current" and #text > 0 then
            local start_p = tonumber(chapter.page) or 1
            local end_p = (next_chapter and tonumber(next_chapter.page))
                or (current_page + 40)
            if end_p > start_p then
                local frac = (current_page - start_p + 1) / (end_p - start_p)
                frac = math.max(0.05, math.min(1, frac))
                text = safeByteCut(text, math.floor(#text * frac))
            end
        end
    else
        -- Page-based documents (PDF, DjVu, ...): extract page by page.
        local start_p = tonumber(chapter.page) or 1
        local end_p
        if which == "current" then
            end_p = current_page
        else
            end_p = (next_chapter and (tonumber(next_chapter.page) - 1)) or current_page
        end
        end_p = math.max(start_p, end_p)
        if ui.document.getPageText then
            local parts = {}
            for p = start_p, end_p do
                local ok, t = pcall(function() return ui.document:getPageText(p) end)
                if ok and t and t ~= "" then table.insert(parts, t) end
                if #parts > 80 then break end -- sanity cap
            end
            text = table.concat(parts, "\n")
        end
    end

    text = text:gsub("\r", " ")
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return fitBudget(text, budget or 12000)
end

-- Index of the chapter with this title in the flattened chapter list.
function Chapters.findIndexByTitle(ui, title)
    local list = Chapters.getChapterList(ui)
    for i, node in ipairs(list) do
        if node.title == title then return i end
    end
    return nil
end

-- Spoiler-safe text for a chapter range (a reading session): concatenates
-- each chapter's text under a chapter header. Only finished chapters should
-- be included; callers enforce that. per_chapter_budget caps each chapter's
-- contribution (default 8000), total capped at total_budget (default 30000).
-- When cur_idx is given, that chapter is treated as "current" (only text up
-- to the reading position is used); all others are "previous".
function Chapters.getRangeText(ui, from_idx, to_idx, per_chapter_budget,
    total_budget, cur_idx)
    per_chapter_budget = per_chapter_budget or 8000
    total_budget = total_budget or 30000
    local flat = Chapters.getChapterList(ui)
    if #flat == 0 then return "" end
    from_idx = math.max(1, from_idx or 1)
    to_idx = math.min(#flat, to_idx or #flat)
    if from_idx > to_idx then return "" end
    local parts = {}
    for i = from_idx, to_idx do
        local node = flat[i]
        local which = (cur_idx and i == cur_idx) and "current" or "previous"
        local ok, text = pcall(Chapters.getChapterText, ui, node, flat[i + 1],
            which, per_chapter_budget)
        if ok and text and #text >= 50 then
            table.insert(parts, "--- Chapter: "
                .. tostring(node.title or ("#" .. i)) .. " ---\n" .. text)
        end
    end
    if #parts == 0 then return "" end
    return fitBudget(table.concat(parts, "\n\n"), total_budget)
end

-- Whole-book text for the end-of-book reflection: samples every chapter so
-- the model sees the full arc. Larger budget than a session, still bounded
-- for the reader's memory and upload time.
function Chapters.getWholeBookText(ui)
    local flat = Chapters.getChapterList(ui)
    if #flat == 0 then return "" end
    return Chapters.getRangeText(ui, 1, #flat, 2000, 50000)
end

return Chapters
