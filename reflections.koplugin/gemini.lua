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

-- One attempt. Returns the text, or (nil, error message, http code).
function Gemini._request(api_key, model, prompt_text, timeout)
    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
        .. model .. ":generateContent"

    local body = JSON.encode({
        contents = {
            { parts = { { text = prompt_text } } },
        },
        generationConfig = {
            temperature = 0.7,
            maxOutputTokens = 1024,
        },
    })

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = api_key,
    }

    local ok_https, https = pcall(require, "ssl.https")
    if not ok_https or not https then
        return nil, "HTTPS support is not available on this device"
    end
    -- Some e-ink devices lack current CA bundles; keep requests working.
    pcall(function() https.cert_verify = false end)

    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    pcall(function() socketutil:set_timeout(timeout, timeout) end)

    local response_body = {}
    local request = {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body),
    }

    local ok, code
    local pok, perr = pcall(function()
        ok, code = https.request(request)
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not pok then
        -- Network-level failure (DNS, refused, dropped): no HTTP code.
        return nil, "request failed: " .. tostring(perr)
    end

    local response_text = table.concat(response_body)
    code = tonumber(code) or 0
    if not ok or code < 200 or code >= 300 then
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
function Gemini.generate(api_key, model, prompt_text, timeout, max_retries)
    timeout = timeout or 60
    if max_retries == nil then max_retries = 1 end
    local models = type(model) == "table" and model or { model }
    local last_err
    for _, m in ipairs(models) do
        for attempt = 0, max_retries do
            local text, err, code = Gemini._request(api_key, m, prompt_text, timeout)
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

return Gemini
