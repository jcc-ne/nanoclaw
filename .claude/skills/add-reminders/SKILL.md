---
name: add-reminders
description: Add macOS Reminders integration. Gives the agent four MCP tools to list, add, and complete reminders via the macOS Reminders app. macOS only — uses AppleScript via osascript. Triggers on "reminders", "add reminders", "macos reminders", "todo list".
---

# Add macOS Reminders Integration

Bridges the agent container to the macOS Reminders app. The agent gets four MCP tools (`reminders_list_lists`, `reminders_list`, `reminders_add`, `reminders_complete`). Communication is IPC-file-based: the container writes a request file, the host executes AppleScript and writes a response file.

**macOS only.** Requires `osascript` (built into macOS). The host must be running on macOS — this will not work on Linux.

## What this installs

1. **`src/ipc.ts`** — AppleScript bridge functions + request/response file watcher in the IPC poll loop
2. **`container/agent-runner/src/ipc-mcp-stdio.ts`** — four MCP tools + `sendReminderRequest` IPC helper + `REQUESTS_DIR`/`RESPONSES_DIR` path constants
3. **`container/skills/reminders/SKILL.md`** — agent-facing documentation (already included in this repo at that path)

---

## Step 1 — Modify `src/ipc.ts`

### 1a. Add imports

Add to the existing Node built-in imports at the top:

```typescript
import { execFileSync } from 'child_process';
import { tmpdir } from 'os';
```

### 1b. Add the AppleScript bridge

Insert the following block **before** the `export interface IpcDeps` declaration:

```typescript
// --- macOS Reminders via AppleScript ---

function asAppleScriptString(str: string): string {
  const parts = str.split('"');
  if (parts.length === 1) return `"${str}"`;
  return parts.map((p) => `"${p}"`).join(' & quote & ');
}

function runAppleScript(script: string): string {
  const tmpFile = path.join(tmpdir(), `nanoclaw-reminders-${Date.now()}.applescript`);
  try {
    fs.writeFileSync(tmpFile, script, 'utf-8');
    return execFileSync('osascript', [tmpFile], {
      encoding: 'utf-8',
      timeout: 10000,
    }).trim();
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch {
      // ignore
    }
  }
}

function formatDateForAppleScript(isoDate: string): string {
  const d = new Date(isoDate);
  if (isNaN(d.getTime())) return isoDate;
  const pad = (n: number) => String(n).padStart(2, '0');
  const h = d.getHours();
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 || 12;
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())}/${d.getFullYear()} ${pad(h12)}:${pad(d.getMinutes())}:${pad(d.getSeconds())} ${ampm}`;
}

async function processReminderRequest(data: {
  id: string;
  operation: string;
  params?: Record<string, string>;
}): Promise<{ result?: string; error?: string }> {
  const params = data.params || {};
  let script: string;

  switch (data.operation) {
    case 'list_lists': {
      script = `tell application "Reminders"
  set output to ""
  repeat with l in (every list)
    set output to output & name of l & linefeed
  end repeat
  return output
end tell`;
      break;
    }

    case 'list': {
      const listName = params.list || '';
      if (listName) {
        script = `tell application "Reminders"
  set output to ""
  try
    set targetList to first list whose name is ${`asAppleScriptString(listName)`}
    repeat with r in (every reminder in targetList whose completed is false)
      set reminderName to name of r
      set dueDate to ""
      if due date of r is not missing value then
        set dueDate to (due date of r as string)
      end if
      set output to output & ${`asAppleScriptString(listName)`} & tab & reminderName & tab & dueDate & linefeed
    end repeat
  end try
  return output
end tell`;
      } else {
        script = `tell application "Reminders"
  set output to ""
  repeat with l in (every list)
    set listName to name of l
    repeat with r in (every reminder in l whose completed is false)
      set reminderName to name of r
      set dueDate to ""
      if due date of r is not missing value then
        set dueDate to (due date of r as string)
      end if
      set output to output & listName & tab & reminderName & tab & dueDate & linefeed
    end repeat
  end repeat
  return output
end tell`;
      }
      break;
    }

    case 'add': {
      const name = params.name;
      const listName = params.list || 'Reminders';
      const dueDate = params.due_date || '';

      if (!name) return { error: 'name is required' };

      const dueDateLine = dueDate
        ? `  set due date of newReminder to date ${`asAppleScriptString(formatDateForAppleScript(dueDate))`}`
        : '';

      script = `tell application "Reminders"
  set targetList to first list whose name is ${`asAppleScriptString(listName)`}
  set newReminder to make new reminder at end of targetList
  set name of newReminder to ${`asAppleScriptString(name)`}
${dueDateLine}
end tell
return "ok"`;
      break;
    }

    case 'complete': {
      const name = params.name;
      const listName = params.list || '';

      if (!name) return { error: 'name is required' };

      if (listName) {
        script = `tell application "Reminders"
  set theReminder to (first reminder of list ${`asAppleScriptString(listName)`} whose name is ${`asAppleScriptString(name)`})
  set completed of theReminder to true
end tell
return "ok"`;
      } else {
        script = `tell application "Reminders"
  repeat with l in (every list)
    repeat with r in (every reminder in l)
      if name of r is ${`asAppleScriptString(name)`} and completed of r is false then
        set completed of r to true
        return "ok"
      end if
    end repeat
  end repeat
  return "not found"
end tell`;
      }
      break;
    }

    default:
      return { error: `Unknown operation: ${data.operation}` };
  }

  try {
    const result = runAppleScript(script);
    return { result };
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) };
  }
}

// --- End Reminders ---
```

> **Note:** The `asAppleScriptString(...)` and `formatDateForAppleScript(...)` calls inside template literals above are TypeScript expressions — write them as `${asAppleScriptString(listName)}` etc. in the actual source file.

### 1c. Add reminder request processing to the IPC poll loop

In `startIpcWatcher`, inside the `for (const sourceGroup of groupFolders)` loop, after the existing `tasksDir` processing block (the `try { if (fs.existsSync(tasksDir)) ... } catch` block), add:

```typescript
      // Process reminder requests from this group's IPC directory
      const requestsDir = path.join(ipcBaseDir, sourceGroup, 'requests');
      const responsesDir = path.join(ipcBaseDir, sourceGroup, 'responses');
      try {
        if (fs.existsSync(requestsDir)) {
          const requestFiles = fs
            .readdirSync(requestsDir)
            .filter((f) => f.endsWith('.json'));
          for (const file of requestFiles) {
            const filePath = path.join(requestsDir, file);
            let requestId: string | undefined;
            try {
              const data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
              fs.unlinkSync(filePath);
              if (data.type === 'reminder_request' && data.id && data.operation) {
                requestId = data.id as string;
                const response = await processReminderRequest(data);
                fs.mkdirSync(responsesDir, { recursive: true });
                fs.writeFileSync(
                  path.join(responsesDir, `${requestId}.json`),
                  JSON.stringify(response),
                );
                logger.info(
                  { requestId, operation: data.operation, sourceGroup },
                  'Reminder request processed',
                );
              }
            } catch (err) {
              logger.error(
                { file, sourceGroup, err },
                'Error processing reminder request',
              );
              if (requestId) {
                try {
                  fs.mkdirSync(responsesDir, { recursive: true });
                  fs.writeFileSync(
                    path.join(responsesDir, `${requestId}.json`),
                    JSON.stringify({ error: String(err) }),
                  );
                } catch {
                  // ignore
                }
              }
            }
          }
        }
      } catch (err) {
        logger.error(
          { err, sourceGroup },
          'Error reading IPC requests directory',
        );
      }
```

---

## Step 2 — Modify `container/agent-runner/src/ipc-mcp-stdio.ts`

### 2a. Add path constants

After the existing `const TASKS_DIR` line, add:

```typescript
const REQUESTS_DIR = path.join(IPC_DIR, 'requests');
const RESPONSES_DIR = path.join(IPC_DIR, 'responses');
```

### 2b. Add MCP tools and IPC helper

Insert the following **before** the final `// Start the stdio transport` block at the bottom of the file:

```typescript
// --- macOS Reminders tools ---

async function sendReminderRequest(
  operation: string,
  params: Record<string, string>,
): Promise<string> {
  const requestId = `rem-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const data = {
    type: 'reminder_request',
    id: requestId,
    operation,
    params,
  };

  const reqPath = path.join(REQUESTS_DIR, `${requestId}.json`);
  fs.mkdirSync(REQUESTS_DIR, { recursive: true });
  const tempPath = `${reqPath}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(data, null, 2));
  fs.renameSync(tempPath, reqPath);

  // Poll for response (host processes within IPC_POLL_INTERVAL ~1s)
  const responsePath = path.join(RESPONSES_DIR, `${requestId}.json`);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (fs.existsSync(responsePath)) {
      const response = JSON.parse(fs.readFileSync(responsePath, 'utf-8'));
      try { fs.unlinkSync(responsePath); } catch { /* ignore */ }
      if (response.error) throw new Error(response.error);
      return response.result ?? '';
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('Reminders request timed out after 15 seconds');
}

server.tool(
  'reminders_list_lists',
  'List all reminder lists available in the macOS Reminders app.',
  {},
  async () => {
    try {
      const result = await sendReminderRequest('list_lists', {});
      const lists = result.trim().split('\n').filter(Boolean);
      if (lists.length === 0) return { content: [{ type: 'text' as const, text: 'No reminder lists found.' }] };
      return { content: [{ type: 'text' as const, text: `Reminder lists:\n${lists.map((l) => `- ${l}`).join('\n')}` }] };
    } catch (err) {
      return { content: [{ type: 'text' as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` }], isError: true };
    }
  },
);

server.tool(
  'reminders_list',
  'List incomplete reminders from the macOS Reminders app. Optionally filter by list name.',
  {
    list: z.string().optional().describe('Reminder list name to filter by (e.g. "Reminders", "Shopping"). Omit to list all.'),
  },
  async (args) => {
    try {
      const result = await sendReminderRequest('list', { list: args.list ?? '' });
      const lines = result.trim().split('\n').filter(Boolean);
      if (lines.length === 0) return { content: [{ type: 'text' as const, text: 'No reminders found.' }] };
      const formatted = lines.map((line) => {
        const [list, name, due] = line.split('\t');
        return due ? `- [${list}] ${name} (due: ${due})` : `- [${list}] ${name}`;
      }).join('\n');
      return { content: [{ type: 'text' as const, text: `Reminders:\n${formatted}` }] };
    } catch (err) {
      return { content: [{ type: 'text' as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` }], isError: true };
    }
  },
);

server.tool(
  'reminders_add',
  'Add a new reminder to the macOS Reminders app.',
  {
    name: z.string().describe('The reminder title/name'),
    list: z.string().optional().describe('List to add to (defaults to "Reminders")'),
    due_date: z.string().optional().describe('Due date as ISO 8601 string e.g. "2026-03-01T14:00:00". Omit for no due date.'),
  },
  async (args) => {
    try {
      await sendReminderRequest('add', {
        name: args.name,
        list: args.list ?? 'Reminders',
        due_date: args.due_date ?? '',
      });
      const dueStr = args.due_date ? ` (due: ${args.due_date})` : '';
      return { content: [{ type: 'text' as const, text: `Reminder added: "${args.name}"${dueStr}` }] };
    } catch (err) {
      return { content: [{ type: 'text' as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` }], isError: true };
    }
  },
);

server.tool(
  'reminders_complete',
  'Mark a reminder as complete in the macOS Reminders app.',
  {
    name: z.string().describe('The exact reminder name to mark as complete'),
    list: z.string().optional().describe('List to search in. Omit to search all lists.'),
  },
  async (args) => {
    try {
      const result = await sendReminderRequest('complete', {
        name: args.name,
        list: args.list ?? '',
      });
      if (result === 'not found') {
        return { content: [{ type: 'text' as const, text: `Reminder not found: "${args.name}"` }], isError: true };
      }
      return { content: [{ type: 'text' as const, text: `Marked as complete: "${args.name}"` }] };
    } catch (err) {
      return { content: [{ type: 'text' as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` }], isError: true };
    }
  },
);

// --- End Reminders ---
```

---

## Step 3 — Create `container/skills/reminders/SKILL.md`

Create the file at that path with the following content (agent-facing documentation):

```markdown
# macOS Reminders

You have access to the macOS Reminders app via these MCP tools.

## Available Tools

### `reminders_list_lists`
List all reminder lists (e.g. "Reminders", "Shopping", "Work").

### `reminders_list`
List all incomplete reminders. Optionally filter by list.

Output format per reminder: `[List] Name (due: date)` or `[List] Name`

### `reminders_add`
Add a new reminder.

- `list` defaults to "Reminders" if omitted
- `due_date` is ISO 8601 local time — no `Z` suffix (e.g. `"2026-03-01T14:00:00"`)

### `reminders_complete`
Mark a reminder as done. Name must match exactly (case-sensitive).

## Notes

- macOS will prompt for Reminders permission the first time — grant it in System Settings → Privacy & Security → Reminders
- Due dates use the local timezone of the Mac
- Completed reminders are not returned by `reminders_list`
- If a list name doesn't exist, `reminders_add` will error — use `reminders_list_lists` to check first
```

---

## Step 4 — Build and restart

```bash
npm run build

# macOS
launchctl kickstart -k gui/$(id -u)/com.nanoclaw

# Linux (will not have osascript — reminders tools will time out)
systemctl --user restart nanoclaw
```

The container image does **not** need to be rebuilt — the MCP changes are compiled into the agent-runner TypeScript which is compiled at container startup via `npx tsc`.

---

## First use

The first time the agent calls a reminders tool, macOS will show a permission prompt:

> **"osascript" wants access to your Reminders.**

Grant it. If the prompt doesn't appear (already denied), grant manually:
**System Settings → Privacy & Security → Reminders → enable `osascript` or Terminal**

---

## Removal

1. Remove the `// --- macOS Reminders via AppleScript ---` block and the reminder request processing block from `src/ipc.ts`; remove `execFileSync` and `tmpdir` imports if no longer used
2. Remove `REQUESTS_DIR`, `RESPONSES_DIR`, `sendReminderRequest`, and the four `server.tool('reminders_*', ...)` blocks from `container/agent-runner/src/ipc-mcp-stdio.ts`
3. Delete `container/skills/reminders/SKILL.md`
4. Rebuild: `npm run build && launchctl kickstart -k gui/$(id -u)/com.nanoclaw`
