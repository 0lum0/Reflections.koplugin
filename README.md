# Reflections for KOReader

A KOReader plugin that writes thoughtful discussion questions for every
chapter you finish, and for whole reading sessions, using the Gemini API.
Answer them with pen and paper, like a book club for one.

## What it does

- **Tracks your chapters** from the book's table of contents as you read.
- **Generates reflection prompts in the background**, silently, the moment you
  reach a new chapter. Nothing ever appears on your reading screen.
- **Chapter browser**: open `Tools > Reflections` to see every chapter you've
  read so far. Tap one to read its questions; hold one to generate a fresh set.
- **Session questions**: read several chapters in one sitting? Pick the first
  and last chapter and get questions about the whole range, focused on how
  characters change and themes develop across chapters. Past sessions are
  remembered for re-reading.
- **End of book reflection**: finished the book? Get one set of big-picture
  questions about the whole work: how characters changed from beginning to
  end, what it's ultimately about, what lingers after the last page. A
  closing ritual for your journal.
- **Fiction or nonfiction**: flip the mode per book and the questions reframe
  around arguments, evidence, and ideas instead of story. Your novels and
  your history books each get questions that fit.
- **Spoiler safe**: only text up to your current reading position is ever sent
  to Gemini.
- **Story focused**: questions are about the book itself, its events,
  characters, choices, and themes.

## Setup

### 1. Get a free Gemini API key

1. Go to [Google AI Studio](https://aistudio.google.com).
2. Sign in with a Google account.
3. Click **Get API key** and create one in a new or existing project.
4. Copy the key. The free tier is plenty for this plugin.

### 2. Install the plugin

1. Download the latest `reflections-koplugin-vX.zip` from the releases.
2. Unzip it. You'll get a folder called `reflections.koplugin`.
3. **Highly recommended**: before copying anything over, open
   `reflections.koplugin/reflections.conf.lua` in a text editor, paste your
   API key into the `api_key` field, and save. Doing this on your computer
   means no typing on the e-ink keyboard later.
4. Copy that folder into KOReader's `plugins` directory:
   - **Kindle**: connect over USB, open the KOReader folder, and drop it in
     `koreader/plugins/`.
   - **Kobo / PocketBook / Android**: same idea, inside the `koreader/plugins/`
     folder wherever KOReader keeps its data.
5. Restart KOReader (long-press the power button, or quit and relaunch).

> Skipped step 3? You can still add your key on the reader: open any book,
> go to `Tools > Reflections > Settings > Gemini API key`, and type it in.
>
> Keep your key private. Never post your `reflections.conf.lua` with a real
> key in it.

### 3. Read

Open a book and read. When you finish a chapter, its questions generate
quietly in the background. Open `Tools > Reflections` any time to browse
chapters and read their prompts. Generation usually takes 10 to 30 seconds on
decent Wi-Fi.

## Settings

Inside `Tools > Reflections > Settings`:

| Setting | What it does | Default |
|---|---|---|
| Gemini API key | Your key from Google AI Studio | (empty) |
| Prompts per chapter | 1 to 20 questions per chapter (tap to type a number) | 3 |
| Questions per session | 1 to 20 questions per session, set inside the session picker | 6 |
| Questions per book | 1 to 20 questions for the end-of-book reflection, set inside its picker | 6 |
| Model | Any Gemini model id you want to use | `gemini-3.5-flash-lite` |
| Generate in background | Make questions automatically as you read | on |

**About the model**: the plugin uses `gemini-3.5-flash-lite` out of the box.
It's fast, cheap, and more than capable of writing good discussion questions.

**Clearing saved questions**: the chapter list has a *Clear cached prompts*
entry (with a confirmation step) that wipes every saved question for the
current book. Holding a single chapter regenerates just that chapter.

**How session questions are built**: the first 3 are always open-ended
cross-chapter questions. Past 3, each question takes one random lens from ten
angles: plot and events, characters and their choices, themes and ideas,
shifting relationships, foreshadowing and payoff, the author's craft, moral
gray areas, worldbuilding, the emotional arc, and predictions. At 7+
questions there's a small chance one lens becomes a playful question instead,
so it stays a rare surprise.

**How the book reflection works**: it samples text from every chapter, so the
questions cover the full arc. The first 3 are open-ended big-picture
questions, then the same ten lenses as sessions (framed for a finished book)
take over past 3, with the same rare playful surprise at 7+.

## How it works

- Chapter boundaries come from the book's own table of contents, matched
  against your current page.
- Only chapter text up to where you're reading is sent to Gemini, so later
  chapters can't leak in.
- Questions are cached per book, so reopening a chapter is instant and costs
  nothing.
- Background generation runs in a separate process and never touches the
  reading UI.

## Requirements

- KOReader (any recent version)
- A Gemini API key (free tier works)
- Wi-Fi when questions are being generated

## License

MIT. See [LICENSE](LICENSE).

---

Chapter tracking approach adapted from
[xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin). Everything
else is original.
