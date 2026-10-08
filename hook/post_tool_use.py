#!/usr/bin/env python3
"""
PostToolUse Hook: Tool Completion Notification
ツール実行完了時に発火し、ClaudeApprover.app に完了通知を送信する。
GUI に残っているリクエストを確実に削除するセーフティネット。

Exit codes:
  0 - 常に 0 (PostToolUse はツール実行に影響しない)
"""

import json
import os
import socket
import struct
import sys
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SOCKET_DIR = Path.home() / "Library" / "Application Support" / "ClaudeApprover"
SOCKET_PATH = SOCKET_DIR / "claude-approver.sock"
TIMEOUT_SECONDS = 5
LOG_PATH = Path.home() / ".claude" / "approver_debug.log"


def _debug_log(msg: str):
    if not os.environ.get("CLAUDE_APPROVER_DEBUG"):
        return
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{datetime.now().isoformat()}] [PostToolUse] {msg}\n")
    except Exception:
        pass


def _is_agent(hook_input: dict) -> bool:
    """エージェント経由の実行かどうかを判別。"""
    if "/subagents/" in hook_input.get("transcript_path", ""):
        return True
    if "agent_id" in hook_input:
        return True
    return False


def _send_completion(tool_use_id: str, session_id: str, tool_name: str, tool_input: dict) -> None:
    """Fire-and-forget で完了通知を送信。応答は不要。"""
    if not SOCKET_PATH.exists():
        _debug_log("Socket not found, skipping")
        return

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(str(SOCKET_PATH))

        message = json.dumps({
            "type": "completion",
            "tool_use_id": tool_use_id,
            "session_id": session_id,
            "tool_name": tool_name,
            # tool_input lets the app correlate this completion to a GUI card that was
            # approved OUTSIDE the app (phone/remote), where the request carries no tool_use_id.
            "tool_input": tool_input,
        }).encode("utf-8")

        header = struct.pack(">I", len(message))
        sock.sendall(header + message)
    except (ConnectionRefusedError, FileNotFoundError, OSError, socket.timeout):
        _debug_log(f"Socket error, skipping: tool_use_id={tool_use_id}")
    finally:
        try:
            sock.close()
        except Exception:
            pass


def main():
    try:
        raw = sys.stdin.read()
        hook_input = json.loads(raw)
    except (json.JSONDecodeError, Exception):
        sys.exit(0)

    tool_use_id = hook_input.get("tool_use_id", "")
    tool_name = hook_input.get("tool_name", "")
    session_id = hook_input.get("session_id", "")
    tool_input = hook_input.get("tool_input", {})

    _debug_log(f"tool={tool_name} tool_use_id={tool_use_id} session_id={session_id[:8]}")

    # Skip agent-spawned tool uses
    if _is_agent(hook_input):
        _debug_log("  -> SKIP (agent)")
        sys.exit(0)

    if not session_id:
        _debug_log("  -> SKIP (no session_id)")
        sys.exit(0)

    _send_completion(tool_use_id, session_id, tool_name, tool_input)
    _debug_log(f"  -> SENT completion")
    sys.exit(0)


if __name__ == "__main__":
    main()
