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
    -- Your Gemini API key from https://aistudio.google.com
    api_key = "",

    -- Model to use (default shown).
    model = "gemini-3.5-flash-lite",

    -- Reflection prompts per chapter: 1 to 20.
    prompt_count = 3,

    -- Reflection prompts per reading session: 1 to 20.
    session_prompt_count = 6,

    -- Questions for the end-of-book reflection: 1 to 20.
    book_prompt_count = 6,

    -- Generate prompts silently in the background when you finish a chapter.
    background = true,
}
