# Suica

Suica is a personal background agent that watches the owner's GitLab merge requests, tells the owner what needs their attention, and chats other people in Microsoft Teams so reviews keep moving.

## Language

**Owner**:
The one person the agent works for. Every Teams message and GitLab review comment the agent produces appears as the Owner.
_Avoid_: User, me

**Author**:
The person who opened a merge request. On this team the MR's assignee is always the Author.
_Avoid_: Assignee, submitter

**Reviewer**:
A person GitLab lists in an MR's reviewer field.
_Avoid_: Approver, assignee

**Review Request**:
The moment someone adds the Owner as a Reviewer on their MR. The agent notices it by polling and tells the Owner.
_Avoid_: Assignment, new MR

**Reviewer Nudge**:
A Teams chat from the Owner to a Reviewer of the Owner's own MR, asking them to review it.
_Avoid_: Ping, reminder, review request

**Re-review Nudge**:
A Teams chat from the Owner to a Reviewer of the Owner's own MR who had already reviewed it, sent after the Owner pushed new commits, asking them to review again.
_Avoid_: Re-request, follow-up

**Review Notice**:
A Teams chat from the Owner to the Author of someone else's MR, sent after the Owner has reviewed it. After an Agent Review is posted, it says how many findings the review has per severity; after an Agent Re-review is posted, it says how many new findings it has. After an Agent Re-review the agent approved, it says the MR is approved. Every Teams chat opens with the agent introducing itself by its name (`teams.agentName`).
_Avoid_: Review reply, feedback ping

**Activity Alert**:
A notification to the Owner that someone else reviewed or replied on one of the Owner's own MRs.
_Avoid_: Update, notification

**Alert Template**:
The editable title and body of one kind of macOS notification to the Owner (a Review Request, an Activity Alert, an Agent Review that is ready, posted or failed, …), with its own placeholders.
_Avoid_: Notification template, alert text

**Variant**:
One of several versions of a Teams template; each message uses one, picked from its dedupe key.
_Avoid_: Alternative, random template

**Agent Review**:
A review of an MR that the agent writes with a language model following a skill, in answer to a Review Request or when the Owner asks for one, and posts to GitLab as the Owner once the Owner approves it, or at once when it is ready to approve and the agent approves the MR (`review.approve`, as strict as `review.approveWhen`; with `review.approveBy: agent` a second, tool-less model run reads the review and decides, also by the Owner's `review.approveRules`). The Owner can cancel it while it is queued or running.
_Avoid_: Auto review, bot review

**Agent Re-review**:
An Agent Review of an MR whose previous Agent Review was posted, written after the Author pushed new commits (or, when the Owner asks for one, changed the description). It reviews the changes since the commit the previous review covered and says, for each finding of the previous review, whether it was fixed.
_Avoid_: incremental review, follow-up review

**Finding Thread**:
An unresolved, resolvable discussion on the Owner's own MR whose newest note was written by someone other than the Owner, bots included. A Reviewer's new thread is one, and so is a Reviewer's answer to a reply the agent posted.
_Avoid_: comment, finding (alone)

**Watched MR**:
An open MR the Owner authored that is not yet approved (it has Reviewers and not all of them approved) and that the Owner watches: by its own Watch or Unwatch choice, else by `fix.watch`. Only Watched MRs get automatic Agent Fixes of threads; an automatic Pipeline Fix needs a watched MR too, but not an unapproved one.
_Avoid_: tracked MR

**Agent Fix**:
A change to the Owner's own MR that the agent writes with a language model to answer Finding Threads or fix a failed pipeline: it changes code, drafts replies, or both. It is committed, pushed (never with force) and replied as the Owner only once the Owner confirms it; the Reviewers resolve their threads.
_Avoid_: auto fix, bot commit

**Pipeline Fix**:
An Agent Fix whose input is the failed head pipeline of the Owner's own MR: the agent reads the failed jobs' logs, the model changes the code, and it waits for the Owner like any Agent Fix. Queued by hand, or automatically when the pipeline watch sees the pipeline fail.
_Avoid_: CI fix, auto fix

**Lesson**:
A general rule learned from one or more review findings, with every occurrence.
_Avoid_: rule, knowledge, memory

**Occurrence**:
One finding a Lesson was learned from or matched: its MR, repo, file and line, severity, text, source (Agent Review or Finding Thread) and outcome.
_Avoid_: instance, hit

**Lesson Scope**:
A folder on the Owner's Mac whose repos share Lessons: one repo, or a parent folder of many (searched for repos below it).
_Avoid_: root, workspace

**Topic**:
A kind of code or concern a Lesson is about (`http-client`, `db-pool`, `auth`, `sql`, `logging`, a language). The graph's link between Lessons.
_Avoid_: tag, category

**Pending Message**:
A Reviewer Nudge, Re-review Nudge or Review Notice written by the agent but held until the Owner sends or skips it, when that flow is set to require approval.
_Avoid_: Draft, queued message

**Coding Agent**:
A coding assistant process running on the Owner's Mac (Claude Code, Codex, Gemini CLI, …). Not Suica's own background agent, and not an Agent Review.
_Avoid_: Agent (alone), bot

**Session**:
One running conversation of a Coding Agent, in one folder.
_Avoid_: Run, process

**Room**:
A project folder (its git repository root; worktrees join the main repository's Room) that has at least one live Session, drawn as a room in the Office.
_Avoid_: Project (alone), workspace

**Center Room**:
The hall in the middle of the Office that every Room opens onto through a doorway; it has no Desks and is there even when no Session is running.
_Avoid_: Lobby, hallway

**Desk**:
One Session's place in its Room.
_Avoid_: Seat, slot

**Session Title**:
The name of a Session as its Coding Agent knows it (Claude Code's session name) or, failing that, the first line of its first prompt.
_Avoid_: Session name, label

**Chat Panel**:
The view of a Session's conversation that opens when its figure is clicked in the Office, with a field to send its agent a message.
_Avoid_: Chat window, transcript view

**Boss**:
The figure that walks to a worker's Desk while the Owner writes to that Session's agent from the Chat Panel, and says the message sent.
_Avoid_: Manager, owner figure
