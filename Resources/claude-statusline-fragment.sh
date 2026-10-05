# Source after your existing status line has read stdin into the variable input.
# Local official rate_limits only. No credentials, networking or model call.
# The capability guard also makes a rollback to an older Arqmeter safe.
arqmeter_status_bridge_binary="$HOME/Applications/Arqmeter.app/Contents/MacOS/Arqmeter"
arqmeter_status_bridge_info="$HOME/Applications/Arqmeter.app/Contents/Info.plist"
if [ -x "$arqmeter_status_bridge_binary" ] &&
   [ "$(/usr/libexec/PlistBuddy -c 'Print :ARQClaudeStatusBridge' "$arqmeter_status_bridge_info" 2>/dev/null)" = "true" ]; then
    printf '%s' "${input:-}" | "$arqmeter_status_bridge_binary" --capture-claude-status >/dev/null 2>&1 || true
fi
