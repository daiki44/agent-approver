# Claude Code integration

Agent Approver integrates with Claude Code through the `PermissionRequest` and `PostToolUse` command hooks. The adapter translates Claude Code's hook JSON into the app's local socket protocol and translates the user's decision back into Claude Code's hook response format.

Official references:

- [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks)
- [Automate workflows with hooks](https://code.claude.com/docs/en/hooks-guide)
- [Claude Code permissions](https://code.claude.com/docs/en/permissions)

## Requirements

- macOS 14.0+
- Python 3
- Claude Code CLI

## Install

The current Makefile uses the following local checkout layout:

```bash
git clone https://github.com/daiki44/agent-approver.git ~/.claude/claude-approver
cd ~/.claude/claude-approver
make install
```

`make install` builds the Swift app, creates the app bundle, registers the hooks in `~/.claude/settings.json`, and installs a LaunchAgent for automatic startup.

Restart Claude Code after installation, or run `/hooks` to confirm that the `PermissionRequest` and `PostToolUse` hooks are visible.

To register the hooks without rebuilding the app:

```bash
python3 scripts/register_hook.py
```

To remove the Claude Code integration:

```bash
make uninstall
```

## Supported Claude Code behavior

- Standard tool permission requests such as Bash, file edits, and MCP tools appear in the menu bar popover.
- `AskUserQuestion` requests are shown with a shortcut back to the terminal, because answers cannot be injected through this permission hook.
- `ExitPlanMode` requests have a dedicated plan approval card.
- Permission suggestions expose Claude Code's `updatedPermissions` choices as “Always Allow” options.
- `PostToolUse` removes stale cards after a tool completes outside the app or after terminal passthrough.
- Plan approval cards answered in the terminal are removed when any main-agent tool completes in the same session. Claude Code fires no hook when a plan is rejected in the terminal, so the model resuming work is the only signal; a rejected plan followed by a text-only reply keeps its card until the 300-second timeout.
- Requests originating from supported Claude Code subagent signals are auto-approved by the Claude adapter as documented in `CLAUDE.md`.

## Decision and passthrough behavior

When the app is available, the adapter returns a Claude Code `PermissionRequest` decision:

- **Allow** returns `decision.behavior: "allow"`.
- **Deny** returns `decision.behavior: "deny"`, with an optional message.
- **Always Allow** returns Claude Code `updatedPermissions` entries.
- **Dismiss** closes the socket without a decision so Claude Code handles the request normally in the terminal.

The adapter is fail-open. If the app, socket, or hook fails, it exits in the way Claude Code expects for passthrough and leaves the native permission flow available.

## Troubleshooting

### The app does not receive requests

Check the hook registration and socket:

```bash
python3 scripts/register_hook.py
ls -l "$HOME/Library/Application Support/ClaudeApprover/claude-approver.sock"
```

Restart Claude Code after changing `~/.claude/settings.json`, then run `/hooks` and verify the command paths.

### The menu bar app does not start

```bash
launchctl list | grep claude.approver
tail -f "$HOME/Library/Logs/ClaudeApprover/stderr.log"
```

### Debug logging

```bash
export CLAUDE_APPROVER_DEBUG=1
tail -f "$HOME/.claude/approver_debug.log"
```
