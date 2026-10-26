# Notification polish

Date: 2026-10-26

## Goal

The macOS notifications read better, carry the Suica logo and offer buttons for the next step.

## Design

- **Wording and icons**: every built-in alert title starts with an emoji for its kind (👀 review request, 💬 activity, 🔴 pipeline failed, ❌ failure, ✅ posted, 🛠️ fix ready); failure notifications likewise. Bodies keep their facts; a review request adds the MR number. Custom `.txt` templates are unchanged.
- **Logo**: macOS has no per-notification icon; it comes from the sending app. `scripts/install-macos-app.sh` copies terminal-notifier to `~/Applications/Suica Notifier.app` with the Suica `AppIcon.icns`, its own bundle id and the name Suica. The notifier tries it first, then `terminal-notifier`, then `osascript`. A refused permission falls through to the next one, so no alert is lost. (my call)
- **Sound**: `Glass` for what needs the Owner, `Basso` for failures, none for progress. (my call)
- **Buttons**: `Review dengan agen` (`suica review queue <key>`) on a review request, `Perbaiki pipeline` (`suica fix queue <key> --pipeline`) on a failed pipeline. A click on the body opens the link as before. Buttons only queue work the app already offers; nothing is sent to Teams or GitLab from a button. (my call)
- **Not blocking the poll**: terminal-notifier with buttons stays running until answered (up to an hour). `notify` returns once the process has survived 1.5 s; a failure to start inside that window is still a delivery failure. A button that fails is dropped silently.
- Links a button or click opens must be `http(s)://` or `suica://`.
