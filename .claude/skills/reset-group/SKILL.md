---
name: reset-group
description: Reset a group's agent session so the next message starts with zero prior context. Triggers on "reset group", "reset session", "clear group session", "start fresh", "new session", "reduce context".
---

# Reset Group Session

Clears the accumulated context window for a group by removing the session ID from SQLite and restarting the service. The next message starts a brand-new session with zero prior conversation history.

## How context works (the two mechanisms)

**1. Session transcript** — the SDK resumes from `data/sessions/{folder}/.claude/projects/` only when a specific session ID is passed via `resume: sessionId`. If `sessionId` is `undefined`, the SDK creates a fresh session and the existing `projects/` files are completely ignored. **No need to delete `projects/` — just clearing the session ID is enough.**

**2. DB messages (prompt)** — `getMessagesSince(chatJid, lastAgentTimestamp)` sends only messages since the cursor. The cursor advances forward with each processed batch, so old DB messages are NOT re-sent. The message cursor is unaffected by a session reset and should not be touched.

## Why a restart is required

NanoClaw loads `sessions` from SQLite once at startup into an in-memory map (`index.ts:67`). Deleting from SQLite does not update the live map. On the next message, `runAgent()` would still pass the old stale session ID → SDK resumes old session → context not cleared.

A restart forces `loadState()` to re-read the now-empty `sessions` table, so the next run gets `sessionId = undefined` → new session → fresh context.

## Steps

### 1. Find available groups

```bash
sqlite3 store/messages.db "SELECT folder, name FROM registered_groups ORDER BY folder"
sqlite3 store/messages.db "SELECT group_folder FROM sessions"
```

If only one group, use it. If multiple, use `AskUserQuestion` to ask which one.

### 2. Optionally ask about message history

Only ask if the user explicitly requests it or seems to want a deeper wipe. Otherwise skip — deleting messages has no effect on LLM context (the cursor ensures old messages are never re-sent regardless).

### 3. Execute

```bash
# Clear session ID — this is all that's needed to get fresh context
sqlite3 store/messages.db "DELETE FROM sessions WHERE group_folder = '{folder}'"
```

If user also wants message history cleared:
```bash
JID=$(sqlite3 store/messages.db "SELECT jid FROM registered_groups WHERE folder = '{folder}'")
sqlite3 store/messages.db "DELETE FROM messages WHERE chat_jid = '$JID'"
```

### 4. Restart the service

```bash
# macOS (launchd)
launchctl kickstart -k gui/$(id -u)/com.nanoclaw

# Linux (systemd)
systemctl --user restart nanoclaw
```

### 5. Confirm

Tell the user the session was cleared and the service restarted. Next message to the group starts a fresh session with zero prior context.

Note: `data/sessions/{folder}/.claude/projects/` transcript files are left on disk — they are now orphaned and harmless. Optionally clean them up for disk space: `rm -rf data/sessions/{folder}/.claude/projects/`
