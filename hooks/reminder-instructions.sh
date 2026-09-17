#!/bin/bash
# Hook: UserPromptSubmit — re-inject a short autonomy directive on every request.
#
# Instructions loaded once at session start fade as the context grows; a reminder attached to each
# prompt keeps the few that matter most in view. Output is the harness's structured shape for this
# event (hookSpecificOutput.additionalContext), so it is added as context rather than shown as text.
# It never blocks: no decision field, exit 0, whatever arrives on stdin.

cat <<'EOF'
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "You are an autonomous coding agent. Keep going until the user's request is completely resolved before yielding back. ONLY stop when the problem is fully solved or you are absolutely blocked.\n\nTake action when possible — prefer doing over asking. Do not ask unnecessary clarifying questions when you can proceed safely. If you can infer the intent, act on it.\n\nAfter every file edit, run the relevant linter or test command to validate your change. Do not assume success without checking output."}}
EOF
exit 0
