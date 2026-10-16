-- Reflections for KOReader
-- Finish a chapter and Gemini has 1-3 pen-and-paper reflection prompts
-- waiting for you. Chapters are detected as you read; prompts generate in
-- the background the moment you turn the page into a new chapter.
-- Chapter tracking approach adapted from xray.koplugin (ultimatejimmy).

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Chapters = require(plugin_path .. "chapters")
local Gemini = require(plugin_path .. "gemini")

local DEFAULT_MODEL = "gemini-3.5-flash-lite"
-- Models Google has retired for new API users: silently upgrade to the default.
local RETIRED_MODELS = {
    ["gemini-2.5-flash"] = true,
}
local DEFAULT_PROMPT_COUNT = 3

-- fork()/waitpid() for silent background generation (no UI, ever).
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
    pcall(ffi.cdef, [[
        int fork(void);
        int waitpid(int pid, int *status, int options);
        int kill(int pid, int sig);
        void _exit(int status);
    ]])
end
local WNOHANG = 1
local SIGKILL = 9

local Reflections = WidgetContainer:extend{
    name = "reflections",
    is_doc_only = true,
}

function Reflections:init()
    self._inflight = {}
    self._job_seq = 0
    self._job_errors = {}   -- chapter title -> last background/foreground job error
    self._pending = nil     -- foreground tap currently waiting on a job
    self._open_prompts = nil -- currently shown prompts page, if any
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- ---------------------------------------------------------------- settings

-- Optional pre-configuration file (filled in on a computer, see
-- reflections.conf.lua). Values set on the device always win over it.
function Reflections:getFileConfig()
    if self._file_config ~= nil then return self._file_config end
    local cfg = {}
    pcall(function()
        if self.path then
            local path = self.path .. "/reflections.conf.lua"
            local f = io.open(path, "r")
            if f then
                f:close()
                local chunk = loadfile(path)
                if chunk then
                    local ok, res = pcall(chunk)
                    if ok and type(res) == "table" then cfg = res end
                end
            end
        end
    end)
    self._file_config = cfg
    return cfg
end

function Reflections:getApiKey()
    if G_reader_settings then
        local v = G_reader_settings:readSetting("reflections_gemini_key")
        if v and v ~= "" then return v end
    end
    return self:getFileConfig().api_key or ""
end

function Reflections:getPromptCount()
    local n
    if G_reader_settings then
        n = G_reader_settings:readSetting("reflections_prompt_count")
    end
    if n == nil then n = self:getFileConfig().prompt_count end
    n = tonumber(n) or DEFAULT_PROMPT_COUNT
    if n < 1 or n > 3 then n = DEFAULT_PROMPT_COUNT end
    return n
end

function Reflections:getModel()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_model")
    end
    if not v or v == "" then
        v = self:getFileConfig().model
    end
    if not v or v == "" or RETIRED_MODELS[v] then
        v = DEFAULT_MODEL
    end
    return v
end

-- Models to try in order when generating. The user's chosen model goes
-- first; if Google reports it overloaded (or retired), the next one is
-- tried, since capacity is managed per model.
function Reflections:getModelChain()
    local primary = self:getModel()
    local chain, seen = { primary }, { [primary] = true }
    for _, m in ipairs({ "gemini-3.5-flash", "gemini-3.5-flash-lite" }) do
        if not seen[m] then
            chain[#chain + 1] = m
            seen[m] = true
        end
    end
    return chain
end

function Reflections:getBackgroundEnabled()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_background")
    end
    if v == nil then v = self:getFileConfig().background end
    if v == nil then return true end
    return v
end

function Reflections:editApiKey()
    local current = self:getApiKey()
    local dialog
    dialog = InputDialog:new{
        title = _("Gemini API key"),
        input_hint = _("Paste your Gemini API key"),
        input = current,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local v = dialog:getInputText() or ""
                        v = v:gsub("^%s+", ""):gsub("%s+$", "")
                        G_reader_settings:saveSetting("reflections_gemini_key", v)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("API key saved."),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reflections:editModel()
    local current = self:getModel()
    local dialog
    dialog = InputDialog:new{
        title = _("Gemini model"),
        input_hint = _("e.g. gemini-3.8-flash"),
        input = current,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local v = dialog:getInputText() or ""
                        v = v:gsub("^%s+", ""):gsub("%s+$", "")
                        if v == "" then v = DEFAULT_MODEL end
                        G_reader_settings:saveSetting("reflections_model", v)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------- per-book storage

function Reflections:getDocStore()
    local ok, ds = pcall(function() return self.ui.doc_settings end)
    if ok and ds then return ds end
    return nil
end

function Reflections:saveDocSetting(key, value)
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        ds:saveSetting(key, value)
        if ds.flush then ds:flush() end
    end)
end

function Reflections:readDocSetting(key)
    local ds = self:getDocStore()
    if not ds then return nil end
    local ok, v = pcall(function() return ds:readSetting(key) end)
    if ok then return v end
    return nil
end

-- Ordered list of finished chapters: { {title=...}, ... }
function Reflections:getProgress()
    local p = self:readDocSetting("reflections_chapters")
    if type(p) == "table" then return p end
    return {}
end

function Reflections:recordFinished(title)
    local progress = self:getProgress()
    for _, e in ipairs(progress) do
        if e.title == title then return end
    end
    table.insert(progress, { title = title })
    self:saveDocSetting("reflections_chapters", progress)
end

function Reflections:getLastIdx()
    return self:readDocSetting("reflections_last_idx")
end

function Reflections:setLastIdx(idx)
    self:saveDocSetting("reflections_last_idx", idx)
end

-- Prompts cache: title -> { text=..., partial=bool }. Plain strings from
-- v1 are still honored.
function Reflections:readCachedPrompts(chapter_title)
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return nil end
    local entry = cache[chapter_title]
    if type(entry) == "string" then return entry end
    if type(entry) == "table" then return entry.text end
    return nil
end

function Reflections:isPartialCache(chapter_title)
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return false end
    local entry = cache[chapter_title]
    return type(entry) == "table" and entry.partial == true
end

function Reflections:cachePrompts(chapter_title, prompts, partial)
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        local cache = ds:readSetting("reflections_cache") or {}
        cache[chapter_title] = { text = prompts, partial = partial and true or false }
        ds:saveSetting("reflections_cache", cache)
        if ds.flush then ds:flush() end
    end)
end

-- Forget every cached prompt for the current book.
function Reflections:clearCache()
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        ds:delSetting("reflections_cache")
        if ds.flush then ds:flush() end
    end)
end

-- ------------------------------------------------------ chapter tracking

function Reflections:onPageUpdate(page)
    pcall(function()
        self:checkChapterTransition()
        self:reapBackgroundJobs()
    end)
end

function Reflections:onResume()
    pcall(function()
        self:checkChapterTransition()
        self:reapBackgroundJobs()
    end)
end

function Reflections:onReaderReady()
    pcall(function()
        self:checkChapterTransition()
        self:reapBackgroundJobs()
    end)
end

function Reflections:onCloseDocument()
    -- Stop watching any in-flight tap; its result still lands in /tmp and
    -- will be adopted as an orphan next time this book opens.
    self._pending = nil
    self._open_prompts = nil
    pcall(function() self:reapBackgroundJobs() end)
end

function Reflections:checkChapterTransition()
    if not self.ui or not self.ui.document then return end
    local idx, chapter = Chapters.findChapter(self.ui, "current")
    if not idx or not chapter then return end

    local last = self:getLastIdx()
    if not last then
        -- First sight of this book: everything before the current
        -- chapter counts as already read.
        local list = Chapters.getChapterList(self.ui)
        local progress = {}
        for i = 1, idx - 1 do
            if list[i] and list[i].title then
                table.insert(progress, { title = list[i].title })
            end
        end
        self:saveDocSetting("reflections_chapters", progress)
        self:setLastIdx(idx)
        return
    end

    if idx > last then
        local list = Chapters.getChapterList(self.ui)
        for i = last, idx - 1 do
            local node = list[i]
            if node and node.title then
                self:recordFinished(node.title)
                self:maybeBackgroundGenerate(node.title, node, list[i + 1])
            end
        end
    end
    self:setLastIdx(idx)
end

-- ------------------------------------------------------------- generation

function Reflections:buildPrompt(title, author, chapter_title, text, n)
    return "You are a reading companion helping someone think deeply about "
        .. "the story they just read. They will answer with pen and paper in "
        .. "a physical journal, so make each question open-ended and worth "
        .. "writing about.\n\n"
        .. "Book: \"" .. title .. "\" by " .. author .. "\n"
        .. "Chapter: \"" .. chapter_title .. "\"\n\n"
        .. "Chapter text (may be excerpted; NEVER reference anything beyond "
        .. "this text):\n---\n" .. text .. "\n---\n\n"
        .. "Write exactly " .. tostring(n) .. " numbered discussion questions "
        .. "about THIS chapter, the kind a thoughtful book club would ask. "
        .. "Rules:\n"
        .. "- About the story itself: its events, characters, choices, themes, and ideas\n"
        .. "- Open-ended: no yes/no questions, no single correct answer\n"
        .. "- Specific to this chapter's events, characters, choices, or ideas\n"
        .. "- Never ask about the reader's own life, feelings, or experiences\n"
        .. "- Never ask what the reader would do in a character's situation\n"
        .. "- Do not summarize the chapter\n"
        .. "- Do not reveal or hint at anything not in the text above\n"
        .. "- Output ONLY the numbered questions, nothing else"
end

-- A short stable key for this book, used to name background result files.
function Reflections:getBookKey()
    local key
    pcall(function()
        local f = self.ui.document.file
        if type(f) == "string" then key = f end
    end)
    if not key then
        local info = Chapters.getBookInfo(self.ui)
        key = info.title
    end
    return tostring(key):gsub("[^%w]", "_"):sub(1, 60)
end

-- Shared job launcher: extracts the spoiler-guarded chapter text here in
-- the parent, then fork()s a child that only does the HTTPS call (with
-- retries for transient errors) and writes the result to a temp file.
-- opts: { kind = "previous"|"current", partial = bool, overwrite = bool }.
-- Returns true when a job is now running (or already was).
function Reflections:launchGeneration(chapter_title, node, next_node, opts)
    opts = opts or {}
    if self._inflight[chapter_title] then return true end
    local kind = opts.kind or "previous"
    local ok, text = pcall(Chapters.getChapterText, self.ui, node, next_node, kind)
    if not ok or not text or #text < 50 then return false end
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildPrompt(
        info.title, info.author, chapter_title, text, self:getPromptCount())

    self._job_seq = self._job_seq + 1
    local result_path = string.format("/tmp/reflections_%s_%d_%d_%d.txt",
        self:getBookKey(), os.time(), self._job_seq, math.random(1000000))
    self._inflight[chapter_title] = {
        path = result_path,
        started = os.time(),
        partial = opts.partial and true or false,
        overwrite = opts.overwrite and true or false,
    }
    self._job_errors[chapter_title] = nil

    local api_key, models = self:getApiKey(), self:getModelChain()
    local pid = ffi.C.fork()
    if pid == 0 then
        -- Child: network only. Never touch UI, the document, or plugin state.
        local okc, result = pcall(Gemini.generate, api_key, models, prompt_text, 45, 1)
        local f = io.open(result_path, "w")
        if f then
            if okc and result then
                f:write("OK\n" .. chapter_title .. "\n" .. result)
            else
                f:write("ERR\n" .. chapter_title .. "\n" .. tostring(result))
            end
            f:close()
        end
        ffi.C._exit(0)
    elseif pid > 0 then
        self._inflight[chapter_title].pid = pid
    else
        self._inflight[chapter_title] = nil -- fork failed
    end
    return true
end

-- Kick off a SILENT background generation for a just-finished chapter.
-- Nothing is ever shown on the reading screen: the text is extracted here
-- in the parent, then fork() runs only the HTTPS call in the child, which
-- writes the result to a temp file and exits. The parent picks results up
-- on later page turns (see reapBackgroundJobs).
function Reflections:maybeBackgroundGenerate(chapter_title, node, next_node)
    if not self:getBackgroundEnabled() then return end
    if not ffi_ok then return end -- no fork support: falls back to tap-to-generate
    if self:getApiKey() == "" then return end
    if self._inflight[chapter_title] then return end
    local cached = self:readCachedPrompts(chapter_title)
    if cached and not self:isPartialCache(chapter_title) then return end
    self:launchGeneration(chapter_title, node, next_node,
        { kind = "previous", partial = false, overwrite = false })
end

-- Collect finished background jobs (non-blocking) and adopt any result
-- files left behind by earlier sessions.
function Reflections:reapBackgroundJobs()
    if not ffi_ok then return end
    local tracked_paths = {}
    for title, job in pairs(self._inflight) do
        tracked_paths[job.path] = true
        if job.pid then
            local done = ffi.C.waitpid(job.pid, nil, WNOHANG)
            if done == job.pid or done == -1 then
                self:collectJobResult(job)
                self._inflight[title] = nil
            elseif os.time() - job.started > 300 then
                ffi.C.kill(job.pid, SIGKILL)
                ffi.C.waitpid(job.pid, nil, 0)
                os.remove(job.path)
                self._inflight[title] = nil
            end
        end
    end
    self:adoptOrphanResults(tracked_paths)
end

function Reflections:collectJobResult(job)
    local f = io.open(job.path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    os.remove(job.path)
    local status, ctitle, body =
        content:match("^(%a+)\n([^\n]*)\n([%s%S]*)$")
    if status == "OK" and ctitle and body and body ~= "" then
        if job.overwrite or not self:readCachedPrompts(ctitle) then
            self:cachePrompts(ctitle, body, job.partial and true or false)
        end
    elseif status == "ERR" and ctitle then
        -- Stashed for the foreground poller; background errors stay silent.
        self._job_errors[ctitle] = (body and body ~= "") and body or "unknown error"
    end
end

function Reflections:adoptOrphanResults(tracked_paths)
    local prefix = "reflections_" .. self:getBookKey() .. "_"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs or not lfs.dir then return end
    for file in lfs.dir("/tmp") do
        if file:sub(1, #prefix) == prefix then
            local path = "/tmp/" .. file
            if not tracked_paths[path] then
                local f = io.open(path, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    os.remove(path)
                    local status, ctitle, body =
                        content:match("^(%a+)\n([^\n]*)\n([%s%S]*)$")
                    if status == "OK" and ctitle and body and body ~= ""
                        and not self:readCachedPrompts(ctitle) then
                        self:cachePrompts(ctitle, body, false)
                    end
                end
            end
        end
    end
end

-- Tap-to-generate. Never blocks the UI: the prompts page opens immediately
-- with a placeholder, generation runs in a forked child, and the page is
-- updated when the result lands. opts: { partial = bool } — partial marks
-- the cached result as "from an unfinished chapter".
function Reflections:generateForChapter(chapter_title, force, opts)
    opts = opts or {}
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    if not force then
        local cached = self:readCachedPrompts(chapter_title)
        if cached then
            self:showPrompts(chapter_title, cached, true)
            return
        end
    end
    local node, next_node = Chapters.findNodeByTitle(self.ui, chapter_title)
    if not node then
        UIManager:show(InfoMessage:new{
            text = _("Could not find that chapter in this book."),
        })
        return
    end
    local kind = "previous"
    local cur_idx, cur = Chapters.findChapter(self.ui, "current")
    if cur and cur.title == chapter_title then kind = "current" end

    -- No fork support (never happens on real devices): synchronous fallback.
    if not ffi_ok then
        self:generateForChapterSync(chapter_title, node, next_node, kind, opts.partial)
        return
    end

    -- Regenerating while a job is already running: stop the old one first so
    -- the new request isn't answered by the stale job.
    if force then
        local old_job = self._inflight[chapter_title]
        if old_job then
            pcall(function()
                if old_job.pid then
                    ffi.C.kill(old_job.pid, SIGKILL)
                    ffi.C.waitpid(old_job.pid, nil, 0)
                end
            end)
            pcall(os.remove, old_job.path)
            self._inflight[chapter_title] = nil
        end
    end

    self:showPrompts(chapter_title, _("Generating your prompts…"),
        { placeholder = true })
    self._pending = {
        title = chapter_title,
        partial = opts.partial and true or false,
        old = self:readCachedPrompts(chapter_title),
        waited = 0,
    }
    if not self:launchGeneration(chapter_title, node, next_node,
        { kind = kind, partial = opts.partial, overwrite = force }) then
        self._pending = nil
        self:showPrompts(chapter_title,
            _("Could not extract enough chapter text."), {})
        return
    end
    self:pollPendingPrompts()
end

-- Synchronous fallback used only when fork() is unavailable.
function Reflections:generateForChapterSync(chapter_title, node, next_node, kind, partial)
    local busy = InfoMessage:new{ text = _("Generating reflection prompts...") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local text = Chapters.getChapterText(self.ui, node, next_node, kind)
    if not text or #text < 50 then
        UIManager:close(busy)
        UIManager:show(InfoMessage:new{
            text = _("Could not extract enough chapter text."),
        })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildPrompt(
        info.title, info.author, chapter_title, text, self:getPromptCount())
    local result, err = Gemini.generate(self:getApiKey(), self:getModelChain(),
        prompt, 45, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Gemini request failed:\n") .. tostring(err),
        })
        return
    end
    self:cachePrompts(chapter_title, result, partial and true or false)
    self:showPrompts(chapter_title, result, false)
end

-- Watches the forked job started by generateForChapter and swaps the
-- placeholder page for the real prompts (or a readable error) when it
-- lands. The UI stays responsive the whole time; pressing Back cancels
-- the watch while the job still caches silently in the background.
function Reflections:pollPendingPrompts()
    local my = self._pending
    if not my then return end
    UIManager:scheduleIn(2, function()
        if self._pending ~= my then return end -- superseded or cancelled
        pcall(function() self:reapBackgroundJobs() end)
        local prompts = self:readCachedPrompts(my.title)
        local job_done = self._inflight[my.title] == nil
        if prompts and (prompts ~= my.old or job_done) then
            self._pending = nil
            self:showPrompts(my.title, prompts, { from_cache = false })
            return
        end
        local err = self._job_errors[my.title]
        if err then
            self._pending = nil
            self._job_errors[my.title] = nil
            self:showPrompts(my.title,
                _("Gemini request failed: ") .. tostring(err), {})
            return
        end
        my.waited = my.waited + 2
        if my.waited >= 330 then
            self._pending = nil
            self:showPrompts(my.title,
                _("Gemini is taking too long. Check your connection and try again."), {})
            return
        end
        self:pollPendingPrompts()
    end)
end

function Reflections:cancelPending(chapter_title)
    if self._pending and self._pending.title == chapter_title then
        self._pending = nil
    end
end

function Reflections:closePromptsPage()
    if self._open_prompts then
        UIManager:close(self._open_prompts.dialog)
        self._open_prompts = nil
    end
end

-- On-demand prompts for the chapter currently being read. Spoiler-guarded:
-- only text up to the current page is sent.
function Reflections:reflectCurrent()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local chap_idx, chapter = Chapters.findChapter(self.ui, "current")
    if not chapter then
        UIManager:show(InfoMessage:new{
            text = _("Could not detect chapters. This book may have no table of contents."),
        })
        return
    end
    -- Marked partial: the full-chapter generation later will replace these.
    self:generateForChapter(chapter.title or _("Untitled chapter"), true,
        { partial = true })
end

-- Full-screen prompts page: the chapter's questions, with New prompts
-- and Back buttons. A dedicated screen, not an overlay dialog.
-- opt may be a boolean (from_cache) or a table { from_cache, placeholder }.
function Reflections:showPrompts(chapter_title, prompts, opt)
    local from_cache, placeholder
    if type(opt) == "table" then
        from_cache, placeholder = opt.from_cache, opt.placeholder
    else
        from_cache = opt
    end

    -- Replace any prompts page already on screen (e.g. placeholder -> result).
    if self._open_prompts then
        pcall(UIManager.close, UIManager, self._open_prompts.dialog)
        self._open_prompts = nil
    end

    local Screen = require("device").screen
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local ScrollTextWidget = require("ui/widget/scrolltextwidget")
    local Button = require("ui/widget/button")

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(16)
    local title_h = Screen:scaleBySize(52)
    local buttons_h = Screen:scaleBySize(72)
    local text_h = sh - pad * 2 - title_h - pad - buttons_h - pad
    if text_h < Screen:scaleBySize(100) then
        text_h = Screen:scaleBySize(100)
    end

    local body
    if placeholder then
        body = prompts -- already a status line like "Generating your prompts…"
    else
        local header = _("Grab your journal and a pen.")
        if from_cache then
            header = header .. " " .. _("(saved from earlier)")
        end
        body = header .. "\n\n" .. prompts
    end

    local dialog
    local function goBack()
        self:cancelPending(chapter_title)
        self:closePromptsPage()
        self:showMainScreen()
    end

    -- Built separately so we can hand it the dialog reference
    -- ScrollTextWidget needs for its scrollbar refreshes.
    local scroll_widget = ScrollTextWidget:new{
        text = body,
        face = Font:getFace("cfont", 22),
        width = sw - pad * 2,
        height = text_h,
    }

    dialog = FrameContainer:new{
        width = sw,
        height = sh,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        -- Fullscreen and opaque: nothing underneath gets painted or tapped.
        covers_fullscreen = true,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = chapter_title,
                face = Font:getFace("tfont", 26),
            },
            VerticalSpan:new{ width = pad },
            scroll_widget,
            VerticalSpan:new{ width = pad },
            HorizontalGroup:new{
                align = "center",
                Button:new{
                    text = _("New prompts"),
                    callback = function()
                        self:generateForChapter(chapter_title, true)
                    end,
                },
                HorizontalSpan:new{ width = pad },
                Button:new{
                    text = _("Back"),
                    callback = goBack,
                },
            },
        },
    }
    scroll_widget.dialog = dialog
    self._open_prompts = { title = chapter_title, dialog = dialog }
    UIManager:show(dialog)
end

-- ------------------------------------------------------------------ screens

-- Dedicated full-screen chapter browser. Tapping the plugin's Tools menu
-- entry opens this instead of a submenu, xray-style.
function Reflections:showMainScreen()
    pcall(function()
        self:checkChapterTransition()
        self:reapBackgroundJobs()
    end)

    local Menu = require("ui/widget/menu")
    local menu
    local items = {}

    for _, entry in ipairs(self:getProgress()) do
        local title = entry.title
        table.insert(items, {
            text = title,
            callback = function()
                -- The chapter list closes; Back on the prompts page reopens it.
                UIManager:close(menu)
                self:generateForChapter(title, false)
            end,
            hold_callback = function()
                UIManager:close(menu)
                self:generateForChapter(title, true)
            end,
        })
    end

    table.insert(items, {
        text = _("Reflect on current chapter"),
        callback = function()
            UIManager:close(menu)
            self:reflectCurrent()
        end,
    })
    table.insert(items, {
        text = _("Settings"),
        sub_item_table = {
            {
                text_func = function()
                    if self:getApiKey() ~= "" then
                        return _("Gemini API key: set")
                    end
                    return _("Gemini API key: missing")
                end,
                callback = function() self:editApiKey() end,
            },
            {
                text_func = function()
                    return _("Prompts per chapter: ")
                        .. tostring(self:getPromptCount())
                end,
                callback = function()
                    local n = self:getPromptCount()
                    n = (n % 3) + 1
                    G_reader_settings:saveSetting("reflections_prompt_count", n)
                end,
            },
            {
                text_func = function()
                    return _("Model: ") .. self:getModel()
                end,
                callback = function() self:editModel() end,
            },
            {
                text_func = function()
                    if self:getBackgroundEnabled() then
                        return _("Generate in background: on")
                    end
                    return _("Generate in background: off")
                end,
                callback = function()
                    G_reader_settings:saveSetting(
                        "reflections_background", not self:getBackgroundEnabled())
                end,
            },
        },
    })
    table.insert(items, {
        text = _("Clear cached prompts"),
        callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Delete all cached prompts for this book?\nYou can generate fresh ones afterwards."),
                ok_text = _("Delete"),
                ok_callback = function()
                    self:clearCache()
                    UIManager:close(menu)
                    self:showMainScreen()
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("Tip: hold a chapter for fresh prompts"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Tap a chapter to read its prompts.\nHold a chapter to generate a new set."),
            })
        end,
    })
    table.insert(items, {
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    })

    menu = Menu:new{
        title = _("Reflections"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

function Reflections:addToMainMenu(menu_items)
    menu_items.reflections = {
        text = _("Reflections"),
        sorting_hint = "tools",
        callback = function() self:showMainScreen() end,
    }
end

return Reflections
