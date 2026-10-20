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
-- Seconds a single generation attempt may run before the provider is
-- given up on. Heavier reasoning models think for a long while before
-- answering, so this is generous; the foreground watcher and the
-- background reaper below are sized to outlast one retry at this cap.
local REQUEST_TIMEOUT = 300
local DEFAULT_PROMPT_COUNT = 3
local DEFAULT_SESSION_PROMPT_COUNT = 6
local DEFAULT_BOOK_PROMPT_COUNT = 6
local MAX_PROMPT_COUNT = 20

-- AI providers. Gemini keeps its own wire format; every other
-- provider speaks the OpenAI chat format and is just a base URL plus
-- a key and a model. Keys and models are stored per provider, so
-- switching back and forth loses nothing.
local AI_PROVIDERS = {
    { id = "gemini", label = "Gemini" },
    { id = "openai", label = "OpenAI",
        base_url = "https://api.openai.com/v1",
        default_model = "gpt-4o-mini",
        model_hint = "e.g. gpt-4o-mini" },
    { id = "anthropic", label = "Anthropic (Claude)",
        base_url = "https://api.anthropic.com/v1",
        default_model = "claude-sonnet-4-5",
        model_hint = "e.g. claude-sonnet-4-5" },
    { id = "deepseek", label = "DeepSeek",
        base_url = "https://api.deepseek.com/v1",
        default_model = "deepseek-chat",
        model_hint = "e.g. deepseek-chat" },
    { id = "openrouter", label = "OpenRouter",
        base_url = "https://openrouter.ai/api/v1",
        default_model = "meta-llama/llama-3.3-70b-instruct:free",
        model_hint = "e.g. deepseek/deepseek-chat" },
    { id = "nvidia", label = "NVIDIA NIM",
        base_url = "https://integrate.api.nvidia.com/v1",
        default_model = "z-ai/glm-5.3-flash",
        model_hint = "e.g. z-ai/glm-5.3-flash" },
    { id = "xai", label = "xAI (Grok)",
        base_url = "https://api.x.ai/v1",
        default_model = "grok-4",
        model_hint = "e.g. grok-4" },
    { id = "groq", label = "Groq",
        base_url = "https://api.groq.com/openai/v1",
        default_model = "llama-3.3-70b-versatile",
        model_hint = "e.g. llama-3.3-70b-versatile" },
    { id = "mistral", label = "Mistral",
        base_url = "https://api.mistral.ai/v1",
        default_model = "mistral-small-latest",
        model_hint = "e.g. mistral-small-latest" },
    { id = "together", label = "Together",
        base_url = "https://api.together.xyz/v1",
        default_model = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        model_hint = "e.g. meta-llama/Llama-3.3-70B-Instruct-Turbo" },
    { id = "perplexity", label = "Perplexity",
        base_url = "https://api.perplexity.ai",
        default_model = "sonar",
        model_hint = "e.g. sonar" },
    { id = "custom", label = "Custom (OpenAI compatible)",
        default_model = "",
        model_hint = "Model id for your endpoint" },
}

local function providerById(id)
    for _, p in ipairs(AI_PROVIDERS) do
        if p.id == id then return p end
    end
    return AI_PROVIDERS[1]
end

-- Languages the generated questions can be written in. The label is
-- what the Settings picker shows; the name is how the prompt refers
-- to the language, in English so every model reads it the same way.
local LANGUAGES = {
    { id = "en", label = "English", name = "English" },
    { id = "es", label = "Español", name = "Spanish" },
    { id = "fr", label = "Français", name = "French" },
    { id = "de", label = "Deutsch", name = "German" },
    { id = "it", label = "Italiano", name = "Italian" },
    { id = "pt", label = "Português", name = "Portuguese" },
    { id = "nl", label = "Nederlands", name = "Dutch" },
    { id = "pl", label = "Polski", name = "Polish" },
    { id = "sv", label = "Svenska", name = "Swedish" },
    { id = "ru", label = "Русский", name = "Russian" },
    { id = "uk", label = "Українська", name = "Ukrainian" },
    { id = "tr", label = "Türkçe", name = "Turkish" },
    { id = "ar", label = "العربية", name = "Arabic" },
    { id = "hi", label = "हिन्दी", name = "Hindi" },
    { id = "ja", label = "日本語", name = "Japanese" },
    { id = "ko", label = "한국어", name = "Korean" },
    { id = "zh", label = "简体中文", name = "Simplified Chinese" },
}

local function languageById(id)
    for _, l in ipairs(LANGUAGES) do
        if l.id == id then return l end
    end
    return LANGUAGES[1]
end

-- Reasoning levels for the heavier models: how much thinking a model
-- may do before it answers. Auto sends no control at all, which is
-- exactly how the plugin behaved before this setting existed.
local REASONING_LEVELS = {
    { id = "auto", label = "Auto" },
    { id = "off", label = "Off" },
    { id = "low", label = "Low" },
    { id = "medium", label = "Medium" },
    { id = "high", label = "High" },
}

local function reasoningById(id)
    for _, r in ipairs(REASONING_LEVELS) do
        if r.id == id then return r end
    end
    return REASONING_LEVELS[1]
end

local function trimValue(v)
    if type(v) ~= "string" then return "" end
    return v:gsub("^%s+", ""):gsub("%s+$", "")
end


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
    -- Background generation used to default on. With paid providers
    -- supported, it is opt-in now: turn a previously saved "on" off
    -- exactly once, existing installs included, before any seeding
    -- below. Installs that never saved a choice fall through to the
    -- new default in getBackgroundEnabled, and the Settings toggle
    -- rules for everyone afterwards.
    if not G_reader_settings:readSetting("reflections_bg_default_reset") then
        if G_reader_settings:readSetting("reflections_background") == true then
            G_reader_settings:saveSetting("reflections_background", false)
        end
        G_reader_settings:saveSetting("reflections_bg_default_reset", true)
    end
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
    -- Provider pre-configuration: the active provider, plus each
    -- provider's key and model, seed exactly like everything else,
    -- so any provider can be set up from a computer before install.
    if type(cfg.provider) == "string" then
        for _, p in ipairs(AI_PROVIDERS) do
            if p.id == cfg.provider then
                seed("reflections_provider", cfg.provider)
            end
        end
    end
    for _, p in ipairs(AI_PROVIDERS) do
        if p.id ~= "gemini" then
            seed("reflections_key_" .. p.id, cfg[p.id .. "_api_key"])
            seed("reflections_model_" .. p.id, cfg[p.id .. "_model"])
        end
    end
    seed("reflections_custom_base_url", cfg.custom_base_url)
    if type(cfg.language) == "string" then
        for _, l in ipairs(LANGUAGES) do
            if l.id == cfg.language then
                seed("reflections_language", cfg.language)
            end
        end
    end
    if type(cfg.reasoning) == "string" then
        for _, r in ipairs(REASONING_LEVELS) do
            if r.id == cfg.reasoning then
                seed("reflections_reasoning", cfg.reasoning)
            end
        end
    end
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

function Reflections:getProviderId()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_provider")
    end
    if type(v) == "string" then
        for _, p in ipairs(AI_PROVIDERS) do
            if p.id == v then return v end
        end
    end
    return "gemini"
end

function Reflections:getProviderLabel()
    return providerById(self:getProviderId()).label
end

function Reflections:requestFailedText(err)
    return self:getProviderLabel() .. " request failed:\n"
        .. tostring(err)
end

-- The Gemini key: device setting, then the preconfigured file value.
function Reflections:getGeminiKey()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_gemini_key")
    end
    if not v or v == "" then
        v = self:getFileConfig().api_key
    end
    -- E-ink keyboards love stray spaces: never send them to a provider.
    return trimValue(v)
end

-- The API key for whichever provider is active.
function Reflections:getApiKey()
    local id = self:getProviderId()
    if id == "gemini" then return self:getGeminiKey() end
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_key_" .. id)
    end
    return trimValue(v)
end

function Reflections:getCustomBaseUrl()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_custom_base_url")
    end
    return (trimValue(v):gsub("/+$", ""))
end

-- Everything a generation call needs, in the shape the client module
-- dispatches on: for Gemini the key plus the fallback model chain,
-- for the OpenAI family the key, one model, and a base URL.
function Reflections:getAIConfig()
    local id = self:getProviderId()
    if id == "gemini" then
        return { kind = "gemini", label = "Gemini",
            api_key = self:getGeminiKey(),
            models = self:getModelChain(),
            reasoning = self:getReasoningEffort() }
    end
    local p = providerById(id)
    local config = { kind = "openai", label = p.label,
        provider_id = id,
        api_key = self:getApiKey(), model = self:getModel(),
        base_url = p.base_url,
        reasoning = self:getReasoningEffort() }
    if id == "custom" then
        config.base_url = self:getCustomBaseUrl()
    elseif id == "openrouter" then
        config.extra_headers = {
            ["X-Title"] = "Reflections (KOReader)",
        }
    end
    return config
end

-- Language for the generated questions: device setting, then the
-- preconfigured file value, then English. Unknown ids fall back to
-- English rather than producing a broken prompt.
function Reflections:getQuestionLanguage()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_language")
    end
    if type(v) == "string" then
        for _, l in ipairs(LANGUAGES) do
            if l.id == v then return v end
        end
    end
    v = self:getFileConfig().language
    if type(v) == "string" then
        for _, l in ipairs(LANGUAGES) do
            if l.id == v then return v end
        end
    end
    return "en"
end

function Reflections:getQuestionLanguageLabel()
    return languageById(self:getQuestionLanguage()).label
end

function Reflections:getQuestionLanguageName()
    return languageById(self:getQuestionLanguage()).name
end

-- Reasoning level for generation calls: device setting, then the
-- preconfigured file value, then Auto. Unknown values fall back to
-- Auto rather than sending a control the provider would reject.
function Reflections:getReasoningEffort()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_reasoning")
    end
    if type(v) == "string" then
        for _, r in ipairs(REASONING_LEVELS) do
            if r.id == v then return v end
        end
    end
    v = self:getFileConfig().reasoning
    if type(v) == "string" then
        for _, r in ipairs(REASONING_LEVELS) do
            if r.id == v then return v end
        end
    end
    return "auto"
end

function Reflections:getReasoningLabel()
    return reasoningById(self:getReasoningEffort()).label
end

-- Rule injected into every question prompt. Empty for English, so
-- English prompts stay exactly as they have always been; cached
-- questions keep the language they were generated in, new ones use
-- the current choice.
function Reflections:getLanguageRule()
    local id = self:getQuestionLanguage()
    if id == "en" then return "" end
    return "- Write every question in " .. languageById(id).name
        .. ". Use natural, native phrasing, and keep book, chapter, "
        .. "and character names exactly as they appear in the text\n"
end

function Reflections:keySetupMessage()
    return _("Set your ") .. self:getProviderLabel()
        .. _(" API key first:\nReflections > Settings > API key")
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
    local id = self:getProviderId()
    if id ~= "gemini" then
        local v
        if G_reader_settings then
            v = G_reader_settings:readSetting("reflections_model_" .. id)
        end
        if not v or v == "" then
            v = providerById(id).default_model
        end
        return v or ""
    end
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

-- The model to generate with: exactly the one the user chose. There
-- is deliberately no fallback chain; if the chosen model is overloaded,
-- the request is retried and then reported, never silently handed to
-- a different model. (The name is kept from when this returned a
-- chain; the client still accepts a list.)
function Reflections:getModelChain()
    return { self:getModel() }
end

function Reflections:getBackgroundEnabled()
    local v
    if G_reader_settings then
        v = G_reader_settings:readSetting("reflections_background")
    end
    if v == nil then v = self:getFileConfig().background end
    -- Off by default: generation spends API quota (and, on paid
    -- providers, money) silently, so it is opt-in from Settings.
    if v == nil then return false end
    return v
end

function Reflections:editApiKey()
    local provider_id = self:getProviderId()
    local label = self:getProviderLabel()
    local current = self:getApiKey()
    local dialog
    dialog = InputDialog:new{
        title = label .. _(" API key"),
        input_hint = _("Paste your ") .. label .. _(" API key"),
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
                        if provider_id == "gemini" then
                            G_reader_settings:saveSetting(
                                "reflections_gemini_key", v)
                        else
                            G_reader_settings:saveSetting(
                                "reflections_key_" .. provider_id, v)
                        end
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
    local provider_id = self:getProviderId()
    local label = self:getProviderLabel()
    local current = self:getModel()
    local dialog
    dialog = InputDialog:new{
        title = label .. _(" model"),
        input_hint = providerById(provider_id).model_hint
            or _("e.g. gemini-3.8-flash"),
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
                        if provider_id == "gemini" then
                            if v == "" then v = DEFAULT_MODEL end
                            G_reader_settings:saveSetting(
                                "reflections_model", v)
                        else
                            G_reader_settings:saveSetting(
                                "reflections_model_" .. provider_id, v)
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reflections:editBaseUrl()
    local current = self:getCustomBaseUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("API base URL"),
        input_hint = _("e.g. http://192.168.1.10:1234/v1"),
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
                            :gsub("/+$", "")
                        G_reader_settings:saveSetting(
                            "reflections_custom_base_url", v)
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
--
-- Global generations: "clear for all books" bumps a counter in
-- G_reader_settings instead of touching every book's file. Per-book data
-- tagged with an older generation reads as empty and is deleted lazily.
function Reflections:getCacheGeneration()
    return G_reader_settings:readSetting("reflections_cache_generation") or 0
end

function Reflections:getSessionsGeneration()
    return G_reader_settings:readSetting("reflections_sessions_generation") or 0
end

-- True when this book's cached prompts belong to the current generation.
function Reflections:isCacheValid()
    local gen = self:readDocSetting("reflections_cache_gen") or 0
    if gen == self:getCacheGeneration() then return true end
    local ds = self:getDocStore()
    pcall(function()
        if ds then
            ds:delSetting("reflections_cache")
            ds:delSetting("reflections_cache_gen")
            if ds.flush then ds:flush() end
        end
    end)
    return false
end

-- True when this book's sessions list belongs to the current generation.
function Reflections:isSessionsValid()
    local gen = self:readDocSetting("reflections_sessions_gen") or 0
    if gen == self:getSessionsGeneration() then return true end
    local ds = self:getDocStore()
    pcall(function()
        if ds then
            ds:delSetting("reflections_sessions")
            ds:delSetting("reflections_sessions_gen")
            if ds.flush then ds:flush() end
        end
    end)
    return false
end

function Reflections:readCachedPrompts(chapter_title)
    if not self:isCacheValid() then return nil end
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return nil end
    local entry = cache[chapter_title]
    if type(entry) == "string" then return entry end
    if type(entry) == "table" then return entry.text end
    return nil
end

function Reflections:isPartialCache(chapter_title)
    if not self:isCacheValid() then return false end
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return false end
    local entry = cache[chapter_title]
    return type(entry) == "table" and entry.partial == true
end

function Reflections:cachePrompts(chapter_title, prompts, partial,
    provider_label)
    local ds = self:getDocStore()
    if not ds then return end
    pcall(function()
        local cache = ds:readSetting("reflections_cache") or {}
        -- The provider stamp names whoever generated the set. Callers
        -- that just generated pass it explicitly; callers rewriting a
        -- set (a one question swap) pass nothing and the original
        -- stamp survives.
        local old = cache[chapter_title]
        local provider = provider_label
            or (type(old) == "table" and old.provider) or nil
        cache[chapter_title] = { text = prompts, partial = partial and true or false,
            at = os.time(), provider = provider }
        ds:saveSetting("reflections_cache", cache)
        ds:saveSetting("reflections_cache_gen", self:getCacheGeneration())
        if ds.flush then ds:flush() end
    end)
end

-- Which provider generated a set (nil for sets cached before provider
-- stamps existed, and for sets adopted from orphaned result files,
-- whose origin is genuinely unknown).
function Reflections:readCachedProvider(key)
    if not self:isCacheValid() then return nil end
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return nil end
    local entry = cache[key]
    if type(entry) == "table" and type(entry.provider) == "string"
        and entry.provider ~= "" then
        return entry.provider
    end
    return nil
end

-- When a set was generated (nil for sets cached before timestamps existed).
function Reflections:readCachedAt(key)
    if not self:isCacheValid() then return nil end
    local cache = self:readDocSetting("reflections_cache")
    if type(cache) ~= "table" then return nil end
    local entry = cache[key]
    if type(entry) == "table" and type(entry.at) == "number" then
        return entry.at
    end
    return nil
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

-- Forget cached prompts (and optionally sessions) for ALL books by bumping
-- the global generations; per-book data from older generations reads empty.
function Reflections:clearAllCaches(keep_sessions)
    pcall(function()
        G_reader_settings:saveSetting("reflections_cache_generation",
            self:getCacheGeneration() + 1)
        if not keep_sessions then
            G_reader_settings:saveSetting("reflections_sessions_generation",
                self:getSessionsGeneration() + 1)
        end
        if G_reader_settings.flush then G_reader_settings:flush() end
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
    .. "- A two-part question must CLOSE with a direct question: a why "
    .. "('why did [character] [action]?'), a judgment ('was [character] "
    .. "right to [choice]?'), or a what-would-you-do. Never close a "
    .. "two-part question by observing what a moment reveals, suggests, "
    .. "or shows about something\n"
    .. "- Spread the set across the chapter: no two questions about the "
    .. "same scene, choice, line, or image. Dig past the chapter's most "
    .. "obvious dramatic beats; quieter moments often make the best "
    .. "questions\n"
    .. "- Questions do not have to be deep or philosophical, but each one "
    .. "has to open something: if a question's honest answer is obvious "
    .. "and fits in a few words, skip it, whatever the size of the moment. "
    .. "Light questions about small moments are welcome when they invite "
    .. "noticing, wondering, or comparing\n"
    .. "- At least one question should zoom in on a single moment, choice, "
    .. "or line rather than a broad theme\n"
    .. "- Don't embed the answer in the question; leave the conclusion "
    .. "genuinely open\n"

-- When regenerating, show the model what it already asked so it asks
-- different questions instead of rewording the same ones.
local function avoidRepeat(old)
    if not old or old == "" then return "" end
    return "\nThe reader already saw these questions:\n---\n" .. old
        .. "\n---\nAsk DIFFERENT questions. Do not reuse any scene, "
        .. "choice, line, or image the questions above touched; pick "
        .. "different moments entirely, from different angles."
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
            .. self:getLanguageRule()
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
        .. self:getLanguageRule()
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

-- The playful question rotates through archetypes, one picked per
-- generation. Listing several examples in the prompt made the model grab
-- the same one every time (casting choices), so the prompt only ever
-- names the one archetype picked here.
local PLAYFUL_SESSION = {
    "asking for a better title for one of the chapters",
    "casting choices for a movie version of a scene",
    "a one-sentence dramatic summary of the session",
    "asking which character from these chapters the reader would want "
        .. "to have dinner with, and what they would ask them",
    "asking what song should play over the end of the last chapter, "
        .. "and why",
    "a one-sentence pitch that would make a friend pick up this book",
}
local PLAYFUL_SESSION_NF = {
    "asking for a better title for one of the chapters",
    "asking which idea deserves its own TED talk",
    "a one-sentence dramatic summary of the session",
    "asking the reader to explain one idea from these chapters to a "
        .. "smart ten-year-old",
    "asking which claim from these chapters would make the best "
        .. "debate motion",
    "a bumper-sticker version of one idea from these chapters",
}
local PLAYFUL_BOOK = {
    "asking for a better title for the book",
    "casting choices for a movie version",
    "a one-sentence dramatic summary of the whole story",
    "asking which character the reader would want to have dinner with, "
        .. "and what they would ask them",
    "asking what song should play over the final scene, and why",
    "a one-sentence pitch that would make a friend pick up this book",
}
local PLAYFUL_BOOK_NF = {
    "asking for a better title for the book",
    "asking which idea deserves its own TED talk",
    "a one-sentence dramatic summary of the whole book",
    "asking the reader to explain the book's biggest idea to a smart "
        .. "ten-year-old",
    "asking which claim from the book would make the best debate motion",
    "a bumper-sticker version of the book's core idea",
}

local function pickPlayful(pool)
    return pool[math.random(#pool)]
end

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
        table.insert(steps, "finally write 1 playful, creative question: "
            .. pickPlayful(nf and PLAYFUL_SESSION_NF or PLAYFUL_SESSION))
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
        .. self:getLanguageRule()
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
-- fork() children are unreliable on Android: they can wedge in the
-- network stack, and a blocking waitpid() on the UI thread then freezes
-- the whole reader on "Generating your prompts...". Android therefore
-- uses the synchronous request path everywhere (X-RAY's Gemini requests
-- are synchronous on every platform, which is why the same key works
-- there); the network and keys are proven fine, the fork is the problem.
function Reflections:isAndroid()
    local ok, dev = pcall(require, "device")
    return ok and dev and type(dev.isAndroid) == "function"
        and dev:isAndroid() or false
end

function Reflections:shouldFork()
    return ffi_ok and not self:isAndroid()
end

-- Stop a forked job without ever blocking the UI thread: SIGKILL, a few
-- non-blocking reaps, then abandon the pid if it still won't die. A
-- wedged child must never freeze the reader on waitpid().
function Reflections:stopJob(job)
    if not job or not ffi_ok then return end
    pcall(os.remove, job.path)
    if not job.pid then return end
    pcall(function() ffi.C.kill(job.pid, SIGKILL) end)
    local ok_sock, socket = pcall(require, "socket")
    for _ = 1, 10 do
        local done = ffi.C.waitpid(job.pid, nil, WNOHANG)
        if done == job.pid or done == -1 then return end
        if ok_sock and socket and socket.sleep then
            pcall(socket.sleep, 0.05)
        end
    end
    -- Still alive: abandon it. init reaps the zombie when KOReader exits.
end

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

    local ai_config = self:getAIConfig()
    -- Remember which provider is doing the work, so the finished set
    -- can be stamped with it even if the setting changes meanwhile.
    self._inflight[key].provider = ai_config.label
    local pid = ffi.C.fork()
    if pid == 0 then
        -- Child: network only. Never touch UI, the document, or plugin state.
        -- pcall yields generateAny()'s (text) or (nil, err): keep the error,
        -- or every failure surfaces as a bare "nil".
        local okc, result, errmsg =
            pcall(Gemini.generateAny, ai_config, prompt_text, REQUEST_TIMEOUT, 1)
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
    if not self:shouldFork() then return end -- no fork (or Android): falls back to tap-to-generate
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
            elseif os.time() - job.started > 700 then
                self:stopJob(job)
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
            self:cachePrompts(ctitle, body, job.partial and true or false, job.provider)
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
            text = self:keySetupMessage(),
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

    -- No fork support (Android never forks (unreliable there)): synchronous fallback.
    if not self:shouldFork() then
        self:generateForChapterSync(chapter_title, node, next_node, kind, opts.partial)
        return
    end

    -- Regenerating while a job is already running: stop the old one first so
    -- the new request isn't answered by the stale job.
    if force then
        local old_job = self._inflight[chapter_title]
        if old_job then
            self:stopJob(old_job)
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
    local result, err = Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    self:cachePrompts(chapter_title, result, partial and true or false, self:getProviderLabel())
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
    if not self:isSessionsValid() then return {} end
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
    self:saveDocSetting("reflections_sessions_gen", self:getSessionsGeneration())
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
            text = self:keySetupMessage(),
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
            text = self:keySetupMessage(),
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
        self:stopJob(old_job)
        self._inflight[key] = nil
    end
    self:recordSession(key, from_title, to_title)
    if not self:shouldFork() then
        -- Android: fork is unreliable, so run the request directly with a
        -- busy note (the user just tapped End session; a short wait is fine).
        local busy = InfoMessage:new{ text = _("Generating session prompts...") }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local result, err = Gemini.generateAny(self:getAIConfig(), prompt_text, REQUEST_TIMEOUT, 1)
        UIManager:close(busy)
        if result then
            self:cachePrompts(key, result, false, self:getProviderLabel())
            UIManager:show(InfoMessage:new{
                text = _("Session prompts have been generated and sent to the Sessions tab."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Session prompts failed: ") .. tostring(err),
            })
        end
        return
    end
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
            text = self:keySetupMessage(),
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
            text = self:keySetupMessage(),
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
function Reflections:showProviderPicker()
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    local current = self:getProviderId()
    for _i, p in ipairs(AI_PROVIDERS) do
        local entry_id, entry_label = p.id, p.label
        items[#items + 1] = {
            text = entry_label
                .. (entry_id == current and _(" (current)") or ""),
            callback = function()
                UIManager:close(menu)
                G_reader_settings:saveSetting("reflections_provider",
                    entry_id)
                self:showAISettingsScreen()
            end,
        }
    end
    menu = Menu:new{
        title = _("AI provider"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

function Reflections:showLanguagePicker()
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    local current = self:getQuestionLanguage()
    for _i, l in ipairs(LANGUAGES) do
        local entry_id, entry_label = l.id, l.label
        items[#items + 1] = {
            text = entry_label
                .. (entry_id == current and _(" (current)") or ""),
            callback = function()
                UIManager:close(menu)
                G_reader_settings:saveSetting("reflections_language",
                    entry_id)
                self:showSettingsScreen()
            end,
        }
    end
    menu = Menu:new{
        title = _("Question language"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

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
                return _("AI: ") .. self:getProviderLabel()
            end,
            callback = function()
                UIManager:close(menu)
                self:showAISettingsScreen()
            end,
        },
        {
            text_func = function()
                return _("Question language: ")
                    .. self:getQuestionLanguageLabel()
            end,
            callback = function()
                UIManager:close(menu)
                self:showLanguagePicker()
            end,
        },
        countRow(_("Prompts per chapter: "), "chapter",
            Reflections.getPromptCount),
        countRow(_("Prompts per session: "), "session",
            Reflections.getSessionPromptCount),
        countRow(_("Prompts per book reflection: "), "book",
            Reflections.getBookPromptCount),
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
            text = _("Clear cached reflections (all books)"),
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
                    text = _("This will delete all generated reflections for EVERY book: chapter prompts, session questions, and book reflections.\n\nPrevious sessions lists will be deleted too, unless you keep them below.\n\nHit OK to proceed."),
                    ok_text = _("OK"),
                    ok_callback = function()
                        self:clearAllCaches(keep_sessions)
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

function Reflections:showReasoningPicker()
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    local current = self:getReasoningEffort()
    for _i, r in ipairs(REASONING_LEVELS) do
        local entry_id, entry_label = r.id, r.label
        items[#items + 1] = {
            text = entry_label
                .. (entry_id == current and _(" (current)") or ""),
            callback = function()
                UIManager:close(menu)
                G_reader_settings:saveSetting("reflections_reasoning",
                    entry_id)
                self:showAISettingsScreen()
            end,
        }
    end
    menu = Menu:new{
        title = _("Reasoning"),
        item_table = items,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(menu)
end

-- The AI side of Settings, in its own submenu: provider, key, model,
-- reasoning, and background generation.
function Reflections:showAISettingsScreen()
    local Menu = require("ui/widget/menu")
    local menu
    local items = {
        {
            text_func = function()
                return _("AI provider: ") .. self:getProviderLabel()
            end,
            callback = function()
                UIManager:close(menu)
                self:showProviderPicker()
            end,
        },
        {
            text_func = function()
                local k = self:getApiKey()
                if k ~= "" then
                    -- Fingerprint, not the key: enough to spot a typo.
                    local fp = k:sub(1, 6) .. "..." .. k:sub(-4)
                        .. " (" .. #k .. " chars)"
                    return _("API key (") .. self:getProviderLabel()
                        .. _("): set [") .. fp .. "]"
                end
                return _("API key (") .. self:getProviderLabel()
                    .. _("): missing")
            end,
            callback = function() self:editApiKey() end,
        },
        {
            text_func = function()
                return _("Model: ") .. self:getModel()
            end,
            callback = function() self:editModel() end,
        },
        {
            text_func = function()
                return _("Reasoning: ") .. self:getReasoningLabel()
            end,
            callback = function()
                UIManager:close(menu)
                self:showReasoningPicker()
            end,
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
                self:showAISettingsScreen()
            end,
        },
        {
            text = _("Close"),
            callback = function() UIManager:close(menu) end,
        },
    }
    if self:getProviderId() == "custom" then
        -- The model row sits at position 3 (provider, key, model);
        -- the base URL belongs right under it.
        table.insert(items, 4, {
            text_func = function()
                local u = self:getCustomBaseUrl()
                if u == "" then u = _("not set") end
                return _("API base URL: ") .. u
            end,
            callback = function() self:editBaseUrl() end,
        })
    end
    menu = Menu:new{
        title = _("AI"),
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
            text = self:keySetupMessage(),
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

    -- No fork support (Android never forks (unreliable there)): synchronous fallback.
    if not self:shouldFork() then
        self:generateForSessionSync(key, from_title, to_title,
            from_idx, to_idx, regen)
        return
    end

    -- Regenerating while a job is already running: stop the old one first.
    if force then
        local old_job = self._inflight[key]
        if old_job then
            self:stopJob(old_job)
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
            text = self:keySetupMessage(),
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

    -- No fork support (Android never forks (unreliable there)): synchronous fallback.
    if not self:shouldFork() then
        self:generateForPageSessionSync(key, from_label, to_label,
            from_page, to_page, regen)
        return
    end

    if force then
        local old_job = self._inflight[key]
        if old_job then
            self:stopJob(old_job)
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
    local result, err = Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    self:cachePrompts(key, result, false, self:getProviderLabel())
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
    local result, err = Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    self:cachePrompts(key, result, false, self:getProviderLabel())
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
    -- Page sessions arrive as "page N" labels from the live flow and
    -- as raw numbers from the saved sessions list.
    local f = tonumber(from_title)
        or tonumber((tostring(from_title):match("^page (%d+)$")))
    local t = tonumber(to_title)
        or tonumber((tostring(to_title):match("^page (%d+)$")))
    if not opt.swap then
        if f and t then
            opt.swap = function(old)
                return self:fetchOnePageSessionQuestion(f, t, old)
            end
        else
            opt.swap = function(old)
                return self:fetchOneSessionQuestion(from_title, to_title, old)
            end
        end
    end
    if not opt.hl_scope then
        if f and t then
            opt.hl_scope = { kind = "pages", from = f, to = t }
        else
            opt.hl_scope = { kind = "session", from = from_title, to = to_title }
        end
    end
    if not opt.back_to then
        -- Session pages are reached from the Sessions screen, so Back
        -- belongs there, not at the chapter browser.
        opt.back_to = function()
            self:showSessionsScreen()
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
        table.insert(steps, "finally write 1 playful, creative question: "
            .. pickPlayful(nf and PLAYFUL_BOOK_NF or PLAYFUL_BOOK))
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
        .. self:getLanguageRule()
        .. "- Output ONLY the numbered questions, nothing else"
        .. avoidRepeat(old)
end

-- Small picker: generate the book reflection, adjust the question count,
-- or re-read the saved one.
function Reflections:showBookPicker()
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = self:keySetupMessage(),
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
                    { from_cache = true, cache_key = key,
                      swap = function(old) return self:fetchOneBookQuestion(old) end,
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
            text = self:keySetupMessage(),
        })
        return
    end
    local key = self:getBookReflectionKey()
    local page_title = self:getBookReflectionTitle()
    local regen = function()
        self:generateForBook(true)
    end
    local function bookOpt(extra)
        local o = { cache_key = key,
            swap = function(old) return self:fetchOneBookQuestion(old) end,
            regen = regen }
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end
    if not force then
        local cached = self:readCachedPrompts(key)
        if cached then
            self:showPrompts(page_title, cached, bookOpt{ from_cache = true })
            return
        end
    end

    -- No fork support (Android never forks (unreliable there)): synchronous fallback.
    if not self:shouldFork() then
        self:generateForBookSync(key, page_title, regen)
        return
    end

    -- Regenerating while a job is already running: stop the old one first.
    if force then
        local old_job = self._inflight[key]
        if old_job then
            self:stopJob(old_job)
            self._inflight[key] = nil
        end
    end

    self:showPrompts(page_title, _("Generating your prompts…"),
        bookOpt{ placeholder = true })
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
            _("Could not extract enough text from this book."), bookOpt{})
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
    local result, err = Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    self:cachePrompts(key, result, false, self:getProviderLabel())
    self:showPrompts(page_title, result, { from_cache = false, regen = regen,
        cache_key = key,
        swap = function(old) return self:fetchOneBookQuestion(old) end })
end

-- Watches the forked job started by generateForChapter and swaps the
-- placeholder page for the real prompts (or a readable error) when it
-- lands. The UI stays responsive the whole time; pressing Back cancels
-- the watch while the job still caches silently in the background.
-- Floating notice shown while a foreground generation runs: a small
-- framed card in the middle of the screen with a Cancel button, so a
-- long wait on a heavy model is never a trap. It floats over the
-- prompts page rather than replacing it.
local InputContainerN = require("ui/widget/container/inputcontainer")
local GeomN = require("ui/geometry")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainerN = require("ui/widget/container/framecontainer")
local VerticalGroupN = require("ui/widget/verticalgroup")
local VerticalSpanN = require("ui/widget/verticalspan")
local TextWidgetN = require("ui/widget/textwidget")
local ButtonN = require("ui/widget/button")
local FontN = require("ui/font")
local BlitbufferN = require("ffi/blitbuffer")
local GenNotice = InputContainerN:extend{
    cancel_callback = nil,
}
function GenNotice:init()
    local Screen = require("device").screen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(16)
    local frame = FrameContainerN:new{
        background = BlitbufferN.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        padding = pad,
        VerticalGroupN:new{
            align = "center",
            TextWidgetN:new{
                text = _("Generating your prompts…"),
                face = FontN:getFace("cfont", 22),
            },
            VerticalSpanN:new{ width = pad },
            ButtonN:new{
                text = _("Cancel"),
                callback = function()
                    if self.cancel_callback then
                        self.cancel_callback()
                    end
                end,
            },
        },
    }
    self[1] = CenterContainer:new{
        dimen = GeomN:new{ x = 0, y = 0, w = sw, h = sh },
        frame,
    }
    self.dimen = GeomN:new{ x = 0, y = 0, w = sw, h = sh }
end

function Reflections:showGenNotice()
    if self._gen_notice then return end
    local notice = GenNotice:new{
        cancel_callback = function()
            -- Deferred, like every other page swap out of a button
            -- press: restoring the prompts page mid press is what
            -- wedged the highlights flow in v50 to v54.
            UIManager:scheduleIn(0, function()
                self:cancelGeneration()
            end)
        end,
    }
    self._gen_notice = notice
    UIManager:show(notice)
end

function Reflections:closeGenNotice()
    if self._gen_notice then
        pcall(UIManager.close, UIManager, self._gen_notice)
        self._gen_notice = nil
    end
end

-- The notice's Cancel button: kill the running job, stop the watcher,
-- and put the page back the way it was. Previous questions return on
-- a regen; a first generation simply closes back to the book.
function Reflections:cancelGeneration()
    local my = self._pending
    self:closeGenNotice()
    if not my then return end
    self._pending = nil
    local job = self._inflight[my.title]
    if job then
        self:stopJob(job)
        self._inflight[my.title] = nil
    end
    self._job_errors[my.title] = nil
    if my.old and my.old ~= "" then
        local opt = { from_cache = true }
        if my.regen then opt.regen = my.regen end
        if my.cache_key then opt.cache_key = my.cache_key end
        if my.swap then opt.swap = my.swap end
        if my.back_to then opt.back_to = my.back_to end
        self:showPrompts(my.page_title or my.title, my.old, opt)
    else
        self:closePromptsPage()
    end
end

function Reflections:pollPendingPrompts()
    local my = self._pending
    if not my then return end
    -- Page flows get the floating notice with its Cancel button.
    -- Quiet session ends and Simplify keep their current behavior:
    -- no card, nothing over the reading screen or the open page.
    if not my.quiet and not my.simplify and not my._notice then
        my._notice = true
        self:showGenNotice()
    end
    UIManager:scheduleIn(2, function()
        if self._pending ~= my then return end -- superseded or cancelled
        pcall(function() self:reapBackgroundJobs() end)
        -- Sessions and book reflections render through the same prompts
        -- page; their New prompts button regenerates via the stored regen
        -- callback. page_title may differ from the cache/job key.
        local function showIt(prompts, opt)
            opt = opt or {}
            if my.regen then opt.regen = my.regen end
            if my.cache_key then opt.cache_key = my.cache_key end
            if my.swap then opt.swap = my.swap end
            if my.back_to then opt.back_to = my.back_to end
            self:showPrompts(my.page_title or my.title, prompts, opt)
        end
        local prompts = self:readCachedPrompts(my.title)
        local job_done = self._inflight[my.title] == nil
        if prompts and (prompts ~= my.old or job_done) then
            self._pending = nil
            self:closeGenNotice()
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
            self:closeGenNotice()
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
                showIt(self:getProviderLabel() .. " request failed: " .. tostring(err),
                    { is_error = true })
            end
            return
        end
        my.waited = my.waited + 2
        if my.waited >= 660 then
            self._pending = nil
            self:closeGenNotice()
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
                showIt(_(self:getProviderLabel() .. " is taking too long. Check your connection and try again."),
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
        -- Leaving the page dismisses the notice too. The job itself
        -- keeps running and caches silently, as Back has always done;
        -- killing the job is the notice button's job, not Back's.
        self:closeGenNotice()
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
            text = self:keySetupMessage(),
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
-- ------------------------------------------------------------- prompts page

-- Standbys for anything the generated questions did not prompt,
-- behind the "Journaling Extras" row at the bottom of the page.
function Reflections:showJournalingExtras()
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Journaling Extras\n\n"
            .. "A few standbys for anything the questions missed:\n\n"
            .. "Predict what happens next, and put odds on it.\n\n"
            .. "Who changed the most this time, even a little?\n\n"
            .. "Confused? Write it down. The book may answer it later.\n\n"
            .. "What stuck? A line, a scene, anything that stayed "
            .. "with you.\n\n"
            .. "One small detail that felt deliberate. Note it, no "
            .. "theory needed.\n\n"
            .. "Dear future you: one sentence on where things stand, "
            .. "for when you pick the book back up."),
    })
end

-- One tappable question on the prompts page, following KOReader's own
-- MenuItem pattern: a TextBoxWidget in an InputContainer whose tap range
-- is its own size. Taps land here; pans and swipes scroll the container
-- around it.
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local GeomQ = require("ui/geometry")
local TextBoxWidgetQ = require("ui/widget/textboxwidget")
local QuestionBlock = InputContainer:extend{
    text = nil,
    face = nil,
    width = nil,
    idx = nil,
    callback = nil,
}
function QuestionBlock:init()
    local tb = TextBoxWidgetQ:new{
        text = self.text,
        face = self.face,
        width = self.width,
    }
    self[1] = tb
    local size = tb:getSize()
    self.dimen = GeomQ:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapQuestion = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end
function QuestionBlock:onTapQuestion(arg, ges)
    if not self.dimen then return end
    if self.callback then self.callback(self.idx) end
    return true
end

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
        -- Cache key for this page; differs from the title only for the
        -- book reflection. Swap fetches one fresh question for this page.
        cache_key = (type(opt) == "table" and opt.cache_key)
            or (same_page and prev.cache_key) or chapter_title,
        swap = (type(opt) == "table" and opt.swap)
            or (same_page and prev.swap) or nil,
        -- Highlight questions: sessions carry their scope; chapter pages
        -- resolve it from the title.
        hl_scope = (type(opt) == "table" and opt.hl_scope)
            or (same_page and prev.hl_scope) or nil,
        -- Where Back goes when it isn't the chapter browser (the
        -- highlights page returns to the page it was opened from).
        back_to = (type(opt) == "table" and opt.back_to)
            or (same_page and prev.back_to) or nil,
    }
    if not page.hl_scope and not page.regen then
        page.hl_scope = { kind = "chapter", title = chapter_title }
    end
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

    local header = _("Grab your journal and a pen.")
    if from_cache then
        header = header .. " " .. _("(saved from earlier)")
    end
    local gen_at = not is_error and self:readCachedAt(page.cache_key)
    if gen_at then
        header = header .. "\n" .. _("Generated ")
            .. os.date("%b %d, %Y, %I:%M %p", gen_at)
        local gen_provider = self:readCachedProvider(page.cache_key)
        if gen_provider then
            header = header .. " (" .. gen_provider .. ")"
        end
    end

    local dialog
    local function doGoBack()
        self:cancelPending(chapter_title)
        local back_to = page.back_to
        self:closePromptsPage()
        if back_to then
            back_to()
        else
            self:showMainScreen()
        end
    end
    local function goBack()
        -- Highlights pages: leaving swaps one prompts page for
        -- another in the middle of the Back press, which can wedge
        -- the device (field reports v50 to v53: Back froze on this
        -- page only, fresh or cached). Let the press finish first;
        -- the same steps then run from the scheduler.
        if page.cache_key:sub(-12) == "::highlights" then
            UIManager:scheduleIn(0, doGoBack)
        else
            doGoBack()
        end
    end

    -- The questions body. A clean question set renders as one tappable
    -- block per question (a tap asks to swap that question) inside a
    -- scrollable container; the header rides along as a plain block.
    -- Placeholder, status, and error pages keep the plain scrolling text.
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local Geom = require("ui/geometry")
    local scroll_widget
    local use_blocks = false
    local display_qs
    if not placeholder and not auto_simplify and not is_error
        and page.canonical then
        display_qs = self:splitQuestions(prompts)
        if #display_qs > 0
            and #display_qs == #self:splitQuestions(page.canonical) then
            use_blocks = true
        end
    end
    if use_blocks then
        -- The container reserves 3 scrollbar widths on the right when
        -- the content scrolls vertically; blocks must fit inside that
        -- crop or the text gets clipped and a sideways scrollbar shows.
        local inner_w = sw - pad * 2 - 3 * Screen:scaleBySize(6)
        local content = { align = "left" }
        table.insert(content, TextBoxWidget:new{
            text = header,
            face = Font:getFace("cfont", 22),
            width = inner_w,
        })
        for i, q in ipairs(display_qs) do
            local idx = i
            table.insert(content, VerticalSpan:new{
                width = Screen:scaleBySize(26) })
            -- init() is not automatic: KOReader calls it explicitly
            -- (as Menu does for its items) because layout needs the
            -- TextBoxWidget measured first.
            local block = QuestionBlock:new{
                text = idx .. ". " .. q,
                face = Font:getFace("cfont", 22),
                width = inner_w,
                idx = idx,
                callback = function() self:askSwapQuestion(idx) end,
            }
            block:init()
            table.insert(content, block)
        end
        -- A quiet extra under the last question: standbys for anything
        -- the generated questions did not prompt.
        table.insert(content, VerticalSpan:new{
            width = Screen:scaleBySize(26) })
        local tips = QuestionBlock:new{
            text = _("Journaling Extras ›"),
            face = Font:getFace("cfont", 22),
            width = inner_w,
            idx = 0,
            callback = function() self:showJournalingExtras() end,
        }
        tips:init()
        table.insert(content, tips)
        scroll_widget = ScrollableContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sw - pad * 2, h = text_h },
            VerticalGroup:new(content),
        }
    else
        local body
        if placeholder or auto_simplify then
            -- auto_simplify shows its own status line while the reword runs
            body = auto_simplify and _("Simplifying…") or prompts
        else
            body = header .. "\n\n" .. prompts
        end
        -- Built separately so we can hand it the dialog reference
        -- ScrollTextWidget needs for its scrollbar refreshes.
        scroll_widget = ScrollTextWidget:new{
            text = body,
            face = Font:getFace("cfont", 22),
            width = sw - pad * 2,
            height = text_h,
        }
    end

    -- The button row: "Highlights" replaces the old "Swap one" button
    -- (tapping a question now handles swapping). Both appear only once
    -- there are questions on the page.
    local row_items = { align = "center" }
    table.insert(row_items, Button:new{
        text = _("New prompts"),
        callback = function()
            if page.regen then
                page.regen()
            else
                self:generateForChapter(chapter_title, true)
            end
        end,
    })
    -- Highlights button: always present on scoped question pages (a tap
    -- with no highlights shows a friendly note); tap-a-question now
    -- handles swapping, so the old "Swap one" button is gone.
    if page.canonical and page.hl_scope then
        table.insert(row_items, HorizontalSpan:new{ width = pad })
        table.insert(row_items, Button:new{
            text = _("Highlights"),
            callback = function()
                self:generateForHighlights(page.hl_scope, false)
            end,
        })
    end
    table.insert(row_items, HorizontalSpan:new{ width = pad })
    table.insert(row_items, CheckButton:new{
        text = _("Simplify"),
        checked = page.simplify_on,
        -- Explicit width: CheckButton has no parent at
        -- construction time to measure against, so without
        -- this it crashes (checkbutton.lua).
        width = toggle_w,
        callback = function() self:toggleSimplify() end,
    })
    table.insert(row_items, HorizontalSpan:new{ width = pad })
    table.insert(row_items, Button:new{
        text = _("Back"),
        callback = goBack,
    })

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
            HorizontalGroup:new(row_items),
        },
    }
    if use_blocks then
        -- Lets UIManager crop inner repaints to the scroll area, and
        -- points the container's scroll repaints at this dialog:
        -- without show_parent, scrolling moved the content internally
        -- but the screen never repainted (field report, v47).
        dialog.cropping_widget = scroll_widget
        scroll_widget.show_parent = dialog
    else
        scroll_widget.dialog = dialog
    end
    page.dialog = dialog
    self._open_prompts = page
    -- One prompts page at a time. Prompts pages used to stack: nothing
    -- closed the previous page, so prompts to prompts navigation (the
    -- highlights flow) piled fullscreen dialogs, each holding a full
    -- screen compose buffer, and Back only ever closed the top one.
    if prev and prev.dialog and prev.dialog ~= dialog then
        UIManager:close(prev.dialog)
    end
    UIManager:show(dialog)

    if auto_simplify then
        self:requestSimplify()
    end
end

-- -------------------------------------------------------------- swap one

-- Split a generated set ("1. ...\n\n2. ...") into bare question texts.
function Reflections:splitQuestions(text)
    local out, cur = {}, nil
    if type(text) ~= "string" then return out end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local rest = line:match("^%s*%d+[%.%)]%s+(.*)$")
        if rest then
            if cur then table.insert(out, cur) end
            cur = rest
        elseif cur and line:match("%S") then
            cur = cur .. " " .. line:gsub("^%s+", "")
        end
    end
    if cur then table.insert(out, cur) end
    return out
end

function Reflections:joinQuestions(questions)
    local parts = {}
    for i, q in ipairs(questions) do
        parts[i] = i .. ". " .. q
    end
    return table.concat(parts, "\n\n")
end

-- One fresh question for a chapter page, written against everything the
-- reader already has so it lands on a different moment.
function Reflections:fetchOneChapterQuestion(chapter_title, old)
    local node, next_node = Chapters.findNodeByTitle(self.ui, chapter_title)
    if not node then
        return nil, _("Could not find that chapter in this book.")
    end
    local kind = "previous"
    local _, cur = Chapters.findChapter(self.ui, "current")
    if cur and cur.title == chapter_title then kind = "current" end
    local text = Chapters.getChapterText(self.ui, node, next_node, kind)
    if not text or #text < 50 then
        return nil, _("Could not extract enough chapter text.")
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildPrompt(info.title, info.author,
        chapter_title, text, 1, old)
    return Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
end

function Reflections:fetchOneSessionQuestion(from_title, to_title, old)
    local from_idx = Chapters.findIndexByTitle(self.ui, from_title)
    local to_idx = Chapters.findIndexByTitle(self.ui, to_title)
    if not from_idx or not to_idx then
        return nil, _("Could not find those chapters in this book.")
    end
    if from_idx > to_idx then
        from_idx, to_idx = to_idx, from_idx
        from_title, to_title = to_title, from_title
    end
    local text = Chapters.getRangeText(self.ui, from_idx, to_idx)
    if not text or #text < 50 then
        return nil, _("Could not extract enough chapter text.")
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildSessionPrompt(info.title, info.author,
        from_title, to_title, text, 1, old)
    return Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
end

function Reflections:fetchOnePageSessionQuestion(from_page, to_page, old)
    local text = Chapters.getPageRangeText(self.ui, from_page, to_page)
    if not text or #text < 50 then
        return nil, _("Could not extract enough page text.")
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildSessionPrompt(info.title, info.author,
        "page " .. from_page, "page " .. to_page, text, 1, old)
    return Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
end

function Reflections:fetchOneBookQuestion(old)
    local text = Chapters.getWholeBookText(self.ui)
    if not text or #text < 50 then
        return nil, _("Could not extract enough text from this book.")
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildBookPrompt(info.title, info.author,
        text, 1, old)
    return Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
end

-- Tapping a question asks whether to swap it for a new one.
function Reflections:askSwapQuestion(idx)
    local page = self._open_prompts
    if not page or not page.canonical then return end
    local questions = self:splitQuestions(page.canonical)
    local q = questions[idx]
    if not q then return end
    local shown = q
    if #shown > 240 then shown = shown:sub(1, 240) .. "…" end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Swap this question for a new one?\n\n") .. shown,
        ok_text = _("Swap"),
        ok_callback = function() self:swapQuestion(idx) end,
        cancel_text = _("Cancel"),
    })
end

-- Replace one question in the open set with a fresh one and save the set.
-- Always a foreground request, like the Android generation paths: swap is
-- a deliberate tap, so a short wait behind a busy note is fine.
function Reflections:swapQuestion(idx)
    local page = self._open_prompts
    if not page or not page.canonical then return end
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = self:keySetupMessage(),
        })
        return
    end
    local fetch = page.swap
    if not fetch then
        -- Chapter pages carry no fetcher; rebuild it from the title.
        local title = page.title
        if Chapters.findNodeByTitle(self.ui, title) then
            fetch = function(old)
                return self:fetchOneChapterQuestion(title, old)
            end
        end
    end
    if not fetch then
        UIManager:show(InfoMessage:new{
            text = _("Can't swap a question on this page."),
        })
        return
    end
    local questions = self:splitQuestions(page.canonical)
    if idx < 1 or idx > #questions then return end

    local busy = InfoMessage:new{ text = _("Generating a new question...") }
    UIManager:show(busy)
    UIManager:forceRePaint()
    local result, err = fetch(page.canonical)
    UIManager:close(busy)
    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    local fresh = self:splitQuestions(result)
    if #fresh == 0 then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText("no usable question came back"),
        })
        return
    end
    questions[idx] = fresh[1]
    local joined = self:joinQuestions(questions)
    self:cachePrompts(page.cache_key, joined,
        self:isPartialCache(page.cache_key))
    self:showPrompts(page.title, joined, {
        from_cache = false,
        regen = page.regen,
        swap = page.swap,
        cache_key = page.cache_key,
    })
    -- The rebuilt page differs from the one it replaces in a single
    -- block, and the incremental repaint that follows can leave the
    -- old question ghosted under the new one on e-ink (field report:
    -- the swapped question rendered smeared until the page was
    -- reopened). Force one full repaint of the new page.
    if self._open_prompts and self._open_prompts.dialog then
        UIManager:setDirty(self._open_prompts.dialog, "full")
    end
end

-- --------------------------------------- highlight aware questions

-- Highlight annotations for this book, freshest source first: the live
-- annotation module (highlights reach doc settings only when saved),
-- then the persisted doc setting, then the legacy pre-annotation
-- storage (bookmarks carry the text, the highlights table the style).
function Reflections:readAnnotations()
    local ann = self.ui and self.ui.annotation
    if ann and type(ann.annotations) == "table" and #ann.annotations > 0 then
        return ann.annotations
    end
    local saved = self:readDocSetting("annotations")
    if type(saved) == "table" and #saved > 0 then return saved end
    return self:readLegacyAnnotations()
end

function Reflections:readLegacyAnnotations()
    local bookmarks = self:readDocSetting("bookmarks")
    local highlights = self:readDocSetting("highlight")
    if type(bookmarks) ~= "table" then return {} end
    local out = {}
    for _, bm in ipairs(bookmarks) do
        if bm.highlighted and type(bm.notes) == "string" and bm.notes ~= "" then
            local drawer = "lighten"
            local page_hl = type(highlights) == "table" and highlights[bm.page]
            if type(page_hl) == "table" then
                for _, hl in ipairs(page_hl) do
                    if hl.pos0 == bm.pos0 and hl.pos1 == bm.pos1 then
                        drawer = hl.drawer or drawer
                        break
                    end
                end
            end
            table.insert(out, {
                drawer = drawer,
                text = bm.notes,
                pos0 = bm.pos0,
                pos1 = bm.pos1,
                page = bm.page,
            })
        end
    end
    return out
end

-- The chapter boundaries a chapter/session scope covers. Page scopes
-- don't need nodes; they match on page numbers directly.
function Reflections:scopeRange(scope)
    if scope.kind == "chapter" then
        local node, next_node = Chapters.findNodeByTitle(self.ui, scope.title)
        if not node then return nil end
        return node, next_node
    elseif scope.kind == "session" then
        local from_node = Chapters.findNodeByTitle(self.ui, scope.from)
        local _, after_to = Chapters.findNodeByTitle(self.ui, scope.to)
        if not from_node then return nil end
        return from_node, after_to
    end
    return nil
end

-- True when an annotation is a highlight (not a bare bookmark) that
-- belongs to the scope. Highlights can only exist where the reader has
-- read, so this is spoiler safe by construction. Membership is decided
-- by ANY positive signal (KOReader's own chapter tag, the page range,
-- or the xpointer range): on real books each source can be missing or
-- subtly off on a given build, and a cascade of vetoes matched nothing
-- at all on a book full of highlights (field report, v48).
function Reflections:annotationInScope(ann, scope, start_node, end_node,
        ctx)
    if ann.drawer == nil then return false end
    if type(ann.text) ~= "string" or ann.text == "" then return false end
    local doc = self.ui and self.ui.document
    local pos = ann.pos0
    -- The annotation's page without touching the document's page map
    -- (resolving an xpointer to a page can force layout on real
    -- documents, so that is a last resort, done once at the bottom).
    local function ann_page_simple()
        return tonumber(ann.pageno) or tonumber(ann.page)
    end
    local function ann_page_resolved()
        local p = ann_page_simple()
        if not p and type(pos) == "string" and doc
            and doc.getPageFromXPointer then
            local okp, pp = pcall(function()
                return doc:getPageFromXPointer(pos)
            end)
            if okp then p = tonumber(pp) end
        end
        return p
    end
    if scope.kind == "pages" then
        local p = ann_page_resolved()
        return p ~= nil and p >= scope.from and p <= scope.to
    end
    -- The chapter title KOReader recorded on the annotation. For
    -- sessions, collectHighlights precomputes the in-range title set:
    -- resolving chapter indexes per annotation rebuilds the whole TOC
    -- three times per highlight and froze the reader on real books.
    if scope.kind == "chapter" and ann.chapter == scope.title then
        return true
    end
    if scope.kind == "session" and ctx and ctx.titles
        and ann.chapter and ctx.titles[ann.chapter] then
        return true
    end
    if not start_node then return false end
    -- Page numbers already on the annotation (no document work).
    local p = ann_page_simple()
    if p and start_node.page then
        if p >= start_node.page
            and (not end_node or not end_node.page
                or p < end_node.page) then
            return true
        end
    end
    -- XPointer range against the chapter boundaries (pure data
    -- comparison in the document engine).
    if type(pos) == "string" and start_node.xpointer and doc
        and type(doc.compareXPointers) == "function" then
        local okc, ge = pcall(doc.compareXPointers, doc,
            pos, start_node.xpointer)
        if okc and ge >= 0 then
            if not end_node then return true end
            local okc2, lt = pcall(doc.compareXPointers, doc,
                pos, end_node.xpointer)
            if okc2 and lt < 0 then return true end
        end
    end
    -- Last resort: resolve the xpointer to a page (can force layout).
    p = ann_page_resolved()
    if p and start_node.page then
        if p >= start_node.page
            and (not end_node or not end_node.page
                or p < end_node.page) then
            return true
        end
    end
    return false
end

local HL_MAX_PASSAGES = 12
local HL_MAX_CHARS = 8000

-- Highlight passages inside a scope, in reading order, evenly thinned
-- when there are more than the cap. Returns { text, chapter } entries.
function Reflections:collectHighlights(scope)
    local start_node, end_node
    local ctx = {}
    if scope.kind ~= "pages" then
        -- Nodes may be missing (an odd TOC); chapter title matching in
        -- annotationInScope can still find the scope's highlights.
        start_node, end_node = self:scopeRange(scope)
        if scope.kind == "session" then
            -- In-range chapter titles, computed ONCE. Resolving the
            -- indexes per annotation rebuilds the TOC three times per
            -- highlight and froze the reader on real books (v50 report).
            local list = Chapters.getChapterList(self.ui)
            local fi = Chapters.findIndexByTitle(self.ui, scope.from)
            local ti = Chapters.findIndexByTitle(self.ui, scope.to)
            ctx.titles = {}
            if fi and ti then
                if fi > ti then fi, ti = ti, fi end
                for i = fi, ti do
                    if list[i] then ctx.titles[list[i].title] = true end
                end
            end
        end
    end
    local anns = self:readAnnotations()
    local out, seen = {}, {}
    for _, ann in ipairs(anns) do
        if self:annotationInScope(ann, scope, start_node, end_node, ctx) then
            local dedupe = tostring(ann.pos0) .. "\n" .. ann.text
            if not seen[dedupe] then
                seen[dedupe] = true
                table.insert(out, { text = ann.text, chapter = ann.chapter })
            end
        end
    end
    if #out > HL_MAX_PASSAGES then
        local thinned = {}
        local step = #out / HL_MAX_PASSAGES
        for i = 0, HL_MAX_PASSAGES - 1 do
            thinned[#thinned + 1] = out[math.floor(i * step) + 1]
        end
        out = thinned
    end
    local total, kept = 0, {}
    for _, p in ipairs(out) do
        total = total + #p.text
        if total > HL_MAX_CHARS and #kept > 0 then break end
        kept[#kept + 1] = p
    end
    return kept
end

function Reflections:countHighlights(scope)
    return #self:collectHighlights(scope)
end

-- Highlights anywhere in the book, regardless of scope: distinguishes
-- "nothing to read" from "read fine, none matched this chapter".
function Reflections:countBookHighlights()
    local n = 0
    for _, ann in ipairs(self:readAnnotations()) do
        if ann.drawer ~= nil and type(ann.text) == "string"
            and ann.text ~= "" then
            n = n + 1
        end
    end
    return n
end

function Reflections:highlightTarget(scope)
    if scope.kind == "pages" then
        local base = "Pages " .. scope.from .. "-" .. scope.to
        return base, base .. "::highlights", "Highlights: " .. base
    end
    if scope.kind == "session" then
        local base = self:getSessionKey(scope.from, scope.to)
        return base, base .. "::highlights", "Highlights: " .. base
    end
    return scope.title, scope.title .. "::highlights",
        "Highlights: " .. scope.title
end

function Reflections:highlightScopeLabel(scope)
    if scope.kind == "pages" then
        return "pages " .. scope.from .. " to " .. scope.to
    end
    if scope.kind == "session" then
        return "the chapters \"" .. scope.from .. "\" to \"" .. scope.to .. "\""
    end
    return "the chapter \"" .. scope.title .. "\""
end

-- Questions grounded in the passages the reader chose to highlight.
function Reflections:buildHighlightPrompt(title, author, scope_label,
    passages, n, old)
    local blocks = {}
    for i, p in ipairs(passages) do
        local label = "Passage " .. i
        if type(p.chapter) == "string" and p.chapter ~= "" then
            label = label .. " (from \"" .. p.chapter .. "\")"
        end
        blocks[#blocks + 1] = label .. ":\n\"" .. p.text .. "\""
    end
    local passage_text = table.concat(blocks, "\n\n")
    local rules
    if self:isNonfiction() then
        rules = "A highlight is a vote: the reader marked each of these "
            .. "passages for a reason of their own, and each question "
            .. "helps them discover that reason and put it into words. "
            .. "Reasons a passage earns a mark in nonfiction:\n"
            .. "- a claim the reader wants to challenge or test\n"
            .. "- evidence or reasoning that genuinely persuaded them\n"
            .. "- an idea they want to keep, use, or act on\n"
            .. "- a concept that finally clicked into place\n"
            .. "- a passage that clashes with what they believed before\n"
            .. "- a step in the argument they do not yet follow\n"
            .. "Rules:\n"
            .. "- Ask about one passage per question; when there are more "
            .. "passages than questions, choose the ones with the most "
            .. "to ask about\n"
            .. "- Pick the most plausible reason for each passage, and "
            .. "vary the reasons across the set when the passages allow\n"
            .. "- Phrase each question as an invitation, not an "
            .. "assumption: name the likely pull and leave room for the "
            .. "reader's real reason to be a different one\n"
            .. "- Keep questions on the passage and the reader's thinking "
            .. "about it, never diary prompts detached from the text\n"
            .. "- Do not summarize the passages\n"
            .. "- Do not reveal or hint at anything not in the passages above\n"
    else
        rules = "A highlight is a vote: the reader marked each of these "
            .. "passages for a reason of their own, and each question "
            .. "helps them discover that reason and put it into words. "
            .. "Reasons a passage earns a mark in fiction:\n"
            .. "- the beauty of the wording itself\n"
            .. "- recognition: it said something the reader already felt "
            .. "or believed, in words they did not have\n"
            .. "- friction: they agree strongly, or want to push back\n"
            .. "- a detail that feels loaded, as if it will matter later\n"
            .. "- genuine confusion about what is happening, or why\n"
            .. "- a feeling the passage stirred in them\n"
            .. "- a moment simply worth keeping and returning to\n"
            .. "Rules:\n"
            .. "- Ask about one passage per question; when there are more "
            .. "passages than questions, choose the ones with the most "
            .. "to ask about\n"
            .. "- Pick the most plausible reason for each passage, and "
            .. "vary the reasons across the set when the passages allow\n"
            .. "- Phrase each question as an invitation, not an "
            .. "assumption: name the likely pull and leave room for the "
            .. "reader's real reason to be a different one\n"
            .. "- Keep questions on the passage and the reader's response "
            .. "to it, never diary prompts detached from the text\n"
            .. "- Do not summarize the passages\n"
            .. "- Do not reveal or hint at anything not in the passages above\n"
    end
    local intro
    if self:isNonfiction() then
        intro = "You are a reading companion helping someone think about "
            .. "the nonfiction book they just read. These are passages "
            .. "they chose to highlight while reading, the moments their "
            .. "own hand picked out of the whole book; they will answer "
            .. "with pen and paper in a physical journal, so make each "
            .. "question worth writing about.\n\n"
    else
        intro = "You are a reading companion helping someone think about "
            .. "the story they just read. These are passages they chose "
            .. "to highlight while reading, the moments their own hand "
            .. "picked out of the whole book; they will answer with pen "
            .. "and paper in a physical journal, so make each question "
            .. "worth writing about.\n\n"
    end
    return intro
        .. "Book: \"" .. title .. "\" by " .. author .. "\n\n"
        .. "Passages the reader highlighted in " .. scope_label
        .. " (in reading order):\n---\n" .. passage_text .. "\n---\n\n"
        .. "Write exactly " .. tostring(n) .. " numbered discussion "
        .. "questions grounded in these passages. " .. rules
        .. CRAFT_RULES
        .. self:getLanguageRule()
        .. "- Output ONLY the numbered questions, nothing else"
        .. avoidRepeat(old)
end

function Reflections:fetchOneHighlightQuestion(scope, old)
    local passages = self:collectHighlights(scope)
    if #passages == 0 then
        return nil, _("No highlights there anymore.")
    end
    local info = Chapters.getBookInfo(self.ui)
    local prompt = self:buildHighlightPrompt(info.title, info.author,
        self:highlightScopeLabel(scope), passages, 1, old)
    return Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
end

function Reflections:generateForHighlightsSync(scope, hl_key, hl_title,
    prompt, regen, swap, back_to)
    local busy = InfoMessage:new{
        text = _("Generating questions from your highlights...") }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local result, err = Gemini.generateAny(self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
    UIManager:close(busy)

    if not result then
        UIManager:show(InfoMessage:new{
            text = self:requestFailedText(err),
        })
        return
    end
    self:cachePrompts(hl_key, result, false, self:getProviderLabel())
    self:showPrompts(hl_title, result, { from_cache = false,
        cache_key = hl_key, regen = regen, swap = swap,
        back_to = back_to })
end

function Reflections:generateForHighlights(scope, force)
    if self:getApiKey() == "" then
        UIManager:show(InfoMessage:new{
            text = self:keySetupMessage(),
        })
        return
    end
    local _base, hl_key, hl_title = self:highlightTarget(scope)
    local regen = function()
        self:generateForHighlights(scope, true)
    end
    local swap = function(old)
        return self:fetchOneHighlightQuestion(scope, old)
    end
    -- Back from the highlights page returns to the page it was opened
    -- from, not the chapter browser.
    local back_to
    if scope.kind == "chapter" then
        back_to = function()
            self:generateForChapter(scope.title, false)
        end
    else
        local base_key = _base
        back_to = function()
            local prompts = self:readCachedPrompts(base_key)
            if prompts then
                self:showSessionPrompts(base_key, scope.from, scope.to,
                    prompts, { from_cache = true })
            else
                self:showMainScreen()
            end
        end
    end
    if not force then
        local cached = self:readCachedPrompts(hl_key)
        if cached then
            -- Deferred out of the tap: opening the cached set swaps
            -- the parent prompts page for a full questions page in
            -- the middle of the Highlights button press, which can
            -- wedge the device (field reports v50 to v53: the button
            -- froze only when a set was already cached). Fresh
            -- generation escapes it because its result page arrives
            -- from the poll timer instead. Same page, same content,
            -- shown once the press has finished.
            UIManager:scheduleIn(0, function()
                self:showPrompts(hl_title, cached, { from_cache = true,
                    cache_key = hl_key, regen = regen, swap = swap,
                    back_to = back_to })
            end)
            return
        end
    end
    local passages = self:collectHighlights(scope)
    if #passages == 0 then
        local total = self:countBookHighlights()
        local text
        if total > 0 then
            text = _("No highlights matched ")
                .. self:highlightScopeLabel(scope)
                .. _(". (This book has ") .. total
                .. _(" highlights saved elsewhere.)")
        else
            text = _("No highlights in this book yet. Highlight passages "
                .. "while you read and the Highlights button will use them.")
        end
        UIManager:show(InfoMessage:new{ text = text })
        return
    end
    local info = Chapters.getBookInfo(self.ui)
    -- Never ask for more questions than there are passages to ground
    -- them: one highlighted paragraph earns one question.
    local n = scope.kind == "chapter" and self:getPromptCount()
        or self:getSessionPromptCount()
    n = math.min(n, #passages)
    local prompt = self:buildHighlightPrompt(info.title, info.author,
        self:highlightScopeLabel(scope), passages, n,
        force and self:readCachedPrompts(hl_key) or nil)

    -- No fork support (Android never forks (unreliable there)):
    -- synchronous fallback.
    if not self:shouldFork() then
        self:generateForHighlightsSync(scope, hl_key, hl_title, prompt,
            regen, swap, back_to)
        return
    end

    if force then
        local old_job = self._inflight[hl_key]
        if old_job then
            self:stopJob(old_job)
            self._inflight[hl_key] = nil
        end
    end

    self:showPrompts(hl_title, _("Generating your prompts…"),
        { placeholder = true, cache_key = hl_key, regen = regen,
            swap = swap, back_to = back_to })
    self._pending = {
        title = hl_key,
        page_title = hl_title,
        old = self:readCachedPrompts(hl_key),
        waited = 0,
        regen = regen,
        cache_key = hl_key,
        swap = swap,
        back_to = back_to,
    }
    self:spawnJob(hl_key, prompt, { overwrite = force })
    self:pollPendingPrompts()
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
    local lang = ""
    if self:getQuestionLanguage() ~= "en" then
        lang = " Write the reworded questions in "
            .. self:getQuestionLanguageName() .. "."
    end
    return "Reword these discussion questions to be simpler, lighter, and "
        .. "more relaxed. Keep the same substance, specificity, and details "
        .. "-- don't dumb them down, just make them easier to sit with on a "
        .. "quiet day. Output ONLY the numbered questions, nothing else."
        .. lang .. "\n\n"
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
            text = self:keySetupMessage(),
        })
        self:showPrompts(page.title, page.canonical,
            { display_only = true, from_cache = page.from_cache })
        return
    end
    local prompt = self:buildSimplifyPrompt(page.canonical)
    if not self:shouldFork() then
        -- Synchronous fallback (Android never forks: unreliable there).
        local okc, result =
            pcall(Gemini.generateAny, self:getAIConfig(), prompt, REQUEST_TIMEOUT, 1)
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
        -- A dot for chapters with questions waiting: the cache check is
        -- per title, so finished and current chapters both show it.
        local done = self:readCachedPrompts(title) ~= nil
        table.insert(items, {
            text = (done and "● " or "") .. title,
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
            text = _("End of book reflection"),
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
