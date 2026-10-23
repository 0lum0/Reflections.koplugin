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

-- Total page count of the open document (0 when unknown).
function Chapters.getPageCount(ui)
    local ok, n = pcall(function()
        if ui.document and ui.document.getPageCount then
            return ui.document:getPageCount()
        end
    end)
    if ok and n and tonumber(n) and tonumber(n) > 0 then return tonumber(n) end
    return 0
end

-- Text for pages [start_p, end_p] in a reflowable document.
-- NOTE: ui.document:getTextFromPositions() takes on-screen positions, NOT
-- page numbers, on real devices, so page boundaries are converted through
-- getPageXPointer() and read with getTextFromXPointers() instead.
local function reflowablePageRangeText(ui, start_p, end_p)
    local doc = ui.document
    if not (doc and doc.getPageXPointer and doc.getTextFromXPointers) then
        return nil
    end
    local page_count = Chapters.getPageCount(ui)
    local ok0, xp0 = pcall(function() return doc:getPageXPointer(start_p) end)
    if not ok0 or type(xp0) ~= "string" or xp0 == "" then return nil end
    -- The range end is exclusive: use the start of the page after end_p.
    -- When end_p is the last page, end at the live reading position instead
    -- (callers guarantee end_p never passes the reading position then).
    local xp1
    if page_count > 0 and end_p < page_count then
        local ok1, x = pcall(function()
            return doc:getPageXPointer(end_p + 1)
        end)
        if ok1 and type(x) == "string" and x ~= "" then xp1 = x end
    end
    if not xp1 and doc.getXPointer then
        -- end_p is the last page: end at the live reading position. Only
        -- valid when the range actually reaches the reader (end_p <= now);
        -- otherwise bail instead of returning a swapped range.
        local now = Chapters.getCurrentPage(ui)
        if end_p <= now then
            local okc, xc = pcall(function() return doc:getXPointer() end)
            if okc and type(xc) == "string" and xc ~= "" then xp1 = xc end
        end
    end
    if not xp1 then return nil end
    local ok, res = pcall(function()
        return doc:getTextFromXPointers(xp0, xp1)
    end)
    if ok and type(res) == "string" and #res > 0 then return res end
    return nil
end

-- Ordered list of chapter nodes that have page numbers. Books without a
-- table of contents get pseudo-chapters (fixed 50-page chunks up to the
-- current page) so chapter features keep working.
function Chapters.getChapterList(ui)
    local ok, raw_toc = pcall(function() return ui.document:getToc() end)
    local flat = {}
    if ok and raw_toc then
        for _, node in ipairs(flattenTOC(raw_toc)) do
            if type(node) == "table" and tonumber(node.page) then
                table.insert(flat, node)
            end
        end
    end
    if #flat == 0 then
        return Chapters.getPseudoChapters(ui)
    end
    return flat
end

-- Fallback chapter list for books with no TOC: 50-page chunks.
function Chapters.getPseudoChapters(ui)
    local pos = Chapters.getCurrentPage(ui)
    local size = 50
    local chunks = {}
    local n = math.max(1, math.ceil(pos / size))
    for i = 1, n do
        local start_p = (i - 1) * size + 1
        table.insert(chunks, {
            title = "Pages " .. start_p .. "-" .. (i * size),
            page = start_p,
            pseudo = true,
        })
    end
    return chunks
end

function Chapters.findNodeByTitle(ui, title)
    local list = Chapters.getChapterList(ui)
    local i = Chapters.indexInList(list, title)
    if i then return list[i], list[i + 1] end
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

-- Normalize extracted text: single spaces, no blank-line runs, trimmed.
local function cleanText(text)
    text = text:gsub("\r", " ")
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Page-by-page text for paged documents (PDF, DjVu, ...). cap bounds
-- how many non-empty pages get collected, as a sanity limit.
local function pagedRangeText(ui, start_p, end_p, cap)
    if not ui.document.getPageText then return "" end
    local parts = {}
    for p = start_p, end_p do
        local ok, t = pcall(function() return ui.document:getPageText(p) end)
        if ok and t and t ~= "" then table.insert(parts, t) end
        if #parts > cap then break end -- sanity cap
    end
    return table.concat(parts, "\n")
end

-- Index of a title in an already-flattened chapter list (nil when absent).
function Chapters.indexInList(list, title)
    for i, node in ipairs(list) do
        if node.title == title then return i end
    end
    return nil
end

-- Text for an arbitrary page range, never past the reading position.
-- Used by page-based sessions.
function Chapters.getPageRangeText(ui, from_page, to_page, budget)
    local current_page = Chapters.getCurrentPage(ui)
    from_page = math.max(1, tonumber(from_page) or 1)
    to_page = math.min(tonumber(to_page) or current_page, current_page)
    if from_page > to_page then return "" end
    local text = ""
    if ui.rolling then
        local t = reflowablePageRangeText(ui, from_page, to_page)
        if t then text = t end
    else
        text = pagedRangeText(ui, from_page, to_page, 200)
    end
    return fitBudget(cleanText(text), budget or 60000)
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
-- budget caps the returned bytes (default 500000): finished chapters go out
-- whole, so questions can cover the full chapter including the middle.
function Chapters.getChapterText(ui, chapter, next_chapter, which, budget)
    local text = ""
    local is_reflowable = ui.rolling ~= nil
    local current_page = Chapters.getCurrentPage(ui)

    if chapter.pseudo then
        -- No TOC: this "chapter" is a fixed page chunk.
        local start_p = tonumber(chapter.page) or 1
        local end_p = (next_chapter and (tonumber(next_chapter.page) - 1))
            or current_page
        end_p = math.min(end_p, current_page)
        end_p = math.max(start_p, end_p)
        if is_reflowable then
            local t = reflowablePageRangeText(ui, start_p, end_p)
            if t then text = t end
        else
            text = pagedRangeText(ui, start_p, end_p, 80)
        end
    elseif is_reflowable then
        -- Page-range extraction: a chapter's pages run from its TOC start
        -- page to the next chapter's start page. This spans split files and
        -- part layouts whose full text the TOC entry alone cannot see.
        local start_p = tonumber(chapter.page) or 1
        local end_p
        if which == "current" then
            -- Spoiler guard: never past the reading position.
            end_p = current_page
        else
            end_p = (next_chapter and (tonumber(next_chapter.page) - 1))
                or Chapters.getPageCount(ui)
        end
        if end_p <= 0 then end_p = current_page end
        end_p = math.max(start_p, end_p)
        local t = reflowablePageRangeText(ui, start_p, end_p)
        if t then
            text = t
        elseif ui.document.getTextFromXPointer and chapter.xpointer then
            -- Fallback for documents without page-xpointer support: the
            -- chapter entry's own text (the pre-v38 behavior).
            local ok, res = pcall(function()
                return ui.document:getTextFromXPointer(chapter.xpointer)
            end)
            if ok and type(res) == "string" and #res > 100 then
                text = res
                -- Spoiler guard for the chapter being read (pre-v38 cut).
                if which == "current" then
                    local c_start = tonumber(chapter.page) or 1
                    local c_end = (next_chapter and tonumber(next_chapter.page))
                        or (current_page + 40)
                    if c_end > c_start then
                        local frac = (current_page - c_start + 1)
                            / (c_end - c_start)
                        frac = math.max(0.05, math.min(1, frac))
                        text = safeByteCut(text, math.floor(#text * frac))
                    end
                end
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
        text = pagedRangeText(ui, start_p, end_p, 80)
    end

    return fitBudget(cleanText(text), budget or 500000)
end

-- Index of the chapter with this title in the flattened chapter list.
function Chapters.findIndexByTitle(ui, title)
    return Chapters.indexInList(Chapters.getChapterList(ui), title)
end

-- Spoiler-safe text for a chapter range (a reading session): concatenates
-- each chapter's text under a chapter header. Only finished chapters should
-- be included; callers enforce that. per_chapter_budget caps each chapter's
-- contribution (default 20000), total capped at total_budget (default
-- 100000). When cur_idx is given, that chapter is treated as "current"
-- (only text up to the reading position is used); all others are "previous".
function Chapters.getRangeText(ui, from_idx, to_idx, per_chapter_budget,
    total_budget, cur_idx)
    per_chapter_budget = per_chapter_budget or 20000
    total_budget = total_budget or 100000
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
    return Chapters.getRangeText(ui, 1, #flat, 5000, 150000)
end

return Chapters
