-- Reflections for KOReader
-- Finish a chapter and Gemini has pen-and-paper reflection prompts waiting
-- for you, plus session questions spanning the chapters you read and an
-- end-of-book reflection when you finish. Chapters are detected as you read;
-- prompts generate in the background the moment you turn the page into a
-- new chapter.
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
local DEFAULT_SESSION_PROMPT_COUNT = 6
local DEFAULT_BOOK_PROMPT_COUNT = 6
local MAX_PROMPT_COUNT = 20

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
    self:migrateFileConfig()
    self:pinToTopOfToolsMenu()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- Put Reflections at the top of the Tools menu (first page). KOReader
-- appends unknown plugins to the end via sorting_hint; instead we edit the
-- cached menu order directly, the same trick xray.koplugin uses.
function Reflections:pinToTopOfToolsMenu()
    pcall(function()
        local ok_order, reader_menu_order =
            pcall(require, "ui/elements/reader_menu_order")
        if not ok_order then
            ok_order, reader_menu_order =
                pcall(require, "apps/reader/modules/readermenuorder")
        end
        if ok_order and reader_menu_order and reader_menu_order.tools then
            for i, v in ipairs(reader_menu_order.tools) do
                if v == "reflections" then
                    table.remove(reader_menu_order.tools, i)
                    break
                end
            end
            table.insert(reader_menu_order.tools, 1, "reflections")
        end
    end)
end

-- The plugin folder (including reflections.conf.lua) is replaced wholesale
-- when the plugin is updated, so the conf file is only ever a seed: copy
-- any preconfigured values into KOReader's own settings the first time they
-- are seen. Only fills in settings the device does not already have, so
-- on-device Settings always win, and a later update can never wipe them.
function Reflections:migrateFileConfig()
    if not G_reader_settings then return end
    local cfg = self:getFileConfig()
    local function seed(setting, value)
        if value == nil or value == "" then return end
        local cur = G_reader_settings:readSetting(setting)
        if cur == nil or cur == "" then
            G_reader_settings:saveSetting(setting, value)
        end
    end
    seed("reflections_gemini_key", cfg.api_key)
    seed("reflections_prompt_count", tonumber(cfg.prompt_count))
    seed("reflections_session_prompt_count", tonumber(cfg.session_prompt_count))
    seed("reflections_book_prompt_count", tonumber(cfg.book_prompt_count))
    seed("reflections_model", cfg.model)
    seed("reflections_background", cfg.background)
    -- The API key gets one more rule: if the conf key changed since we last
    -- saw it, the user edited it on their computer and expects it to take
    -- effect, so it overwrites the device key. A blank conf (e.g. right
    -- after a storefront update) never wipes the device key.
    local conf_key = cfg.api_key
    if type(conf_key) == "string" and conf_key ~= "" then
        local seen = G_reader_settings:readSetting("reflections_conf_key_seen")
        if seen ~= conf_key then
            G_reader_settings:saveSetting("reflections_gemini_key", conf_key)
            G_reader_settings:saveSetting("reflections_conf_key_seen", conf_key)
        end
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
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_gemini_key")
    end
    if not v or v == "" then
        v = self:getFileConfig().api_key
    end
    if type(v) ~= "string" then return "" end
    -- E-ink keyboards love stray spaces: never send them to Google.
    return v:gsub("^%s+", ""):gsub("%s+$", "")
end

function Reflections:getPromptCount()
    local n
    if G_reader_settings then
        n = G_reader_settings:readSetting("reflections_prompt_count")
    end
    if n == nil then n = self:getFileConfig().prompt_count end
    n = tonumber(n) or DEFAULT_PROMPT_COUNT
    if n < 1 or n > MAX_PROMPT_COUNT then n = DEFAULT_PROMPT_COUNT end
    return n
end

function Reflections:getSessionPromptCount()
    local n
    if G_reader_settings then
        n = G_reader_settings:readSetting("reflections_session_prompt_count")
    end
    if n == nil then n = self:getFileConfig().session_prompt_count end
    n = tonumber(n) or DEFAULT_SESSION_PROMPT_COUNT
    if n < 1 or n > MAX_PROMPT_COUNT then n = DEFAULT_SESSION_PROMPT_COUNT end
    return n
end

function Reflections:getBookPromptCount()
    local n
    if G_reader_settings then
        n = G_reader_settings:readSetting("reflections_book_prompt_count")
    end
    if n == nil then n = self:getFileConfig().book_prompt_count end
    n = tonumber(n) or DEFAULT_BOOK_PROMPT_COUNT
    if n < 1 or n > MAX_PROMPT_COUNT then n = DEFAULT_BOOK_PROMPT_COUNT end
    return n
end

-- Fiction or nonfiction framing for the questions. Per book: a novel and a
-- history book on the same reader get different questions. New questions
-- use the current mode; already cached ones stay as generated (hold a
-- chapter to regenerate it in the new mode).
function Reflections:isNonfiction()
    return self:readDocSetting("reflections_nonfiction") == true
end

function Reflections:setNonfiction(v)
    self:saveDocSetting("reflections_nonfiction", v and true or false)
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

-- Number input for a prompt-count setting. kind is "chapter", "session",
-- or "book". on_done, if given, runs after the dialog closes (e.g. to
-- refresh a menu).
function Reflections:editPromptCount(kind, on_done)
    local setting, current, title
    if kind == "session" then
        setting = "reflections_session_prompt_count"
        current = self:getSessionPromptCount()
        title = _("Questions per session")
    elseif kind == "book" then
        setting = "reflections_book_prompt_count"
        current = self:getBookPromptCount()
        title = _("Questions per book reflection")
    else
        setting = "reflections_prompt_count"
        current = self:getPromptCount()
        title = _("Prompts per chapter")
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input_hint = _("1 to 20"),
        input = tostring(current),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if on_done then on_done() end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local v = tonumber(dialog:getInputText())
                        if v then
                            v = math.floor(v)
                            if v >= 1 and v <= MAX_PROMPT_COUNT then
                                G_reader_settings:saveSetting(setting, v)
                            end
                        end
                        UIManager:close(dialog)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

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
function Reflections:clearCache(keep_sessions)
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        ds:delSetting("reflections_cache")
        if not keep_sessions then
            ds:delSetting("reflections_sessions")
        end
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

-- Shared craft rules: keep questions sharp and journal-sized, never homework.
local CRAFT_RULES =
    "- Each question should invite a few sentences of journaling: "
    .. "one sharp thing to think about, not an essay topic\n"
    .. "- Never ask 'what is the significance of X' or 'how does X shape "
    .. "our understanding of Y' — and the same goes for their cousins "
    .. "('how does X define/reveal/illustrate Y', 'what does X reveal/"
    .. "suggest/show about Y'). That whole family of analytic closers is "
    .. "banned; find a sharper, more specific angle\n"
    .. "- Vary your question shapes across the set: mix 'Why did...', "
    .. "'What would you have done when...', 'Which moment...', "
    .. "'Was X right to...', 'What if...'. Do not repeat the same "
    .. "opening or closer shape from question to question\n"
    .. "- Mix two structures across the set: roughly 60 percent two-part "
    .. "questions (a concrete moment or scene first, then the question it "
    .. "raises), and the rest direct single-sentence questions. "
    .. "Two-part shape: 'When [specific thing happens]. [Question it "
    .. "raises]?' Direct shape: 'Was [character] right to [choice]?' or "
    .. "'Why did [character] [action]?'\n"
    .. "- At least one question should zoom in on a single moment, choice, "
    .. "or line rather than a broad theme\n"
    .. "- Don't embed the answer in the question; leave the conclusion "
    .. "genuinely open\n"

-- When regenerating, show the model what it already asked so it asks
-- different questions instead of rewording the same ones.
local function avoidRepeat(old)
    if not old or old == "" then return "" end
    return "\nThe reader already saw these questions:\n---\n" .. old
        .. "\n---\nAsk DIFFERENT questions: different moments, different "
        .. "angles, no repeats."
end

function Reflections:buildPrompt(title, author, chapter_title, text, n, old)
    if self:isNonfiction() then
        return "You are a reading companion helping someone think deeply "
            .. "about the nonfiction book they just read. They will answer "
            .. "with pen and paper in a physical journal, so make each "
            .. "question open-ended and worth writing about.\n\n"
            .. "Book: \"" .. title .. "\" by " .. author .. "\n"
            .. "Chapter: \"" .. chapter_title .. "\"\n\n"
            .. "Chapter text (may be excerpted; NEVER reference anything "
            .. "beyond this text):\n---\n" .. text .. "\n---\n\n"
            .. "Write exactly " .. tostring(n) .. " numbered discussion "
            .. "questions about THIS chapter, the kind a thoughtful book "
            .. "club would ask. Rules:\n"
            .. "- About the ideas themselves: the author's arguments, evidence, key concepts, and real-world applications\n"
            .. "- Open-ended: no yes/no questions, no single correct answer\n"
            .. "- Specific to this chapter's arguments, evidence, or ideas\n"
            .. "- Ask what to question or challenge, not just what to accept\n"
            .. "- Never ask about the reader's own life, feelings, or experiences\n"
            .. "- Do not summarize the chapter\n"
            .. "- Do not reveal or hint at anything not in the text above\n"
            .. CRAFT_RULES
            .. "- Output ONLY the numbered questions, nothing else"
            .. avoidRepeat(old)
    end
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
        .. CRAFT_RULES
        .. "- Output ONLY the numbered questions, nothing else"
        .. avoidRepeat(old)
end

-- Prompt for a reading session: several chapters read in one sitting.
-- Asks for questions about connections ACROSS the chapters.

-- Ten nuanced angles for session questions. Each lens question takes one,
-- picked at random.
local SESSION_LENSES = {
    "plot and events",
    "characters and their choices",
    "themes and ideas",
    "shifting relationships between characters",
    "foreshadowing and payoff",
    "the author's craft and structure",
    "moral gray areas",
    "worldbuilding and setting",
    "the emotional arc across the chapters",
    "predictions about what comes next",
}

-- Same idea for the end-of-book reflection, framed around the whole work.
local BOOK_LENSES = {
    "plot and events",
    "characters and their choices",
    "themes and ideas",
    "shifting relationships between characters",
    "foreshadowing and payoff",
    "the author's craft and structure",
    "moral gray areas",
    "worldbuilding and setting",
    "the emotional arc from beginning to end",
    "what lingers after the last page",
}

-- Nonfiction variants: arguments, evidence, and ideas instead of story.
local NONFICTION_SESSION_LENSES = {
    "the central arguments and how they're supported",
    "key ideas and concepts",
    "evidence and examples",
    "real-world applications",
    "what to question or challenge",
    "how ideas connect across the chapters",
    "the author's methods and reasoning",
    "implications and takeaways",
    "counterarguments and alternative views",
    "what remains unresolved",
}

local NONFICTION_BOOK_LENSES = {
    "the central arguments and how they're supported",
    "key ideas and concepts",
    "evidence and examples",
    "real-world applications",
    "what to question or challenge",
    "the author's methods and reasoning",
    "implications and takeaways",
    "counterarguments and alternative views",
    "how the ideas fit together as a whole",
    "what remains unresolved",
}

local random_seeded, seed_counter = false, 0
local function ensureSeeded()
    if random_seeded then return end
    seed_counter = seed_counter + 1
    math.randomseed(os.time() * 1000 + math.floor(os.clock() * 1000)
        + seed_counter * 7919)
    math.random()
    random_seeded = true
end

-- Pick k lenses in random order, reshuffling the pool when exhausted so
-- repeats are spaced out.
local function pickLenses(k, lenses)
    lenses = lenses or SESSION_LENSES
    ensureSeeded()
    local picked, pool = {}, {}
    local function refill()
        pool = {}
        for i, lens in ipairs(lenses) do pool[i] = lens end
        for i = #pool, 2, -1 do
            local j = math.random(i)
            pool[i], pool[j] = pool[j], pool[i]
        end
    end
    refill()
    while #picked < k do
        if #pool == 0 then refill() end
        table.insert(picked, table.remove(pool))
    end
    return picked
end

-- Plan a session's questions. The first 3 are always organic cross-chapter
-- questions (lenses only appear when n > 3). Beyond those, each question
-- takes one random lens. At 7+ questions there's a small chance one lens is
-- swapped for a playful question, so it stays a rare surprise.
-- Returns organic_n, {lens, ...}, playful.
local PLAYFUL_CHANCE = 0.35

local function planQuestions(n, lenses)
    if n <= 3 then return n, {}, false end
    local picked = pickLenses(n - 3, lenses)
    if n >= 7 and math.random() < PLAYFUL_CHANCE then
        table.remove(picked, math.random(#picked))
        return 3, picked, true
    end
    return 3, picked, false
end

local function sessionPlan(n, lenses)
    return planQuestions(n, lenses or SESSION_LENSES)
end

local function bookPlan(n, lenses)
    return planQuestions(n, lenses or BOOK_LENSES)
end

function Reflections:buildSessionPrompt(title, author, from_title, to_title, text, n, old)
    local nf = self:isNonfiction()
    local organic_n, lenses, playful = sessionPlan(n,
        nf and NONFICTION_SESSION_LENSES or nil)

    local function qword(c, one, many)
        if c == 1 then return "1 " .. one end
        return c .. " " .. many
    end

    local steps = {}
    if nf then
        table.insert(steps, "first write "
            .. qword(organic_n, "open-ended question", "open-ended questions")
            .. " about connections ACROSS the chapters: how arguments build "
            .. "on each other, how key ideas develop, how evidence in one "
            .. "chapter supports or challenges another")
    else
        table.insert(steps, "first write "
            .. qword(organic_n, "open-ended question", "open-ended questions")
            .. " about connections ACROSS the chapters: how characters change, "
            .. "how themes develop, how an event in one chapter reframes another")
    end

    if #lenses > 0 then
        local bits = {}
        for _, lens in ipairs(lenses) do
            table.insert(bits, "1 question about " .. lens)
        end
        table.insert(steps, "then write " .. table.concat(bits, ", "))
    end

    if playful then
        if nf then
            table.insert(steps, "finally write 1 playful, creative question: "
                .. "for example, asking for a better title for one of the "
                .. "chapters, which idea deserves its own TED talk, or "
                .. "a one-sentence dramatic summary of the session")
        else
            table.insert(steps, "finally write 1 playful, creative question: "
                .. "for example, asking for a better title for one of the "
                .. "chapters, casting choices for a movie version of a scene, or "
                .. "a one-sentence dramatic summary of the session")
        end
    end

    local intro
    if nf then
        intro = "You are a reading companion helping someone think deeply "
            .. "about the nonfiction book they just read. They read several "
            .. "chapters in one sitting and will answer with pen and paper "
            .. "in a physical journal, so make each question open-ended and "
            .. "worth writing about.\n\n"
    else
        intro = "You are a reading companion helping someone think deeply about "
            .. "the story they just read. They read several chapters in one sitting "
            .. "and will answer with pen and paper in a physical journal, so make "
            .. "each question open-ended and worth writing about.\n\n"
    end
    local about_rule
    if nf then
        about_rule = "- About the ideas themselves: the author's arguments, evidence, key concepts, and real-world applications\n"
            .. "- Ask what to question or challenge, not just what to accept\n"
    else
        about_rule = "- About the story itself: its events, characters, choices, themes, and ideas\n"
            .. "- Never ask what the reader would do in a character's situation\n"
    end

    return intro
        .. "Book: \"" .. title .. "\" by " .. author .. "\n"
        .. "Chapters read this session: \"" .. from_title .. "\" through \""
        .. to_title .. "\"\n\n"
        .. "Chapter texts (may be excerpted; NEVER reference anything beyond "
        .. "this text):\n---\n" .. text .. "\n---\n\n"
        .. "Write exactly " .. tostring(n) .. " numbered discussion questions "
        .. "about THESE chapters as a group, the kind a thoughtful book club "
        .. "would ask, in this order: " .. table.concat(steps, "; ")
        .. ". Rules:\n"
        .. about_rule
        .. "- Open-ended: no yes/no questions, no single correct answer\n"
        .. "- Never ask about the reader's own life, feelings, or experiences\n"
        .. "- Do not summarize the chapters\n"
        .. "- Do not reveal or hint at anything not in the text above\n"
        .. CRAFT_RULES
        .. "- Output ONLY the numbered questions, nothing else"
        .. avoidRepeat(old)
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
-- Forks a child that runs only the HTTPS call (with retries for transient
-- errors) and writes the result to a temp file, which the parent picks up
-- later. key identifies the job: a chapter title or a session key.
-- Returns true when a job is now running (or already was).
function Reflections:spawnJob(key, prompt_text, opts)
    opts = opts or {}
    if self._inflight[key] then return true end
    self._job_seq = self._job_seq + 1
    local result_path = string.format("/tmp/reflections_%s_%d_%d_%d.txt",
        self:getBookKey(), os.time(), self._job_seq, math.random(1000000))
    self._inflight[key] = {
        path = result_path,
        started = os.time(),
        partial = opts.partial and true or false,
        overwrite = opts.overwrite and true or false,
    }
    self._job_errors[key] = nil

    local api_key, models = self:getApiKey(), self:getModelChain()
    local pid = ffi.C.fork()
    if pid == 0 then
        -- Child: network only. Never touch UI, the document, or plugin state.
        -- pcall yields generate()'s (text) or (nil, err): keep the error,
        -- or every failure surfaces as a bare "nil".
        local okc, result, errmsg =
            pcall(Gemini.generate, api_key, models, prompt_text, 45, 1)
        local f = io.open(result_path, "w")
        if f then
            if okc and result then
                f:write("OK\n" .. key .. "\n" .. result)
            else
                f:write("ERR\n" .. key .. "\n" .. tostring(errmsg or result))
            end
            f:close()
        end
        ffi.C._exit(0)
    elseif pid > 0 then
        self._inflight[key].pid = pid
    else
        self._inflight[key] = nil -- fork failed
    end
    return true
end

function Reflections:launchGeneration(chapter_title, node, next_node, opts)
    opts = opts or {}
    if self._inflight[chapter_title] then return true end
    local kind = opts.kind or "previous"
    local ok, text = pcall(Chapters.getChapterText, self.ui, node, next_node, kind)
    if not ok or not text or #text < 50 then return false end
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildPrompt(
        info.title, info.author, chapter_title, text, self:getPromptCount(),
        opts.overwrite and self:readCachedPrompts(chapter_title) or nil)
    return self:spawnJob(chapter_title, prompt_text, opts)
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

-- ---------------------------------------------------------- session mode

-- A reading session is a user-picked range of finished chapters, e.g.
-- everything read tonight. Questions span the range: character arcs,
-- developing themes, one chapter reframing another.

function Reflections:getSessionKey(from_title, to_title)
    return from_title .. " → " .. to_title
end

-- Manual picker mode: "chapters" or "pages".
function Reflections:getSessionPickMode()
    local m = self:readDocSetting("reflections_session_pick_mode")
    if m == "pages" then return "pages" end
    return "chapters"
end

function Reflections:setSessionPickMode(mode)
    self:saveDocSetting("reflections_session_pick_mode", mode)
end

-- Page bounds for page-mode sessions; default to everything read so far.
function Reflections:getSessionPageBound(which)
    local b = self:readDocSetting("reflections_session_pages")
    if type(b) == "table" and tonumber(b[which]) then
        return tonumber(b[which])
    end
    if which == "from" then return 1 end
    return Chapters.getCurrentPage(self.ui)
end

function Reflections:setSessionPageBound(which, page)
    local b = self:readDocSetting("reflections_session_pages")
    if type(b) ~= "table" then b = {} end
    b[which] = tonumber(page) or 1
    self:saveDocSetting("reflections_session_pages", b)
end

function Reflections:editSessionPage(which, on_done)
    local current = self:getSessionPageBound(which)
    local max_page = Chapters.getCurrentPage(self.ui)
    local dialog
    dialog = InputDialog:new{
        title = which == "from" and _("From page") or _("To page"),
        input_hint = "1 to " .. tostring(max_page),
        input = tostring(current),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if on_done then on_done() end
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local n = tonumber(dialog:getInputText())
                        if n and n >= 1 and n <= max_page then
                            self:setSessionPageBound(which, math.floor(n))
                        end
                        UIManager:close(dialog)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Last-picked session bounds for this book; default to everything read.
function Reflections:getSessionBound(which)
    local b = self:readDocSetting("reflections_session")
    if type(b) == "table" and b[which] then return b[which] end
    local progress = self:getProgress()
    if #progress == 0 then return nil end
    if which == "from" then return progress[1].title end
    return progress[#progress].title
end

function Reflections:setSessionBound(which, title)
    local b = self:readDocSetting("reflections_session")
    if type(b) ~= "table" then b = {} end
    b[which] = title
    self:saveDocSetting("reflections_session", b)
end

function Reflections:getPastSessions()
    local s = self:readDocSetting("reflections_sessions")
    if type(s) ~= "table" then return {} end
    return s
end

function Reflections:recordSession(key, from_title, to_title, kind)
    local sessions = {}
    for _, s in ipairs(self:getPastSessions()) do
        if s.key ~= key then table.insert(sessions, s) end
    end
    table.insert(sessions, 1, {
        key = key, from = from_title, to = to_title, at = os.time(),
        kind = kind or "chapters",
    })
    while #sessions > 10 do table.remove(sessions) end
    self:saveDocSetting("reflections_sessions", sessions)
end

-- The currently active tracked reading session, if one was begun.
function Reflections:getActiveSession()
    local s = self:readDocSetting("reflections_active_session")
    if type(s) == "table" and s.from_idx then return s end
    return nil
end

-- Begin a reading session: remember where the reader is now. Ending it
-- later generates cross-chapter questions for everything read in between.
function Reflections:beginReadingSession()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local idx, node = Chapters.findChapter(self.ui, "current")
    if not idx or not node then
        UIManager:show(InfoMessage:new{
            text = _("Couldn't tell which chapter you're in."),
        })
        return
    end
    self:saveDocSetting("reflections_active_session", {
        book = self:getBookKey(),
        from_idx = idx,
        from_title = node.title,
        started_at = os.time(),
    })
    UIManager:show(InfoMessage:new{
        text = _("Reading session started at ") .. tostring(node.title)
            .. _(". End it from Tools > Reflections when you're done reading."),
    })
end

-- End the active reading session: generate questions for the chapters read
-- since it began, quietly. A notification pops up when they're ready in
-- the Sessions tab.
function Reflections:endReadingSession()
    local s = self:getActiveSession()
    if not s then return end
    self:saveDocSetting("reflections_active_session", nil)
    if s.book ~= self:getBookKey() then
        UIManager:show(InfoMessage:new{
            text = _("That session was started in another book, so it was discarded."),
        })
        return
    end
    local cur_idx, cur_node = Chapters.findChapter(self.ui, "current")
    cur_idx = cur_idx or s.from_idx
    local from_idx, to_idx = s.from_idx, cur_idx
    if from_idx > to_idx then from_idx, to_idx = to_idx, from_idx end
    -- If the session ends on the very first page of the last chapter, the
    -- reader hasn't really read it: roll the range back one chapter so its
    -- (unread) events can't shape the questions.
    if to_idx == cur_idx and cur_node and cur_node.page
        and to_idx > from_idx then
        local pos = Chapters.getCurrentPage(self.ui)
        if pos - tonumber(cur_node.page) < 1 then
            to_idx = to_idx - 1
        end
    end
    local flat = Chapters.getChapterList(self.ui)
    local from_node, to_node = flat[from_idx], flat[to_idx]
    if not from_node or not to_node then return end
    local from_title, to_title = from_node.title, to_node.title
    -- The final chapter may still be in progress: only text up to the
    -- reading position goes out (spoiler-safe), like chapter generation.
    local text_idx = (to_idx == cur_idx) and cur_idx or nil
    local ok, text = pcall(Chapters.getRangeText, self.ui,
        from_idx, to_idx, nil, nil, text_idx)
    if not ok or not text or #text < 50 then
        UIManager:show(InfoMessage:new{
            text = _("Could not extract enough chapter text."),
        })
        return
    end
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local key = self:getSessionKey(from_title, to_title)
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildSessionPrompt(info.title, info.author,
        from_title, to_title, text, self:getSessionPromptCount())
    -- Stop any stale job for this key first, like the manual flow does.
    local old_job = self._inflight[key]
    if old_job then
        pcall(function()
            if old_job.pid then
                ffi.C.kill(old_job.pid, SIGKILL)
                ffi.C.waitpid(old_job.pid, nil, 0)
            end
        end)
        pcall(os.remove, old_job.path)
        self._inflight[key] = nil
    end
    self:recordSession(key, from_title, to_title)
    -- Quiet: no prompts page. When the result lands, the reader gets a
    -- notification pointing at the Sessions tab instead.
    self._pending = {
        title = key,
        old = self:readCachedPrompts(key),
        waited = 0,
        quiet = true,
    }
    local regen = function()
        self:generateForSession(from_title, to_title, true)
    end
    self._pending.regen = regen
    self:spawnJob(key, prompt_text, { overwrite = true })
    self:pollPendingPrompts()
end

-- Range picker: choose the first and last chapter of the session from the
-- finished chapters, then generate. Past sessions are listed for re-reading.
function Reflections:showSessionPicker()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local progress = self:getProgress()
    if #progress == 0 and self:getSessionPickMode() ~= "pages" then
        UIManager:show(InfoMessage:new{
            text = _("No finished chapters yet. Read a little first, then come back."),
        })
        return
    end
    local Menu = require("ui/widget/menu")
    local menu
    local function chapterChoices(which)
        local t = {}
        for _, e in ipairs(progress) do
            local title = e.title
            table.insert(t, {
                text = title,
                callback = function()
                    UIManager:close(menu)
                    self:setSessionBound(which, title)
                    self:showSessionPicker()
                end,
            })
        end
        return t
    end
    local items = {
        {
            text = _("Generate session questions"),
            callback = function()
                UIManager:close(menu)
                if self:getSessionPickMode() == "pages" then
                    self:generateForPageSession(
                        self:getSessionPageBound("from"),
                        self:getSessionPageBound("to"), false)
                else
                    self:generateForSession(self:getSessionBound("from"),
                        self:getSessionBound("to"), false)
                end
            end,
        },
        {
            text_func = function()
                if self:getSessionPickMode() == "pages" then
                    return _("Pick by: Pages")
                end
                return _("Pick by: Chapters")
            end,
            callback = function()
                UIManager:close(menu)
                if self:getSessionPickMode() == "pages" then
                    self:setSessionPickMode("chapters")
                else
                    self:setSessionPickMode("pages")
                end
                self:showSessionPicker()
            end,
        },
    }
    if self:getSessionPickMode() == "pages" then
        table.insert(items, {
            text_func = function()
                return _("From page: ")
                    .. tostring(self:getSessionPageBound("from"))
            end,
            callback = function()
                UIManager:close(menu)
                self:editSessionPage("from", function()
                    self:showSessionPicker()
                end)
            end,
        })
        table.insert(items, {
            text_func = function()
                return _("To page: ")
                    .. tostring(self:getSessionPageBound("to"))
            end,
            callback = function()
                UIManager:close(menu)
                self:editSessionPage("to", function()
                    self:showSessionPicker()
                end)
            end,
        })
    else
        table.insert(items, {
            text_func = function()
                return _("From: ") .. tostring(self:getSessionBound("from"))
            end,
            sub_item_table = chapterChoices("from"),
        })
        table.insert(items, {
            text_func = function()
                return _("To: ") .. tostring(self:getSessionBound("to"))
            end,
            sub_item_table = chapterChoices("to"),
        })
    end
    table.insert(items, {
        text_func = function()
            return _("Questions: ")
                .. tostring(self:getSessionPromptCount())
        end,
        callback = function()
            UIManager:close(menu)
            self:editPromptCount("session", function()
                self:showSessionPicker()
            end)
        end,
    })
    for _, s in ipairs(self:getPastSessions()) do
        local sess = s
        table.insert(items, {
            text = sess.key,
            callback = function()
                UIManager:close(menu)
                local cached = self:readCachedPrompts(sess.key)
                local regen
                if sess.kind == "pages" then
                    regen = function()
                        self:generateForPageSession(sess.from, sess.to, true)
                    end
                else
                    regen = function()
                        self:generateForSession(sess.from, sess.to, true)
                    end
                end
                if cached then
                    self:showSessionPrompts(sess.key, sess.from, sess.to,
                        cached, { from_cache = true, regen = regen })
                elseif sess.kind == "pages" then
                    self:generateForPageSession(sess.from, sess.to, false)
                else
                    self:generateForSession(sess.from, sess.to, false)
                end
            end,
        })
    end
    table.insert(items, {
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    })
    menu = Menu:new{
        title = _("Session questions"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

-- Sessions tab: past reading sessions with the date and time each was
-- generated, plus the manual chapter-range picker.
function Reflections:showSessionsScreen()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local Menu = require("ui/widget/menu")
    local menu
    local items = {
        {
            text = _("Pick chapters manually…"),
            callback = function()
                UIManager:close(menu)
                self:showSessionPicker()
            end,
        },
    }
    for _, s in ipairs(self:getPastSessions()) do
        local sess = s
        local label
        if sess.at then
            label = os.date("%b %d, %I:%M %p", sess.at) .. " · " .. sess.key
        else
            label = sess.key
        end
        table.insert(items, {
            text = label,
            callback = function()
                UIManager:close(menu)
                local cached = self:readCachedPrompts(sess.key)
                local regen
                if sess.kind == "pages" then
                    regen = function()
                        self:generateForPageSession(sess.from, sess.to, true)
                    end
                else
                    regen = function()
                        self:generateForSession(sess.from, sess.to, true)
                    end
                end
                if cached then
                    self:showSessionPrompts(sess.key, sess.from, sess.to,
                        cached, { from_cache = true, regen = regen })
                elseif self._inflight[sess.key] then
                    UIManager:show(InfoMessage:new{
                        text = _("Still generating, check back in a moment."),
                    })
                elseif sess.kind == "pages" then
                    self:generateForPageSession(sess.from, sess.to, false)
                else
                    self:generateForSession(sess.from, sess.to, false)
                end
            end,
            hold_callback = function()
                UIManager:close(menu)
                if sess.kind == "pages" then
                    self:generateForPageSession(sess.from, sess.to, true)
                else
                    self:generateForSession(sess.from, sess.to, true)
                end
            end,
        })
    end
    table.insert(items, {
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    })
    menu = Menu:new{
        title = _("Sessions"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

-- Standalone Settings screen, also reachable from Tools > Reflections.
function Reflections:showSettingsScreen()
    local Menu = require("ui/widget/menu")
    local menu
    local function countRow(label, kind, get)
        return {
            text_func = function()
                return label .. tostring(get(self))
            end,
            callback = function()
                UIManager:close(menu)
                self:editPromptCount(kind, function()
                    self:showSettingsScreen()
                end)
            end,
        }
    end
    local items = {
        {
            text_func = function()
                local k = self:getApiKey()
                if k ~= "" then
                    -- Fingerprint, not the key: enough to spot a typo.
                    local fp = k:sub(1, 6) .. "..." .. k:sub(-4)
                        .. " (" .. #k .. " chars)"
                    return _("Gemini API key: set [") .. fp .. "]"
                end
                return _("Gemini API key: missing")
            end,
            callback = function() self:editApiKey() end,
        },
        countRow(_("Prompts per chapter: "), "chapter",
            Reflections.getPromptCount),
        countRow(_("Prompts per session: "), "session",
            Reflections.getSessionPromptCount),
        countRow(_("Prompts per book reflection: "), "book",
            Reflections.getBookPromptCount),
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
                UIManager:close(menu)
                G_reader_settings:saveSetting(
                    "reflections_background", not self:getBackgroundEnabled())
                self:showSettingsScreen()
            end,
        },
        {
            text = _("Clear cached reflections"),
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                local CheckButton = require("ui/widget/checkbutton")
                local Screen = require("device").screen
                local keep_sessions = false
                local check = CheckButton:new{
                    text = _("Keep previous sessions"),
                    checked = false,
                    -- Explicit width: CheckButton has no parent at
                    -- construction time to measure against, so without
                    -- this it crashes (checkbutton.lua).
                    width = Screen:scaleBySize(300),
                    callback = function()
                        keep_sessions = not keep_sessions
                    end,
                }
                local dialog = ConfirmBox:new{
                    text = _("This will delete all generated reflections for this book: chapter prompts, session questions, and the book reflection.\n\nYour previous sessions list will be deleted too, unless you keep it below.\n\nHit OK to proceed."),
                    ok_text = _("OK"),
                    ok_callback = function()
                        self:clearCache(keep_sessions)
                        UIManager:close(menu)
                        self:showSettingsScreen()
                    end,
                }
                dialog:addWidget(check)
                UIManager:show(dialog)
            end,
        },
        {
            text = _("Close"),
            callback = function() UIManager:close(menu) end,
        },
    }
    menu = Menu:new{
        title = _("Settings"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

-- Generate (or show cached) questions for a chapter range. Never blocks the
-- UI: the prompts page opens immediately with a placeholder and fills in
-- when the forked job's result lands.
function Reflections:generateForSession(from_title, to_title, force)
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    from_title = from_title or self:getSessionBound("from")
    to_title = to_title or self:getSessionBound("to")
    local from_idx = from_title and Chapters.findIndexByTitle(self.ui, from_title)
    local to_idx = to_title and Chapters.findIndexByTitle(self.ui, to_title)
    if not from_idx or not to_idx then
        UIManager:show(InfoMessage:new{
            text = _("Could not find those chapters in this book."),
        })
        return
    end
    if from_idx > to_idx then -- picked backwards: swap rather than complain
        from_idx, to_idx = to_idx, from_idx
        from_title, to_title = to_title, from_title
    end
    local key = self:getSessionKey(from_title, to_title)
    local regen = function()
        self:generateForSession(from_title, to_title, true)
    end
    if not force then
        local cached = self:readCachedPrompts(key)
        if cached then
            self:showSessionPrompts(key, from_title, to_title, cached,
                { from_cache = true, regen = regen })
            return
        end
    end

    -- No fork support (never happens on real devices): synchronous fallback.
    if not ffi_ok then
        self:generateForSessionSync(key, from_title, to_title,
            from_idx, to_idx, regen)
        return
    end

    -- Regenerating while a job is already running: stop the old one first.
    if force then
        local old_job = self._inflight[key]
        if old_job then
            pcall(function()
                if old_job.pid then
                    ffi.C.kill(old_job.pid, SIGKILL)
                    ffi.C.waitpid(old_job.pid, nil, 0)
                end
            end)
            pcall(os.remove, old_job.path)
            self._inflight[key] = nil
        end
    end

    self:showSessionPrompts(key, from_title, to_title,
        _("Generating your prompts…"), { placeholder = true, regen = regen })
    self._pending = {
        title = key,
        old = self:readCachedPrompts(key),
        waited = 0,
        session = true,
        regen = regen,
    }
    local ok, text = pcall(Chapters.getRangeText, self.ui, from_idx, to_idx)
    if not ok or not text or #text < 50 then
        self._pending = nil
        self:showSessionPrompts(key, from_title, to_title,
            _("Could not extract enough chapter text."), { regen = regen })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildSessionPrompt(info.title, info.author,
        from_title, to_title, text, self:getSessionPromptCount(),
        force and self:readCachedPrompts(key) or nil)
    self:spawnJob(key, prompt_text, { overwrite = force })
    self:recordSession(key, from_title, to_title)
    self:pollPendingPrompts()
end

-- Synchronous fallback used only when fork() is unavailable.
-- Page-based session questions: like generateForSession but for an explicit
-- page range instead of chapters. Handy for books without a TOC and for
-- ranges that don't line up with chapter boundaries.
function Reflections:generateForPageSession(from_page, to_page, force)
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local max_page = Chapters.getCurrentPage(self.ui)
    from_page = math.max(1, tonumber(from_page) or 1)
    to_page = math.min(tonumber(to_page) or max_page, max_page)
    if from_page > to_page then -- picked backwards: swap rather than complain
        from_page, to_page = to_page, from_page
    end
    local key = "Pages " .. from_page .. "-" .. to_page
    local from_label, to_label = "page " .. from_page, "page " .. to_page
    local regen = function()
        self:generateForPageSession(from_page, to_page, true)
    end
    if not force then
        local cached = self:readCachedPrompts(key)
        if cached then
            self:showSessionPrompts(key, from_label, to_label, cached,
                { from_cache = true, regen = regen })
            return
        end
    end

    -- No fork support (never happens on real devices): synchronous fallback.
    if not ffi_ok then
        self:generateForPageSessionSync(key, from_label, to_label,
            from_page, to_page, regen)
        return
    end

    if force then
        local old_job = self._inflight[key]
        if old_job then
            pcall(function()
                if old_job.pid then
                    ffi.C.kill(old_job.pid, SIGKILL)
                    ffi.C.waitpid(old_job.pid, nil, 0)
                end
            end)
            pcall(os.remove, old_job.path)
            self._inflight[key] = nil
        end
    end

    self:showSessionPrompts(key, from_label, to_label,
        _("Generating your prompts…"), { placeholder = true, regen = regen })
    self._pending = {
        title = key,
        old = self:readCachedPrompts(key),
        waited = 0,
        session = true,
        regen = regen,
    }
    local ok, text = pcall(Chapters.getPageRangeText, self.ui,
        from_page, to_page)
    if not ok or not text or #text < 50 then
        self._pending = nil
        self:showSessionPrompts(key, from_label, to_label,
            _("Could not extract enough page text."), { regen = regen })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildSessionPrompt(info.title, info.author,
        from_label, to_label, text, self:getSessionPromptCount(),
        force and self:readCachedPrompts(key) or nil)
    self:spawnJob(key, prompt_text, { overwrite = force })
    self:recordSession(key, from_page, to_page, "pages")
    self:pollPendingPrompts()
end

function Reflections:generateForPageSessionSync(key, from_label, to_label,
    from_page, to_page, regen)
    local busy = InfoMessage:new{ text = _("Generating reflection prompts...") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local text = Chapters.getPageRangeText(self.ui, from_page, to_page)
    if not text or #text < 50 then
        UIManager:close(busy)
        UIManager:show(InfoMessage:new{
            text = _("Could not extract enough page text."),
        })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildSessionPrompt(info.title, info.author,
        from_label, to_label, text, self:getSessionPromptCount())
    local result, err = Gemini.generate(self:getApiKey(), self:getModelChain(),
        prompt, 45, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Gemini request failed:\n") .. tostring(err),
        })
        return
    end
    self:cachePrompts(key, result, false)
    self:recordSession(key, from_page, to_page, "pages")
    self:showSessionPrompts(key, from_label, to_label, result,
        { from_cache = false, regen = regen })
end

function Reflections:generateForSessionSync(key, from_title, to_title,
    from_idx, to_idx, regen)
    local busy = InfoMessage:new{ text = _("Generating reflection prompts...") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local text = Chapters.getRangeText(self.ui, from_idx, to_idx)
    if not text or #text < 50 then
        UIManager:close(busy)
        UIManager:show(InfoMessage:new{
            text = _("Could not extract enough chapter text."),
        })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildSessionPrompt(info.title, info.author,
        from_title, to_title, text, self:getSessionPromptCount())
    local result, err = Gemini.generate(self:getApiKey(), self:getModelChain(),
        prompt, 45, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Gemini request failed:\n") .. tostring(err),
        })
        return
    end
    self:cachePrompts(key, result, false)
    self:recordSession(key, from_title, to_title)
    self:showSessionPrompts(key, from_title, to_title, result,
        { from_cache = false, regen = regen })
end

-- Prompts page for a session. Thin wrapper: the key doubles as the page
-- title, and New prompts regenerates this exact range.
function Reflections:showSessionPrompts(key, from_title, to_title, prompts, opt)
    if type(opt) ~= "table" then opt = { from_cache = opt } end
    if not opt.regen then
        opt.regen = function()
            self:generateForSession(from_title, to_title, true)
        end
    end
    self:showPrompts(key, prompts, opt)
end

-- --------------------------------------------- end-of-book reflection

-- One set of big-picture questions about the whole work, for when the
-- reader finishes the book: a closing ritual. Cached per book under its
-- own key (cleared with everything else by "Clear cached reflections");
-- "New prompts" regenerates.

function Reflections:getBookReflectionKey()
    return "book:reflection"
end

function Reflections:getBookReflectionTitle()
    local info = Chapters.getBookInfo(self.ui)
    return _("Reflection on ") .. tostring(info.title)
end

function Reflections:buildBookPrompt(title, author, text, n, old)
    local nf = self:isNonfiction()
    local organic_n, lenses, playful = bookPlan(n,
        nf and NONFICTION_BOOK_LENSES or nil)

    local function qword(c, one, many)
        if c == 1 then return "1 " .. one end
        return c .. " " .. many
    end

    local steps = {}
    if nf then
        table.insert(steps, "first write "
            .. qword(organic_n, "open-ended question", "open-ended questions")
            .. " about the book AS A WHOLE: how the central arguments develop "
            .. "from beginning to end, what the book is ultimately claiming, "
            .. "which ideas linger after the last page")
    else
        table.insert(steps, "first write "
            .. qword(organic_n, "open-ended question", "open-ended questions")
            .. " about the book AS A WHOLE: how characters changed from beginning "
            .. "to end, what the book is ultimately about, which moments or ideas "
            .. "linger after the last page")
    end

    if #lenses > 0 then
        local bits = {}
        for _, lens in ipairs(lenses) do
            table.insert(bits, "1 question about " .. lens)
        end
        table.insert(steps, "then write " .. table.concat(bits, ", "))
    end

    if playful then
        if nf then
            table.insert(steps, "finally write 1 playful, creative question: "
                .. "for example, asking for a better title for the book, which "
                .. "idea deserves its own TED talk, or a one-sentence dramatic "
                .. "summary of the whole book")
        else
            table.insert(steps, "finally write 1 playful, creative question: "
                .. "for example, asking for a better title for the book, casting "
                .. "choices for a movie version, or a one-sentence dramatic "
                .. "summary of the whole story")
        end
    end

    local intro
    if nf then
        intro = "You are a reading companion helping someone reflect on a "
            .. "nonfiction book they just finished. They will answer with pen "
            .. "and paper in a physical journal, so make each question "
            .. "open-ended and worth writing about.\n\n"
    else
        intro = "You are a reading companion helping someone reflect on a book "
            .. "they just finished. They will answer with pen and paper in a "
            .. "physical journal, so make each question open-ended and worth "
            .. "writing about.\n\n"
    end
    local about_rule
    if nf then
        about_rule = "- About the ideas themselves: the author's arguments, evidence, key concepts, and real-world applications\n"
            .. "- Ask what to question or challenge, not just what to accept\n"
    else
        about_rule = "- About the story itself: its events, characters, choices, themes, and ideas\n"
            .. "- Never ask what the reader would do in a character's situation\n"
    end

    return intro
        .. "Book: \"" .. title .. "\" by " .. author .. "\n\n"
        .. "Book text (sampled across all chapters; the reader has finished "
        .. "the whole book, so nothing here is a spoiler):\n---\n"
        .. text .. "\n---\n\n"
        .. "Write exactly " .. tostring(n) .. " numbered discussion questions "
        .. "about the book as a whole, the kind a thoughtful book club "
        .. "would ask after everyone finished, in this order: "
        .. table.concat(steps, "; ") .. ". Rules:\n"
        .. about_rule
        .. "- Open-ended: no yes/no questions, no single correct answer\n"
        .. "- Never ask about the reader's own life, feelings, or experiences\n"
        .. "- Do not summarize the book\n"
        .. CRAFT_RULES
        .. "- Output ONLY the numbered questions, nothing else"
        .. avoidRepeat(old)
end

-- Small picker: generate the book reflection, adjust the question count,
-- or re-read the saved one.
function Reflections:showBookPicker()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local Menu = require("ui/widget/menu")
    local menu
    local key = self:getBookReflectionKey()
    local items = {}
    local cached = self:readCachedPrompts(key)
    if cached then
        table.insert(items, {
            text = _("Read saved reflection"),
            callback = function()
                UIManager:close(menu)
                self:showPrompts(self:getBookReflectionTitle(), cached,
                    { from_cache = true,
                      regen = function() self:generateForBook(true) end })
            end,
        })
    end
    table.insert(items, {
        text = _("Generate book reflection"),
        callback = function()
            UIManager:close(menu)
            self:generateForBook(false)
        end,
    })
    table.insert(items, {
        text_func = function()
            return _("Questions: ") .. tostring(self:getBookPromptCount())
        end,
        callback = function()
            UIManager:close(menu)
            self:editPromptCount("book", function()
                self:showBookPicker()
            end)
        end,
    })
    table.insert(items, {
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    })
    menu = Menu:new{
        title = _("End of book reflection"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

-- Generate (or show cached) big-picture questions for the whole book.
-- Never blocks the UI: the prompts page opens immediately with a
-- placeholder and fills in when the forked job's result lands.
function Reflections:generateForBook(force)
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        return
    end
    local key = self:getBookReflectionKey()
    local page_title = self:getBookReflectionTitle()
    local regen = function()
        self:generateForBook(true)
    end
    if not force then
        local cached = self:readCachedPrompts(key)
        if cached then
            self:showPrompts(page_title, cached,
                { from_cache = true, regen = regen })
            return
        end
    end

    -- No fork support (never happens on real devices): synchronous fallback.
    if not ffi_ok then
        self:generateForBookSync(key, page_title, regen)
        return
    end

    -- Regenerating while a job is already running: stop the old one first.
    if force then
        local old_job = self._inflight[key]
        if old_job then
            pcall(function()
                if old_job.pid then
                    ffi.C.kill(old_job.pid, SIGKILL)
                    ffi.C.waitpid(old_job.pid, nil, 0)
                end
            end)
            pcall(os.remove, old_job.path)
            self._inflight[key] = nil
        end
    end

    self:showPrompts(page_title, _("Generating your prompts…"),
        { placeholder = true, regen = regen })
    self._pending = {
        title = key,
        page_title = page_title,
        old = self:readCachedPrompts(key),
        waited = 0,
        regen = regen,
    }
    local ok, text = pcall(Chapters.getWholeBookText, self.ui)
    if not ok or not text or #text < 50 then
        self._pending = nil
        self:showPrompts(page_title,
            _("Could not extract enough text from this book."), { regen = regen })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt_text = self:buildBookPrompt(info.title, info.author,
        text, self:getBookPromptCount(),
        force and self:readCachedPrompts(key) or nil)
    self:spawnJob(key, prompt_text, { overwrite = force })
    self:pollPendingPrompts()
end

-- Synchronous fallback used only when fork() is unavailable.
function Reflections:generateForBookSync(key, page_title, regen)
    local busy = InfoMessage:new{ text = _("Generating reflection prompts...") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local text = Chapters.getWholeBookText(self.ui)
    if not text or #text < 50 then
        UIManager:close(busy)
        UIManager:show(InfoMessage:new{
            text = _("Could not extract enough text from this book."),
        })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildBookPrompt(info.title, info.author,
        text, self:getBookPromptCount())
    local result, err = Gemini.generate(self:getApiKey(), self:getModelChain(),
        prompt, 45, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Gemini request failed:\n") .. tostring(err),
        })
        return
    end
    self:cachePrompts(key, result, false)
    self:showPrompts(page_title, result,
        { from_cache = false, regen = regen })
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
        -- Sessions and book reflections render through the same prompts
        -- page; their New prompts button regenerates via the stored regen
        -- callback. page_title may differ from the cache/job key.
        local function showIt(prompts, opt)
            opt = opt or {}
            if my.regen then opt.regen = my.regen end
            self:showPrompts(my.page_title or my.title, prompts, opt)
        end
        local prompts = self:readCachedPrompts(my.title)
        local job_done = self._inflight[my.title] == nil
        if prompts and (prompts ~= my.old or job_done) then
            self._pending = nil
            if my.simplify then
                -- Throwaway reword job: keep it off the prompt cache and
                -- put the result on the open page, if it still wants it.
                self:deleteCachedPrompts(my.title)
                local page = self._open_prompts
                if page and page.simplify_on and not page.simplified then
                    page.simplified = prompts
                    self:showPrompts(page.title, prompts,
                        { display_only = true, from_cache = page.from_cache })
                end
            elseif my.quiet then
                -- Tracked reading session: no prompts page, just a
                -- notification pointing at the Sessions tab.
                UIManager:show(InfoMessage:new{
                    text = _("Session prompts have been generated and sent to the Sessions tab."),
                })
            else
                showIt(prompts, { from_cache = false })
            end
            return
        end
        local err = self._job_errors[my.title]
        if err then
            self._pending = nil
            self._job_errors[my.title] = nil
            if my.simplify then
                local page = self._open_prompts
                if page and page.simplify_on then
                    page.simplify_on = false
                    UIManager:show(InfoMessage:new{
                        text = _("Couldn't simplify right now."),
                    })
                    self:showPrompts(page.title, page.canonical,
                        { display_only = true, from_cache = page.from_cache })
                end
            elseif my.quiet then
                UIManager:show(InfoMessage:new{
                    text = _("Session prompts failed: ") .. tostring(err),
                })
            else
                showIt(_("Gemini request failed: ") .. tostring(err),
                    { is_error = true })
            end
            return
        end
        my.waited = my.waited + 2
        if my.waited >= 330 then
            self._pending = nil
            if my.simplify then
                local page = self._open_prompts
                if page and page.simplify_on then
                    page.simplify_on = false
                    UIManager:show(InfoMessage:new{
                        text = _("Couldn't simplify right now."),
                    })
                    self:showPrompts(page.title, page.canonical,
                        { display_only = true, from_cache = page.from_cache })
                end
            elseif my.quiet then
                UIManager:show(InfoMessage:new{
                    text = _("Session prompts are taking too long. Check your connection and try again."),
                })
            else
                showIt(_("Gemini is taking too long. Check your connection and try again."),
                    { is_error = true })
            end
            return
        end
        self:pollPendingPrompts()
    end)
end

function Reflections:cancelPending(chapter_title)
    if self._pending and (self._pending.title == chapter_title
        or self._pending.page_title == chapter_title) then
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
    local from_cache, placeholder, display_only, is_error
    if type(opt) == "table" then
        from_cache, placeholder = opt.from_cache, opt.placeholder
        display_only = opt.display_only
        is_error = opt.is_error
    else
        from_cache = opt
    end

    -- Normalize once: blank line between numbered questions.
    prompts = self:normalizeSpacing(prompts)

    -- Per-page simplify state. Rebuilding the same page (placeholder swaps,
    -- simplify toggles) keeps it; opening a different page starts fresh.
    local prev = self._open_prompts
    local same_page = prev and prev.title == chapter_title
    -- A fresh result landing while simplify is on gets reworded automatically.
    local auto_simplify = same_page and prev.simplify_on
        and not placeholder and not display_only and not is_error

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
    local CheckButton = require("ui/widget/checkbutton")

    -- Page state, computed before the dialog so the toggle reflects it.
    local page = {
        title = chapter_title,
        from_cache = from_cache and true or false,
        simplify_on = false,
        canonical = nil, -- questions as generated (never the reworded text)
        simplified = nil, -- reworded questions, once fetched
        -- New prompts keeps working after toggle rebuilds (sessions, book).
        regen = (type(opt) == "table" and opt.regen)
            or (same_page and prev.regen) or nil,
    }
    if same_page then
        page.simplify_on = prev.simplify_on
        page.canonical = prev.canonical
        page.simplified = prev.simplified
        page.from_cache = prev.from_cache
        if not placeholder and not display_only and not is_error then
            -- Fresh canonical questions; any simplified text is stale now.
            page.canonical = prompts
            if prev.simplify_on then page.simplified = nil end
        end
    elseif not placeholder and not is_error then
        page.canonical = prompts
    end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(16)
    local title_h = Screen:scaleBySize(52)
    local buttons_h = Screen:scaleBySize(72)
    local text_h = sh - pad * 2 - title_h - pad - buttons_h - pad
    if text_h < Screen:scaleBySize(100) then
        text_h = Screen:scaleBySize(100)
    end

    -- Explicit width for the Simplify toggle: CheckButton has no parent
    -- at construction time to measure against, so without this it
    -- crashes (checkbutton.lua). The row is centered, so extra space
    -- is harmless.
    local toggle_w = Screen:scaleBySize(200)

    local body
    if placeholder or auto_simplify then
        -- auto_simplify shows its own status line while the reword runs
        body = auto_simplify and _("Simplifying…") or prompts
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
                        if page.regen then
                            page.regen()
                        else
                            self:generateForChapter(chapter_title, true)
                        end
                    end,
                },
                HorizontalSpan:new{ width = pad },
                CheckButton:new{
                    text = _("Simplify"),
                    checked = page.simplify_on,
                    -- Explicit width: CheckButton has no parent at
                    -- construction time to measure against, so without
                    -- this it crashes (checkbutton.lua).
                    width = toggle_w,
                    callback = function() self:toggleSimplify() end,
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
    page.dialog = dialog
    self._open_prompts = page
    UIManager:show(dialog)

    if auto_simplify then
        self:requestSimplify()
    end
end

-- ---------------------------------------------------------------- simplify

-- Blank line between numbered questions. The model sometimes returns them
-- single-spaced (notably session prompts); display reads better
-- double-spaced, so enforce it everywhere, including saved prompts.
function Reflections:normalizeSpacing(text)
    if type(text) ~= "string" or text == "" then return text end
    local t = text:gsub("\n\n\n+", "\n\n")
    t = t:gsub("([^\n])\n(%d+[%.%)]%s)", "%1\n\n%2")
    return t
end

-- Build the reword prompt: the same questions, lighter and more relaxed.
-- Never dumbs them down, just easier to sit with.
function Reflections:buildSimplifyPrompt(questions)
    return "Reword these discussion questions to be simpler, lighter, and "
        .. "more relaxed. Keep the same substance, specificity, and details "
        .. "-- don't dumb them down, just make them easier to sit with on a "
        .. "quiet day. Output ONLY the numbered questions, nothing else.\n\n"
        .. "Questions:\n---\n" .. questions .. "\n---"
end

-- The Simplify switch on the prompts page. Scoped to the open page only:
-- it rewords the current questions in place, never the cached originals.
-- Regenerating while it is on rewords the fresh questions automatically.
function Reflections:toggleSimplify()
    local page = self._open_prompts
    if not page or not page.canonical then
        UIManager:show(InfoMessage:new{
            text = _("Wait for the questions to load first."),
        })
        return
    end
    if page.simplify_on then
        page.simplify_on = false
        self:showPrompts(page.title, page.canonical,
            { display_only = true, from_cache = page.from_cache })
    elseif page.simplified then
        page.simplify_on = true
        self:showPrompts(page.title, page.simplified,
            { display_only = true, from_cache = page.from_cache })
    else
        page.simplify_on = true
        self:showPrompts(page.title, _("Simplifying…"), { placeholder = true })
        self:requestSimplify()
    end
end

-- Reword the open page's canonical questions in a background job.
-- The result lives on the page only, never in the prompt cache.
function Reflections:requestSimplify()
    local page = self._open_prompts
    if not page or not page.canonical or not page.simplify_on then return end
    if self:getApiKey() == "" then
        page.simplify_on = false
        UIManager:show(InfoMessage:new{
            text = _("Set your Gemini API key first:\nReflections > Settings > Gemini API key"),
        })
        self:showPrompts(page.title, page.canonical,
            { display_only = true, from_cache = page.from_cache })
        return
    end
    local prompt = self:buildSimplifyPrompt(page.canonical)
    if not ffi_ok then
        -- Synchronous fallback (never happens on real devices).
        local okc, result =
            pcall(Gemini.generate, self:getApiKey(), self:getModelChain(),
                prompt, 45, 1)
        if okc and result then
            page.simplified = result
            self:showPrompts(page.title, result,
                { display_only = true, from_cache = page.from_cache })
        else
            page.simplify_on = false
            UIManager:show(InfoMessage:new{
                text = _("Couldn't simplify right now."),
            })
            self:showPrompts(page.title, page.canonical,
                { display_only = true, from_cache = page.from_cache })
        end
        return
    end
    local key = "\0simplify:" .. page.title .. ":" .. tostring(os.time())
    self._pending = { title = key, old = nil, waited = 0, simplify = true }
    self:spawnJob(key, prompt, { overwrite = true })
    self:pollPendingPrompts()
end

-- Drop a cached entry (used for the throwaway simplify job results).
function Reflections:deleteCachedPrompts(key)
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        local cache = ds:readSetting("reflections_cache")
        if type(cache) == "table" then
            cache[key] = nil
            ds:saveSetting("reflections_cache", cache)
            if ds.flush then ds:flush() end
        end
    end)
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
        text = _("Close"),
        callback = function() UIManager:close(menu) end,
    })

    menu = Menu:new{
        title = _("Reflections"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    -- Start on the last page: the reader lands on the latest chapters.
    menu:switchItemTable(nil, nil, #items)
    UIManager:show(menu)
end

function Reflections:addToMainMenu(menu_items)
    menu_items.reflections = {
        text = _("Reflections"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getSubMenuItems() end,
    }
end

-- Tools > Reflections opens this submenu; each entry opens its own screen.
-- The Begin/End session entry is rebuilt every time so its label always
-- reflects whether a reading session is active.
function Reflections:getSubMenuItems()
    local toggle_text = _("Begin a reading session")
    local active = self:getActiveSession()
    if active then
        toggle_text = _("End session (started ")
            .. os.date("%I:%M %p", active.started_at) .. ")"
    end
    return {
        {
            text = _("Chapters"),
            callback = function() self:showMainScreen() end,
        },
        {
            text = _("Sessions"),
            callback = function() self:showSessionsScreen() end,
        },
        {
            text = _("End of book reflection…"),
            callback = function() self:showBookPicker() end,
        },
        {
            text = toggle_text,
            callback = function()
                if self:getActiveSession() then
                    self:endReadingSession()
                else
                    self:beginReadingSession()
                end
            end,
        },
        {
            text_func = function()
                if self:isNonfiction() then
                    return _("Mode: Nonfiction")
                end
                return _("Mode: Fiction")
            end,
            callback = function()
                self:setNonfiction(not self:isNonfiction())
            end,
        },
        {
            text = _("Settings"),
            callback = function() self:showSettingsScreen() end,
        },
    }
end

return Reflections
