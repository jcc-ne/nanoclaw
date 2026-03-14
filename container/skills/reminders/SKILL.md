# macOS Reminders

You have access to the macOS Reminders app via these MCP tools. Use them to read and manage reminders on behalf of the user.

## Available Tools

### `reminders_list_lists`
List all reminder lists (e.g. "Reminders", "Shopping", "Work").

```
reminders_list_lists()
```

### `reminders_list`
List all incomplete reminders. Optionally filter by list.

```
reminders_list()                        # all lists
reminders_list(list: "Shopping")        # specific list
```

Output format per reminder: `[List] Name (due: date)` or `[List] Name`

### `reminders_add`
Add a new reminder.

```
reminders_add(name: "Buy milk")
reminders_add(name: "Call dentist", list: "Personal", due_date: "2026-03-01T14:00:00")
```

- `list` defaults to "Reminders" if omitted
- `due_date` is ISO 8601 local time — no `Z` suffix (e.g. `"2026-03-01T14:00:00"`)

### `reminders_complete`
Mark a reminder as done.

```
reminders_complete(name: "Buy milk")
reminders_complete(name: "Buy milk", list: "Shopping")  # faster if you know the list
```

The name must match exactly (case-sensitive).

## Example Workflows

**Check what's on the to-do list:**
1. `reminders_list()` — show everything
2. Summarise for the user

**Add something the user mentions:**
- User: "remind me to call mum tomorrow at 10"
- `reminders_add(name: "Call mum", due_date: "2026-03-01T10:00:00")`

**Morning briefing with open reminders:**
1. `reminders_list()` — get all incomplete
2. Filter/sort by due date
3. Report overdue and today's items

**Mark done from conversation:**
- User: "done with the dentist call"
- `reminders_complete(name: "Call dentist")`

## Notes

- macOS will prompt for Reminders permission the first time — grant it in System Settings → Privacy & Security → Reminders
- Due dates use the local timezone of the Mac
- Completed reminders are not returned by `reminders_list`
- If a list name doesn't exist, `reminders_add` will error — use `reminders_list_lists` to check first
