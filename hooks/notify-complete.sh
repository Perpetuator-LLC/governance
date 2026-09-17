#!/bin/bash
# Hook: Stop — Send desktop notification when Claude finishes a task
# Works on macOS (osascript) and Linux (notify-send)

if [[ "$(uname)" == "Darwin" ]]; then
  osascript -e 'display notification "Task complete" with title "Claude Code"' 2>/dev/null
elif command -v notify-send &>/dev/null; then
  notify-send "Claude Code" "Task complete" 2>/dev/null
fi

exit 0
