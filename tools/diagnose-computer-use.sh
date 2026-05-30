#!/bin/zsh
set -u

codex_home="${CODEX_HOME:-$HOME/.codex}"
installed_root="$codex_home/computer-use"
plugin_cache_root="$codex_home/plugins/cache/openai-bundled/computer-use"
installer_rel="Codex Computer Use.app/Contents/SharedSupport/Codex Computer Use Installer.app/Contents/MacOS/Codex Computer Use Installer"
tool_rel="Codex Computer Use.app/Contents/SharedSupport/Codex Computer Use Installer.app/Contents/Resources/CodexComputerUseAuthorizationPluginInstallerTool"
resources_rel="Codex Computer Use.app/Contents/SharedSupport/Codex Computer Use Installer.app/Contents/Resources"

redact_home() {
  local value=$1
  print -r -- "${value//$HOME/\$HOME}"
}

latest_plugin_root() {
  local latest=""
  local root
  for root in "$plugin_cache_root"/*(N); do
    [[ -d "$root" ]] || continue
    if [[ -z "$latest" || "$root" -nt "$latest" ]]; then
      latest="$root"
    fi
  done
  print -r -- "$latest"
}

run_step() {
  local title=$1
  shift
  echo "== $(redact_home "$title") =="
  local output
  local status
  output="$("$@" 2>&1)"
  status=$?
  print -r -- "$(redact_home "$output")"
  echo "exit=$status"
  echo
}

echo "Computer Use diagnostic"
echo "date=$(date)"
echo

echo "== Runtime context =="
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  echo "CODEX_SANDBOX=$CODEX_SANDBOX"
  echo "NOTE: installer status and authorizationdb checks may report sandbox-only failures here."
  echo "If a normal Terminal reports installed, trust that for macOS authorization state."
else
  echo "not running inside the Codex shell sandbox"
fi
echo

config_file="$HOME/.codex/config.toml"
echo "== Codex approval policy =="
if [[ -f "$config_file" ]]; then
  approval_policy="$(awk -F= '/^[[:space:]]*approval_policy[[:space:]]*=/ { gsub(/[[:space:]"]/, "", $2); print $2; exit }' "$config_file")"
  if [[ -n "$approval_policy" ]]; then
    echo "approval_policy=$approval_policy"
    if [[ "$approval_policy" == "never" ]]; then
      echo "WARNING: approval_policy=never blocks Computer Use MCP approval prompts."
      echo "Change Codex approval policy to on-request, on-failure, or untrusted, then restart/reopen the session."
      echo "This must be fixed before get_app_state can capture frames."
    fi
  else
    echo "approval_policy not set in $(redact_home "$config_file")"
  fi
else
  echo "missing config: $(redact_home "$config_file")"
fi
echo

plugin_root="$(latest_plugin_root)"
for root in "$installed_root" "$plugin_root"; do
  [[ -n "$root" ]] || continue
  installer="$root/$installer_rel"
  if [[ -x "$installer" ]]; then
    run_step "installer status: $installer" "$installer" status
  else
    echo "missing installer: $(redact_home "$installer")"
    echo
  fi
done

if [[ -n "$plugin_root" ]]; then
  tool="$plugin_root/$tool_rel"
  resources="$plugin_root/$resources_rel"
elif [[ -n "$installed_root" ]]; then
  tool="$installed_root/$tool_rel"
  resources="$installed_root/$resources_rel"
else
  tool=""
  resources=""
fi

if [[ -n "$tool" && -x "$tool" ]]; then
  run_step "installer tool status" "$tool" status "$resources"
else
  echo "missing installer tool: $(redact_home "$tool")"
  echo
fi

run_step "authorizationdb read system.login.screensaver" /usr/bin/security authorizationdb read system.login.screensaver

echo "== installed plugin files =="
ls -ld \
  "/Library/Security/SecurityAgentPlugins/CodexComputerUseAuthorizationPlugin.bundle" \
  "/Library/Application Support/CodexComputerUseAuthorizationPlugin" 2>&1
echo "exit=$?"
echo

echo "== latest backup manifest =="
plutil -p "/Library/Application Support/CodexComputerUseAuthorizationPlugin/latest-backup-manifest.plist" 2>&1
echo "exit=$?"
