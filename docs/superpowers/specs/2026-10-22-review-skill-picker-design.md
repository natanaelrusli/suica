# Review skill and model picker — design

Status: written from the Owner's request on 2026-10-22 ("Review skill only refers to a name installed in the machine … have a list of the skills that user can choose … for the review model, can choose from a sidebar drawer and clicking instead of typing manually"), and their answers: they want different skills for different MRs, chosen in the MR detail too, for that one review only, with the model chosen there as well. Choices marked _my call_ are the builder's. Vocabulary is in `CONTEXT.md`.

## Why

One skill and one model review every MR, and both are typed by name in Configuration. A Go backend MR and a Flutter MR want different review skills; today that means editing the config before each review and setting it back afterwards. The name also has to be typed exactly, with no way to see what is installed.

## Goals

- Configuration → Agent Review → Skill and model: pick the default **Review skill** and **Review model** by clicking in a list, never by typing a name you have to know.
- MR detail: start one Agent Review with a skill and model chosen for that run only.
- Every list shows only what this machine can run: the skills installed for Claude Code, the models of the CLI that reviews.

## Non-goals

- Editing a skill's text, or creating skills, in the app. "Customize" means choosing in the app (the Owner's answer).
- Remembering a per-MR skill: later re-reviews and automatic reviews use the defaults again.
- Choosing the CLI per review (Model CLI stays one global setting), or the effort per review.

## Anti-goals

- A list that offers a skill or model the next run cannot use. Picking one and seeing the review fail with "not installed" would be worse than the text box.
- Losing the one-click **Review with agent**: the defaults must still start with one click.

## The agent

### `suica review options --json`

A new read-only command, document in `contracts/review-options.v1.json` (golden plus Swift decoder):

```json
{
  "version": 1,
  "cli": "claude",
  "defaults": { "skill": "madhani:madhani-code-review", "model": "sonnet" },
  "skills": [
    { "name": "madhani:madhani-code-review", "description": "Reviews a diff or MR …", "source": "plugin", "plugin": "madhani" },
    { "name": "reverse-engineer-anything", "description": "…", "source": "user", "plugin": null }
  ],
  "models": [
    { "name": "opus", "label": "Opus", "description": "Most capable; slowest and uses the most tokens" }
  ]
}
```

- **Skills**: every `~/.claude/skills/<name>/SKILL.md` (`source: user`, name `<name>`) and, for every plugin in `~/.claude/plugins/installed_plugins.json` that `~/.claude/settings.json` does not turn off in `enabledPlugins`, every `<installPath>/skills/<skill>/SKILL.md` (`source: plugin`, name `<plugin>:<skill>`). The description is the SKILL.md front matter's `description`, cleaned and cut to 300 characters. Without `installed_plugins.json` the plugin cache is scanned the way `findSkillDir` does today (newest version per plugin) (_my call_: the installed list is what Claude Code itself loads; the cache can hold plugins that were removed). Order: names containing `review` first, then by name (_my call_: about 80 skills are installed here and most are not review skills). The configured default is always in the list; when it is not installed it is listed with `"missing": true` so the app can say so.
- **Models**, for the CLI that reviews (`cli`, as `resolveModelCli` gives it; `null` and an empty list when none is installed):
  - Claude Code: `opus`, `sonnet` and `haiku` with a label and one line each, written in the agent (_my call_: Claude Code has no local model list; its aliases follow the newest model of each tier).
  - Codex: the entries of `~/.codex/models_cache.json` whose `visibility` is `list`, with their `display_name` and `description`. A missing or unreadable cache gives an empty list.
  - Gemini CLI does not review, so it has no list.
  - The configured default model is always in the list (added at the end when the CLI's list lacks it).
- Reading never fails the command: an unreadable file is skipped and logged at debug.

### `suica review queue <key> [--skill <name>] [--model <name>] --json`

- Both options are optional; leaving one out means the default from the config, read when the review runs (as today).
- `--skill` must be one of the names `review options` lists without `missing`, `--model` must pass the config's own `review.model` check; anything else is `bad-request` with a message, and nothing is queued. The model is not checked against the list (_my call_: a full model name the list lacks is still valid for the CLI).
- The choice is stored on the queued row: `agent_review` gets `skill TEXT` and `model_choice TEXT` (schema 18, null for the default). The existing `model` column keeps meaning "the model the CLI reported".
- A review of the MR that is already **queued** takes the new choice (both columns replaced, the reply is `queued`), so an automatic review queued a moment earlier does not swallow the pick (_my call_). One that is already **running** is left alone and the reply stays `already-queued`; the drawer's **Start review** is disabled while a review of the MR is queued or running, with a line saying why.
- `review options` takes an optional `--cli <id>` to list the models of another installed CLI; Configuration passes the drafted Model CLI so the drawer matches the unsaved choice (_my call_). A queued row does not record its CLI: a Model CLI change in the seconds between queueing and the run is not handled.

### The run

- A run uses `row.skill ?? config.review.skill` and `row.modelChoice ?? config.review.model` everywhere it uses them today: the prompt, the Codex skill lookup, the `--model` argument, the start log line and the approval judge (_my call_: the judge is part of that review).
- The posted note says the skill the review followed (`renderNote` takes the row's skill, not the config's), so "following `…`" stays true per MR.
- A re-review queued automatically, and **Review again** without a choice, use the defaults.
- **Another skill on a reviewed commit** (the main use: the MR got the wrong skill). "This commit was already reviewed" only skips a run when the review at that commit followed the same skill; a row without a stored skill counts as following the current default (_my call_). Likewise a run becomes an incremental re-review only when the base review followed the same skill; with another skill it is a full first review that reads no `previous-review.md` (_my call_: the old findings were written to another checklist). Both reviews stay in the history; the newest is the one MR detail, the Reviewed tab and approval read, as today.

### Reviews document

`contracts/reviews.v1.json`: each agent review gains `skill` (the skill it follows: the row's choice or, once it ran, the default it used; `null` on rows from before schema 18). MR detail shows it next to the model.

## The app

### The picker drawer

One drawer (SwiftUI `.inspector`, trailing side) used in both places, with up to two sections:

- **Skill**: a search box over name and description, then one row per skill: name, plugin, two lines of description, a checkmark on the selected one. A missing default shows "Not installed" in orange. User skills and plugin skills are not split into groups (_my call_: the search does the work).
- **Model**: one row per model: label, name in secondary text, description, checkmark. A last row **Other model…** turns into a text field for any name (_my call_: keeps full model names possible). A first row **CLI default** clears the choice.
- The drawer loads `review options` when it opens; while it loads it shows a spinner, and a failure shows the agent's message with **Try again**.

### Configuration → Agent Review → Skill and model

- **Review skill** shows the selected skill's name and description and a **Choose…** button that opens the drawer at its Skill section. Picking a row sets the draft (Save as for every field; nothing is saved by the drawer itself). A default that is not installed shows "Not installed" under the field.
- **Review model** shows the selected model's label (or **CLI default**) and **Choose…**, which opens the drawer at its Model section. The small suggestion menu next to the text box goes.
- **Review effort** is unchanged.

### MR detail

- **Review with agent** / **Review again** becomes a split button: the main part starts a review with the defaults, as today; its arrow offers **Review with…**, which opens the drawer with both sections and a **Start review** button at the bottom. Skill and model start at the defaults; **Start review** queues with the chosen ones and closes the drawer. A choice equal to the default is sent as no choice (_my call_: the row then follows a later config change, as before).
- The Agent Review tab shows "Skill: …" beside "Model: …".
- The row actions in the Reviews list and the Overview's buttons keep starting with the defaults (_my call_: the choice belongs to looking at one MR).

### Overview

The Overview's **Model** picker lists the models from `review options` instead of the three hard-coded aliases, so Codex users see Codex models (_my call_). Its "Other model names" hint stays.

## Constraints

- macOS 15 target: `.inspector` is available.
- Names reach `claude` and `codex` as argv elements (no shell) and as the first line of the prompt; the skill name is restricted to names the list holds, so no other text reaches the prompt's slash command.
- `README.md`, `CONTEXT.md` (if a term changes), the contracts and their Swift decoders change in the same branch.

## Tests

- Agent (vitest): skill listing from a fake home (user skills, enabled and disabled plugins, missing `installed_plugins.json`, front matter without description, review-first order, missing default); Codex model list from a fake cache (hidden entries dropped, unreadable cache); `review queue` with good and bad `--skill`/`--model`; a run with a row choice uses it in the prompt, argv, judge and note; schema 18 migration on a schema 17 database; contract goldens.
- App (swift test): decoders for the new and changed contracts; the draft written by picking a skill or model; the split button's choice sent as no choice when equal to the default.
- UI: harness screenshots of the Configuration section with the drawer open and of MR detail's **Review with…** drawer.
