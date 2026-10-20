# Reflections for KOReader

A KOReader plugin that writes thoughtful discussion questions for every
chapter you finish, for whole reading sessions, and for the finished book,
using the AI provider of your choice. Answer them with pen and paper, like
a book club for one.

## What it does

- **Tracks your chapters** from the book's table of contents as you read.
- **Can generate reflection prompts in the background**, silently, the moment
  you reach a new chapter (opt in under Settings > AI). Nothing ever appears
  on your reading screen.
- **A proper submenu**: `Tools > Reflections` opens Chapters, Sessions, End
  of book reflection, Begin/End reading session, Fiction/Nonfiction mode, and
  Settings. It pins itself to the top of the Tools menu.
- **Chapter browser**: open Chapters to see every chapter you've read so far.
  Tap one to read its questions; hold one to generate a fresh set. It opens
  on the last page, where you left off. Chapters with saved questions wear
  a small dot, and every questions page shows when its set was generated
  and which provider wrote it.
- **Highlights questions**: tap Highlights on any chapter or session page
  and get a set grounded only in the passages you highlighted there, one
  question per passage at most. These questions ask why you marked each
  passage: the wording, a moment of recognition, a detail that feels
  loaded, a point of confusion. Your own marked moments, reflected back.
- **Tap a question to swap it**: don't love one question in a set? Tap it
  and it is replaced with a fresh one written against the rest, so it
  lands somewhere new.
- **Journaling Extras**: a row at the bottom of every questions page with
  standbys for anything the questions missed: predictions with odds, who
  changed most, a confusion log, what stuck, one small deliberate detail,
  and a sentence for future you.
- **Reading sessions**: begin a session when you start reading and end it
  when you stop. Questions generate quietly for exactly what you covered,
  and a small notification tells you when they're waiting in the Sessions
  tab. Prefer to pick manually? Choose the first and last chapter yourself,
  or flip the picker to Pages and choose a page range instead.
  Past sessions are listed newest first with date and time, and kept for
  re-reading. End a session on the very first page of a chapter and that
  chapter is left out, so questions never touch what you haven't read.
- **Simplify toggle**: a checkbox on any questions page that rewords the set
  to be lighter and more relaxed, without dumbing it down. Leave it on and
  new questions come out simplified too. Made for slow reading days.
- **End of book reflection**: finished the book? Get one set of big-picture
  questions about the whole work: how characters changed from beginning to
  end, what it's ultimately about, what lingers after the last page. A
  closing ritual for your journal.
- **Fiction or nonfiction**: flip the mode per book and the questions reframe
  around arguments, evidence, and ideas instead of story. Your novels and
  your history books each get questions that fit.
- **Spoiler safe**: only text up to your current reading position is ever sent
  to the provider.
- **Story focused**: questions are about the book itself, its events,
  characters, choices, and themes.
- **Your choice of provider**: Gemini, OpenAI, Anthropic (Claude), DeepSeek,
  OpenRouter, NVIDIA NIM, xAI (Grok), Groq, Mistral, Together, Perplexity,
  or any custom OpenAI compatible endpoint. Each provider keeps its own key
  and model, so switching back and forth loses nothing. The model you pick
  is the model that runs: there is no silent fallback to another model.
- **Question language**: generate your questions in any of 17 languages,
  from Spanish and French to Japanese and Ukrainian.
- **Reasoning control**: heavier reasoning models can think so long they
  never answer. A Reasoning picker (Auto, Off, Low, Medium, High) caps how
  much thinking a model may do before it has to respond.
- **Long waits, with an exit**: generation can take up to five minutes on
  slow, heavy models. While it runs, a small floating card with a Cancel
  button stays on screen, so a long wait is never a trap.

## Setup

### 1. Get an API key

Gemini is the default and the easiest start:

1. Go to [Google AI Studio](https://aistudio.google.com).
2. Sign in with a Google account.
3. Click **Get API key** and create one in a new or existing project.
4. Copy the key. The free tier is plenty for this plugin.

Prefer another provider? OpenAI, Anthropic, DeepSeek, OpenRouter, xAI,
Groq, Mistral, Together, and Perplexity all work with a key from that
provider, and NVIDIA NIM works with a free key from
[build.nvidia.com](https://build.nvidia.com). Any other OpenAI compatible
endpoint can be added as a custom provider.

### 2. Install the plugin

1. Download the latest `reflections-koplugin-vX.zip` from the releases.
2. Unzip it. You'll get a folder called `reflections.koplugin`.
3. **Highly recommended**: before copying anything over, open
   `reflections.koplugin/reflections.conf.lua` in a text editor, set the
   `provider` field and paste your API key into that provider's key field
   (the plain `api_key` field is Gemini's), and save. Doing this on your
   computer means no typing on the e-ink keyboard later.
4. Copy that folder into KOReader's `plugins` directory:
   - **Kindle**: connect over USB, open the KOReader folder, and drop it in
     `koreader/plugins/`.
   - **Kobo / PocketBook / Android**: same idea, inside the `koreader/plugins/`
     folder wherever KOReader keeps its data.
5. Restart KOReader (long-press the power button, or quit and relaunch).

> Skipped step 3? You can still add your key on the reader: open any book,
> go to `Tools > Reflections > Settings > AI > API key`, and type it in.
>
> Once the plugin has seen your key, it stores it in KOReader's own settings,
> so updating the plugin later never wipes it. One and done.
>
> Keep your key private. Never post your `reflections.conf.lua` with a real
> key in it.

### 3. Read

Open a book and read. Finish a chapter and its questions are a tap away in
the Chapters list, or turn on background generation in Settings and they
will be made quietly as you read. Open `Tools > Reflections` any time to
browse chapters, sessions, and settings. Generation usually takes 10 to 30
seconds on decent Wi-Fi with a fast model, and longer with heavy reasoning
models; the Cancel card keeps long waits optional.

## Settings

Inside `Tools > Reflections > Settings`:

AI options live in their own submenu, `Settings > AI`:

| Setting | What it does | Default |
|---|---|---|
| AI provider | Which service writes your questions | Gemini |
| API key | Your key for the active provider; every provider keeps its own | (empty) |
| Model | Any model id the active provider offers | per provider (Gemini: `gemini-3.5-flash-lite`) |
| Reasoning | How much thinking a model may do before answering: Auto, Off, Low, Medium, High | Auto |
| Generate in background | Make questions automatically as you read | off |

| Setting | What it does | Default |
|---|---|---|
| Question language | The language your questions are written in | English |
| Prompts per chapter | 1 to 20 questions per chapter (tap to type a number) | 3 |
| Prompts per session | 1 to 20 questions per session | 6 |
| Prompts per book reflection | 1 to 20 questions for the end-of-book reflection | 6 |

**About the model**: out of the box the plugin uses Gemini's
`gemini-3.5-flash-lite`. It's fast, cheap, and more than capable of writing
good discussion questions. Whatever provider and model you choose is
exactly what runs: if it fails, you see the error, never questions quietly
written by a different model.

**Clearing saved questions**: Settings has a *Clear cached reflections*
entry (with a confirmation step) that wipes every saved question for the
current book, including your previous sessions list. A checkbox lets you keep
the sessions if you'd rather. Holding a single chapter regenerates just that
chapter. *Clear cached reflections (all books)* does the same wipe for
every book at once, in one tap.

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
- Only chapter text up to where you're reading is sent to the provider, so
  later chapters can't leak in.
- Questions are cached per book, so reopening a chapter is instant and costs
  nothing.
- Background generation runs in a separate process and never touches the
  reading UI.

## Requirements

- KOReader (any recent version)
- An API key for one of the supported providers (a free Gemini or NVIDIA
  key works)
- Wi-Fi when questions are being generated

## License

MIT. See [LICENSE](LICENSE).

---

Chapter tracking approach adapted from
[xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin). Everything
else is original.
