# Reset Session

Clears the current group's conversation context so the next message starts fresh with zero prior history. Use when the user asks to "reset", "start fresh", "clear context", or "new session".

## How to reset

Write an IPC task file:

```bash
echo '{"type":"reset_session"}' > /workspace/ipc/tasks/reset-$(date +%s).json
```

The host picks this up within ~1 second, clears the session ID from its database and memory, and confirms in the logs. No restart needed.

## What happens

- The current session transcript is orphaned (its files remain on disk but are never loaded again)
- The next message starts a brand-new Claude session with zero prior conversation history
- The message cursor is unaffected — messages keep flowing normally

## Confirm to the user

After writing the IPC file, tell the user: "Session reset. Your next message will start a fresh conversation."
