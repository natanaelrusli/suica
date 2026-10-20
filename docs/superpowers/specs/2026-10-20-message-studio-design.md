# Message studio: visual template editor, emoji and GIFs, and the Owner's own notifications — design

Status: written from the Owner's request on 2026-10-20 ("add more useful features and fun features": edit message templates in a WYSIWYG editor, GIFs and emoji in messages, a custom message for each notification case; "you can add your own"). The Owner was not available for questions, so every choice below marked _my call_ is the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

1. Templates are edited the way they will look, not as Markdown source.
2. A message can carry emoji and an animated GIF.
3. Each macOS notification the agent shows the Owner (a review request, activity on an MR, an Agent Review that is ready, posted or failed, …) has a text the Owner can change, the way Teams templates can be changed today.
4. My own additions, chosen because they make the agent's chats less robotic: **variants** (a template may hold several versions and each message picks one), and two placeholders, `{{time.greeting}}` ("pagi", "siang", "sore", "malam") and `{{person.firstName}}`.

## Goals

- A visual editor for Teams templates: bold, italic, strikethrough and links shown as such, placeholders shown as chips that move and delete as one piece, emoji shown as emoji, GIFs shown as a GIF chip, and the Markdown source one click away.
- Nothing the visual editor saves changes the meaning of a template it opened: a template it cannot show faithfully opens in the Markdown view.
- Emoji by picker, by the system Emoji & Symbols palette, and by `:shortcode:` (`:tada:` becomes 🎉), in the template text only.
- A GIF is an image in the Markdown message, `![alt](https://…)`, previewed animated in the app.
- Every Owner notification case has a template with a title and a body, with its own placeholders, editable in the same page, previewed as a macOS banner.
- The built-in texts are exactly today's texts: nothing changes for an Owner who edits nothing.

## Non-goals

- A GIF search (Giphy, Tenor): both need an API key, which is a secret to store and rotate (_my call_: paste a link instead; the app remembers the last eight GIFs used).
- Uploading a GIF file into Teams (hosted content): the Teams MCP sends Markdown only.
- Formatting in notifications: macOS notifications are plain text.
- Templates for the failure notifications (GitLab login, Teams unreachable, state storage): they carry fixed instructions (_my call_).
- Variants in notification templates (_my call_: the title/body split is enough to learn for one page).
- Headings, lists, quotes and code in the visual editor: a template using them opens in the Markdown view.

## Anti-goals (a failure even if it works)

- The visual editor re-saving a hand-written template with different Markdown (for example `__bold__` turned into `\_\_bold\_\_`).
- A shortcode or a placeholder inside a value (an MR title, a name) being expanded.
- A non-https image in a sent message.
- A retried or approved-later message changing its text, or its variant, between attempts.
- A notification losing an emoji because its zero-width joiner was stripped (👩‍💻 turning into 👩 💻).

## Behaviour

### Teams templates

1. **Shortcodes.** `:name:` in the template text, where `name` is in the agent's emoji table (about 50 common ones: `:tada:`, `:rocket:`, `:pray:`, `:eyes:`, `:white_check_mark:`, …), becomes the emoji when the message is written. An unknown name stays as written (`10:30:` is not an error). Values are filled in after shortcodes, so a title is never touched. The table is in `suica templates show --json` as `emoji`, so the app's picker and preview use the same one.
2. **Images.** `![alt](url)` is an image. A template whose image URL is not `https://` is refused, by the CLI save and at startup, like an unknown placeholder (_my call_: http links leak the chat to the network; data URIs are not a GIF link). The Teams MCP turns it into `<img src alt>`, which its sanitizer allows. Whether Teams shows an external image inline is **unverified** at the time of writing; with `teams.modes.*: approval` the Owner sees every message before it goes, and the image is a link in the worst case.
3. **Variants.** A line that is exactly `--- or ---` splits a template into variants; each must be valid on its own. A message uses variant `fnv1a(dedupeKey) mod n` (_my call_: deterministic, so a retry or a later approval writes the same text; different messages spread over the variants).
4. **New placeholders.** `{{person.firstName}}`, the first word of the recipient's name, escaped like `person.name`. `{{time.greeting}}`: "pagi" from 04:00, "siang" from 11:00, "sore" from 15:00, "malam" from 18:00, local time, when the message is written (queued messages are written in working hours; a held message keeps the greeting it was written with).
5. **Built-in templates** do not change.

### Owner notification templates (alerts)

1. **Names.** `alert.review-requested`, `alert.activity`, `alert.summary`, `alert.baseline`, `alert.rereview`, `alert.review-ready`, `alert.review-posted`, `alert.review-approved`, `alert.review-post-failed`, `alert.review-failed`, `alert.review-skipped`. A file `<name>.txt` in the templates folder replaces the built-in one, as for Teams templates.
2. **Format.** First line: the title. The rest: the body. Both must be non-empty. Shortcodes work; Markdown does not (it is shown as written).
3. **Placeholders**, plain text (no Markdown escaping), each cleaned to one line and its old length limit:

   | Template | Placeholders |
   |---|---|
   | `alert.review-requested` | `mr.title`, `mr.iid`, `mr.project`, `mr.url`, `author.name` |
   | `alert.activity` | `mr.title`, `mr.iid`, `mr.project`, `mr.url`, `activity.summary` |
   | `alert.summary` | `alert.count`, `alert.titles` |
   | `alert.baseline` | `alert.count` |
   | `alert.rereview` | `mr.title`, `reviewers.names` |
   | `alert.review-ready`, `-posted`, `-approved`, `-post-failed` | `mr.title` |
   | `alert.review-failed`, `alert.review-skipped` | `mr.title`, `review.reason` |

   A placeholder outside its template's list is refused like an unknown one.
4. **Built-in texts** are today's: for example `alert.review-requested` is `Diminta review: {{mr.title}}` / `{{author.name}} · {{mr.project}}`.
5. **Loading.** Alerts load at startup whether Teams is on or not, from `teams.templatesPath` (the one templates folder; _my call_: the key keeps its name to avoid a config migration). A bad alert template stops startup, like a bad Teams template. The config editor's check that the templates folder loads covers alerts too.
6. **Emoji in notifications.** `clean()` keeps a zero-width joiner between two emoji; every other format character is still removed.

### CLI contract (`templates.v1.json`, additive)

- Each template gains `group` (`"teams"` or `"alert"`) and `placeholders` (what that template may use).
- The document gains `emoji` (`{ "tada": "🎉", … }`).
- `suica templates set --json` accepts every name of both groups and validates by the template's group.
- The top-level `placeholders` stays the Teams list, so an older app still works.

### The app (Configuration → Message templates)

1. **List.** Two sections: **Teams messages** and **Your notifications**.
2. **Teams editor.** A format bar: **B**, *I*, ~~S~~, **Link** (⌘K), **Placeholder** (inserts a chip at the cursor, not at the end), **Emoji** (eighteen quick picks plus the system palette), **GIF** (a sheet: paste an https link, see it animated, give it a short description, or pick one of the last eight), and **Visual / Markdown**. Under it the editor, then **Variants** tabs (1, 2, …, +, and remove). Typing a known `:shortcode:` turns into the emoji at once.
3. **Faithful or Markdown.** The editor parses the subset (`**bold**`, `*italic*` and `_italic_`, `~~strike~~`, `[text](url)`, `![alt](url)`, `{{placeholder}}`, backslash escapes) and writes it back canonically (`*` for italic). If writing the parsed template back does not give the same text, the template opens in the Markdown view with a note, and the Visual button explains why it is unavailable until the text is canonical.
4. **Preview.** The Teams preview shows text and, under it, each image animated, loaded over https only, with a 10 s timeout and at most 5 MB.
5. **Alert editor.** A title field and a body field, a placeholder menu with only that alert's placeholders, an emoji button, and a preview drawn as a macOS notification banner with sample values.

## Testing

- Agent (vitest): shortcode expansion (template only, unknown names kept), image URL validation, variants (split, validation per variant, deterministic pick), new placeholders, alert loading/validation/rendering and that every built-in alert renders today's exact text, `clean()` and ZWJ, CLI save by group, contract golden.
- App (swift test): the Markdown subset parser and writer (round trips, canonical form, faithful check against every built-in template), shortcode replacement while typing, variants split/join, preview segments (text and images), alert preview rendering, contract decoding with the new fields and without them.
- Views: screenshots through the scratch harness (see the project memory); no UI test target exists.
