# MR Review Assistant

A personal background agent that watches the owner's GitLab merge requests, tells the owner what needs their attention, and chats other people in Microsoft Teams so reviews keep moving. Working name; the project has no folder yet.

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

**Review Notice**:
A Teams chat from the Owner to the Author of someone else's MR, sent after the Owner has reviewed it.
_Avoid_: Review reply, feedback ping

**Activity Alert**:
A notification to the Owner that someone else reviewed or replied on one of the Owner's own MRs.
_Avoid_: Update, notification

**Agent Review**:
A review of an MR that the agent writes with a language model and posts to GitLab as the Owner, in answer to a Review Request.
_Avoid_: Auto review, bot review

**Pending Message**:
A Reviewer Nudge or Review Notice written by the agent but held until the Owner sends or skips it, when that flow is set to require approval.
_Avoid_: Draft, queued message
