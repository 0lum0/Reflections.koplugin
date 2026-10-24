-- Reflections pre-configuration.
-- Fill this in on your computer BEFORE copying the plugin to your reader,
-- so you don't have to type on the e-ink keyboard.
--
-- Anything you later change inside KOReader (Reflections > Settings)
-- takes precedence over the values here.
--
-- Keep this file private: it contains your API key. Don't share the
-- plugin folder publicly with a real key in it.

return {
    -- Which AI provider to use: "gemini", "openai", "anthropic",
    -- "deepseek", "openrouter", "nvidia", "xai", "groq", "mistral",
    -- "together", "perplexity", or "custom" (any OpenAI-compatible
    -- endpoint).
    provider = "gemini",

    -- Your Gemini API key from https://aistudio.google.com
    api_key = "",

    -- Gemini model to use (default shown).
    model = "gemini-3.5-flash-lite",

    -- Keys and models for the other providers. Only the active
    -- provider's values are used; leave the rest blank. A blank model
    -- uses the provider's preset default.
    openai_api_key = "",
    openai_model = "",
    anthropic_api_key = "",
    anthropic_model = "",
    deepseek_api_key = "",
    deepseek_model = "",
    openrouter_api_key = "",
    openrouter_model = "",
    nvidia_api_key = "",
    nvidia_model = "",
    xai_api_key = "",
    xai_model = "",
    groq_api_key = "",
    groq_model = "",
    mistral_api_key = "",
    mistral_model = "",
    together_api_key = "",
    together_model = "",
    perplexity_api_key = "",
    perplexity_model = "",

    -- Custom provider: your endpoint's base URL (with the version
    -- path, e.g. "http://192.168.1.10:1234/v1"), key, and model.
    custom_api_key = "",
    custom_model = "",
    custom_base_url = "",

    -- Reflection prompts per chapter: 1 to 20.
    prompt_count = 3,

    -- Reflection prompts per reading session: 1 to 20.
    session_prompt_count = 6,

    -- Questions for the end-of-book reflection: 1 to 20.
    book_prompt_count = 6,

    -- Language for the generated questions: "en" (English), "es",
    -- "fr", "de", "it", "pt", "nl", "pl", "sv", "ru", "uk", "tr",
    -- "ar", "hi", "ja", "ko", or "zh". Can also be changed later in
    -- Reflections > Settings > Question language.
    language = "en",

    -- How much thinking a model may do before it answers: "auto",
    -- "off", "low", "medium", or "high". Auto sends no control, which
    -- is how the plugin has always behaved. Heavier reasoning models
    -- can spend the whole answer budget thinking and return nothing;
    -- "low" is a good cap for those. Can also be changed later in
    -- Reflections > Settings > AI > Reasoning.
    reasoning = "auto",

    -- Generate prompts silently in the background when you finish a
    -- chapter. Off by default: generation spends API quota, so it is
    -- opt-in. Set to true (or use Settings) if you want it. (Legacy
    -- switch: the Settings picker now offers "off", "beginning", and
    -- "end" for when background generation runs, and true here means
    -- "end". To preconfigure a mode instead, add a line like:
    -- background_mode = "beginning")
    background = false,

    -- For background "beginning" mode: how many pages into a chapter
    -- its questions generate at. The whole chapter is sent, so the
    -- questions are ready when you finish it. 1 to 30.
    background_pages = 3,
}
