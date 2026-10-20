-- Gemini: minimal client for the Gemini generateContent REST API.
-- Request format follows the proven pattern from xray.koplugin.
-- Transient failures (rate limits, overloaded model, blips) are retried
-- with a short backoff so a busy moment doesn't surface as an error.

local Gemini = {}
local JSON = require("json")

-- Test hook: set to a function to avoid real sleeping in tests.
Gemini._sleep = nil

local function sleep_seconds(n)
    if Gemini._sleep then
        Gemini._sleep(n)
        return
    end
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then
        socket.sleep(n)
    else
        os.execute("sleep " .. tostring(tonumber(n) or 1))
    end
end

-- HTTP codes (and network-level failures, code nil) worth another attempt.
local function is_transient(code)
    return code == nil or code == 429 or code == 500 or code == 502 or code == 503
end

-- One raw POST of a JSON body over whichever transport this KOReader
-- build supports. Returns (response_text, http_code), or
-- (nil, error_message) when every transport failed.
local function http_post(url, headers, body, timeout)
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    pcall(function() socketutil:set_timeout(timeout, timeout) end)

    -- Transports to try in order. socket.http first: on current KOReader
    -- builds it handles https URLs (this is also what xray.koplugin uses,
    -- and it works on devices where ssl.https currently throws with no
    -- message). ssl.https stays as fallback for builds where that flips.
    local transports = {}
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http and http.request then
        transports[#transports + 1] = { name = "socket.http", fn = http.request }
    end
    local ok_https, https = pcall(require, "ssl.https")
    if ok_https and https and https.request then
        -- Some e-ink devices lack current CA bundles; keep requests working.
        pcall(function() https.cert_verify = false end)
        transports[#transports + 1] = { name = "ssl.https", fn = https.request }
    end
    if #transports == 0 then
        return nil, "HTTPS support is not available on this device"
    end

    local function new_sink(t)
        if socketutil.table_sink then return socketutil.table_sink(t) end
        return ltn12.sink.table(t)
    end

    local response_body = {}
    local request = {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = new_sink(response_body),
    }

    local ok, code, fail_detail
    for _, t in ipairs(transports) do
        response_body = {}
        request.sink = new_sink(response_body)
        local ok2, a, b = xpcall(function() return t.fn(request) end,
            function(e) return e end)
        if ok2 and a then
            ok, code = a, b
            fail_detail = nil
            break
        end
        -- This transport threw (a messageless crash on some devices) or
        -- returned a failure: name it and try the next one.
        fail_detail = t.name .. (ok2 and (" failed: " .. tostring(b))
            or " crashed with no error message")
        ok, code = nil, nil
    end
    pcall(function() socketutil:reset_timeout() end)
    if not ok then
        return nil, "request failed: " .. tostring(fail_detail)
    end
    return table.concat(response_body), code
end

-- Maps a reasoning level to a Gemini thinking budget in tokens.
-- Auto (and anything unknown) returns nil: no thinkingConfig is sent
-- and the model thinks exactly as much as it decides on its own.
function Gemini._thinkingBudget(level)
    if level == "off" then return 0 end
    if level == "low" then return 512 end
    if level == "medium" then return 2048 end
    if level == "high" then return 8192 end
    return nil
end

-- One Gemini attempt. Returns the text, or (nil, error message, http code).
function Gemini._request(api_key, model, prompt_text, timeout,
    thinking_budget)
    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
        .. model .. ":generateContent"

    local gen_config = {
        temperature = 0.7,
        maxOutputTokens = 1024,
    }
    if thinking_budget ~= nil then
        gen_config.thinkingConfig = { thinkingBudget = thinking_budget }
    end
    local body = JSON.encode({
        contents = {
            { parts = { { text = prompt_text } } },
        },
        generationConfig = gen_config,
    })

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = api_key,
    }

    local response_text, code = http_post(url, headers, body, timeout)
    if response_text == nil then
        -- Every transport failed: no usable HTTP code.
        return nil, code
    end
    code = tonumber(code) or 0
    if code < 200 or code >= 300 then
        if code == 401 then
            return nil, "Gemini rejected the API key. Check it in Tools > Reflections > Settings > API key.", code
        end
        local detail = response_text:sub(1, 300)
        if detail == "" then detail = "no response body" end
        return nil, "HTTP " .. tostring(code) .. ": " .. detail, code
    end

    local ok_json, data = pcall(JSON.decode, response_text)
    if not ok_json or type(data) ~= "table" then
        return nil, "could not understand Gemini's response", code
    end
    if data.error and data.error.message then
        return nil, tostring(data.error.message), code
    end
    local cands = data.candidates
    if cands and cands[1] and cands[1].content and cands[1].content.parts
        and cands[1].content.parts[1] and cands[1].content.parts[1].text then
        local t = cands[1].content.parts[1].text
        t = t:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then return t end
    end
    return nil, "Gemini returned an empty response", code
end

-- Full call. `model` may be a single model id or a list forming a
-- fallback chain (tried in order). Transient capacity errors (429/500/502/
-- 503, network blips) are retried per model; a 404 (retired model) skips to
-- the next model immediately; other errors fail fast. max_retries counts the
-- extra attempts per model after the first (default 1).
function Gemini.generate(api_key, model, prompt_text, timeout, max_retries,
    thinking_budget)
    timeout = timeout or 60
    if max_retries == nil then max_retries = 1 end
    local models = type(model) == "table" and model or { model }
    local last_err
    for _, m in ipairs(models) do
        for attempt = 0, max_retries do
            local text, err, code = Gemini._request(api_key, m,
                prompt_text, timeout, thinking_budget)
            if text then return text end
            last_err = err
            if code == 404 then
                break -- retired model: try the next one right away
            end
            if not is_transient(code) then
                return nil, err -- auth/bad request/etc: another model won't help
            end
            if attempt == max_retries then
                break -- out of retries for this model: try the next one
            end
            sleep_seconds(4 * (attempt + 1)) -- 4s, then 8s
        end
    end
    return nil, last_err
end

-- ------------------------------------------------- OpenAI-compatible APIs
-- OpenAI, DeepSeek, OpenRouter, and most other providers (plus local
-- model servers) all speak the same chat completions format, so one
-- client covers the whole family. A provider is just a base URL, a
-- bearer key, and a model id, carried in a config table:
-- { kind = "openai", label, api_key, model, base_url, extra_headers }.

-- Reasoning tokens and the visible answer share one completion budget.
-- A flat 1024 leaves heavier reasoning levels nothing to answer with, so
-- the cap rises with the requested level. Auto gets the largest cap too:
-- the provider chooses the effort, and some defaults are heavy. Off
-- keeps the original budget.
local function openai_max_tokens(level)
    if level == "low" then return 2048 end
    if level == "medium" then return 8192 end
    if level == "high" then return 8192 end
    if level == "auto" then return 8192 end
    return 1024
end

-- Pure builder, split out so tests can exercise it without a network.
function Gemini._buildOpenAIRequest(config, prompt_text)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. tostring(config.api_key or ""),
    }
    if type(config.extra_headers) == "table" then
        for k, v in pairs(config.extra_headers) do headers[k] = v end
    end
    local payload = {
        model = config.model,
        messages = { { role = "user", content = prompt_text } },
        temperature = 0.7,
        max_tokens = openai_max_tokens(config.reasoning),
    }
    -- Reasoning control, for the heavier models that would otherwise
    -- spend the whole output budget thinking and return nothing. Each
    -- provider family takes its own field; Auto sends nothing, and
    -- providers with no standard control ignore the setting.
    local level = config.reasoning
    if level == "off" or level == "low" or level == "medium"
        or level == "high" then
        if config.provider_id == "openrouter" then
            payload.reasoning = {
                effort = level == "off" and "none" or level,
            }
        elseif config.provider_id == "nvidia" then
            -- NIM serves many model families behind one endpoint, and
            -- its reasoning controls are the vLLM style ones: the GLM
            -- and gpt-oss families take reasoning_effort, thinking is
            -- switched off through the chat template, and NVIDIA's own
            -- GLM notes ask chat callers to pass clear_thinking.
            if level == "off" then
                payload.chat_template_kwargs = {
                    enable_thinking = false,
                    clear_thinking = true,
                }
            else
                payload.reasoning_effort = level
                payload.chat_template_kwargs = { clear_thinking = true }
            end
        elseif config.provider_id == "openai"
            or config.provider_id == "anthropic"
            or config.provider_id == "groq"
            or config.provider_id == "xai" then
            if level ~= "off" then
                payload.reasoning_effort = level
            end
        end
    end
    local body = JSON.encode(payload)
    local base = tostring(config.base_url or ""):gsub("/+$", "")
    return base .. "/chat/completions", headers, body
end

-- Pure parser for a chat completions response body. Returns the text,
-- or (nil, error message).
function Gemini._parseOpenAI(response_text)
    local ok_json, data = pcall(JSON.decode, response_text)
    if not ok_json or type(data) ~= "table" then
        return nil, "could not understand the provider's response"
    end
    if data.error then
        local msg = type(data.error) == "table" and data.error.message
            or tostring(data.error)
        return nil, tostring(msg or "unknown error")
    end
    local choices = data.choices
    local choice = choices and choices[1] or nil
    if choice and choice.message
        and type(choice.message.content) == "string" then
        local t = choice.message.content
            :gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then return t end
    end
    if choice and choice.finish_reason == "length" then
        return nil, "the model used its whole answer budget before "
            .. "writing any questions. A lower Reasoning setting "
            .. "usually fixes this."
    end
    return nil, "the provider returned an empty response"
end

-- One OpenAI-compatible attempt. Returns the text, or
-- (nil, error message, http code).
function Gemini._requestOpenAI(config, prompt_text, timeout)
    local url, headers, body =
        Gemini._buildOpenAIRequest(config, prompt_text)
    local response_text, code = http_post(url, headers, body, timeout)
    if response_text == nil then
        return nil, code
    end
    code = tonumber(code) or 0
    if code < 200 or code >= 300 then
        if code == 401 or code == 403 then
            return nil, tostring(config.label or "The provider")
                .. " rejected the API key. Check it in Tools > "
                .. "Reflections > Settings > API key.", code
        end
        -- Providers usually answer errors as JSON with a message;
        -- prefer it over the raw body.
        local _, perr = Gemini._parseOpenAI(response_text)
        if perr and not perr:find("empty response", 1, true)
            and not perr:find("could not understand", 1, true) then
            return nil, perr, code
        end
        local detail = response_text:sub(1, 300)
        if detail == "" then detail = "no response body" end
        return nil, "HTTP " .. tostring(code) .. ": " .. detail, code
    end
    local text, err = Gemini._parseOpenAI(response_text)
    if text then return text end
    return nil, err, code
end

-- Full OpenAI-compatible call: one model, transient failures retried
-- with backoff like the Gemini path.
function Gemini.generateOpenAI(config, prompt_text, timeout, max_retries)
    timeout = timeout or 60
    if max_retries == nil then max_retries = 1 end
    local last_err
    for attempt = 0, max_retries do
        local text, err, code =
            Gemini._requestOpenAI(config, prompt_text, timeout)
        if text then return text end
        last_err = err
        if not is_transient(code) then
            return nil, err
        end
        if attempt < max_retries then
            sleep_seconds(4 * (attempt + 1))
        end
    end
    return nil, last_err
end

-- Single entry point for the plugin: the config's kind picks the wire
-- format. Dispatch goes through the module table on purpose, so tests
-- (and future providers) can stub the individual generators.
function Gemini.generateAny(config, prompt_text, timeout, max_retries)
    if type(config) == "table" and config.kind == "openai" then
        return Gemini.generateOpenAI(config, prompt_text, timeout,
            max_retries)
    end
    config = type(config) == "table" and config or {}
    return Gemini.generate(config.api_key, config.models, prompt_text,
        timeout, max_retries, Gemini._thinkingBudget(config.reasoning))
end

return Gemini
