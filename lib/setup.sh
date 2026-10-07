# roam — the setup wizard (roam setup), leaving a pool (roam leave), adding projects (roam add).
# setup can be re-run any time: what's fine gets confirmed, what's missing gets fixed.

step() {  # $1 number, $2 title, $3 explanation
  local w
  w=$(ui_width)
  printf '\n  %s%s%s %s%s/7%s\n' "$C_BOLD" "$2" "$C_RESET" "$C_MUTED" "$1" "$C_RESET"
  [ -n "${3:-}" ] && printf '  %s%s%s\n' "$C_MUTED" "$3" "$C_RESET"
  echo
}

new_pool() {  # $1 dir, $2 claude_sync, $3 claude_history, $4 interval
  mkdir -p "$1/macs" "$1/claude" || return 1
  [ -f "$1/projects.conf" ] || cat > "$1/projects.conf" <<'EOF'
# roam — projects in this pool, one per line:
#   name   folder (under your projects folder, same on every Mac)   git remote   [extras]
# extras:  local=path1,path2   ignored files a project can't run without (e.g. Local.xcconfig)
#          needs=cmd1,cmd2     extra command line tools
# The folder must be identical on every Mac: Claude Code keys history and memory by path.
# Easiest way to add one: roam add <git remote>
EOF
  [ -f "$1/settings" ] || cat > "$1/settings" <<EOF
# roam — pool settings (apply to every Mac)
# carry Claude Code memory between Macs (1/0)
claude_sync = ${2:-1}
# also carry session transcripts, for claude --resume on another Mac (1/0). Transcripts contain
# everything a session saw — including credentials that were printed.
claude_history = ${3:-1}
# auto-park interval in minutes
interval_min = ${4:-10}
# new files above this size block parking a project (MB)
max_file_mb = 50
# what each Mac tells the others about its AI sessions (Claude Code, Codex), for roam sessions:
# 0 nothing · 1 titles, todos, changed files · 2 also the last prompt, reply and recap (secrets masked)
session_digest = 2
# carry ignored .env* files and the local=… files of projects.conf, encrypted with age — one key per
# Mac, it never leaves the Mac (1/0). Needs age on every Mac: brew install age
carry_secrets = 0
EOF
}

claude_move() {  # $1 old project path, $2 new: take Claude Code history and memory along
  local old="$HOME/.claude/projects/$(claude_key "$1")" new="$HOME/.claude/projects/$(claude_key "$2")"
  [ -d "$old" ] || return 0
  if [ -d "$new" ]; then rsync -a --update "$old/" "$new/"; else mv "$old" "$new"; fi
}

sync_folders() {  # known sync folders on this Mac: "label<TAB>path"
  local d
  [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] && printf 'iCloud Drive\t%s\n' "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
  for d in "$HOME/kDrive" "$HOME/Dropbox" "$HOME/Nextcloud" "$HOME/Library/CloudStorage"/*; do
    [ -d "$d" ] || continue
    case $d in */CloudStorage/iCloud*) continue ;; esac
    printf '%s\t%s\n' "$(basename "$d" | sed 's/-/ /')" "$d"
  done
}

find_pools() {  # existing pools inside the sync folders (projects.conf + settings + macs/)
  local b p
  sync_folders | cut -f2 | while IFS= read -r b; do
    find -H "$b" -maxdepth 5 \( -name node_modules -o -name .git -o -name Library -o -name '*.app' \) -prune -o \
      -name projects.conf -print 2>/dev/null | while IFS= read -r p; do
      p=$(dirname "$p"); [ -f "$p/settings" ] && [ -d "$p/macs" ] && echo "$p"
    done
  done
}

roam_command() {  # stable path of the program: with Homebrew the link in bin/, not the versioned Cellar
  case $HERE in
    */Cellar/*) echo "${HERE%%/Cellar/*}/bin/roam" ;;
    *) echo "$HERE/roam" ;;
  esac
}

git_access() {  # $1 remote: check it; for SSH remotes offer to set up a key
  local remote=$1 host pub
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new" \
    git ls-remote -q --heads "$remote" >/dev/null 2>&1 && { say_ok "access to ${C_MUTED}$remote${C_RESET}"; return 0; }
  case $remote in
    git@*:*|ssh://*) host=$(printf '%s' "$remote" | sed -E 's#^(ssh://)?git@([^:/]+).*#\2#') ;;
    *) say_err "no access to $remote — store HTTPS credentials in the keychain (git credential-osxkeychain)"; return 1 ;;
  esac
  say_err "no access to $remote"
  confirm "Set up SSH access to $host now?" y || return 1
  if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    say_info "Creating ~/.ssh/id_ed25519 — the passphrase will be kept in your keychain."
    ssh-keygen -t ed25519 -C "$(scutil --get ComputerName) (roam)" -f "$HOME/.ssh/id_ed25519" </dev/tty || return 1
  fi
  if ! grep -E "^Host[[:space:]]" "$HOME/.ssh/config" 2>/dev/null | grep -q -w "$host"; then
    printf '\nHost %s\n  User git\n  IdentityFile ~/.ssh/id_ed25519\n  AddKeysToAgent yes\n  UseKeychain yes\n' "$host" >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
  ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519" </dev/tty 2>/dev/null
  pub="$HOME/.ssh/id_ed25519.pub"
  pbcopy < "$pub"
  say_ok "public key copied to the clipboard"
  printf '    %s%s%s\n' "$C_MUTED" "$(cat "$pub")" "$C_RESET"
  case $host in
    github.com) say_info "Opening GitHub › Settings › SSH keys — paste it there."; open "https://github.com/settings/ssh/new" ;;
    gitlab.com) say_info "Opening GitLab › SSH keys — paste it there."; open "https://gitlab.com/-/user_settings/ssh_keys" ;;
    *) say_info "Add it as an SSH key at $host." ;;
  esac
  ask "Press ⏎ once the key is added" "" >/dev/null
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new" \
    git ls-remote -q --heads "$remote" >/dev/null 2>&1 && { say_ok "access works"; return 0; }
  say_err "still no access — run roam setup again later"
  return 1
}

install_agent() {
  local cmd
  cmd=$(roam_command)
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
  case $HERE in
    */Cellar/*) ;;   # Homebrew already put roam on the PATH
    *)
      mkdir -p "$HOME/.local/bin"
      ln -sf "$HERE/roam" "$HOME/.local/bin/roam"
      chmod +x "$HERE/roam"
      case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) grep -q '.local/bin' "$HOME/.zshrc" 2>/dev/null || {
             echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
             say_info "added ~/.local/bin to ~/.zshrc (takes effect in new terminal windows)"; } ;;
      esac ;;
  esac
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$cmd</string>
        <string>auto</string>
    </array>
    <key>StartInterval</key>
    <integer>$((INTERVAL * 60))</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/roam.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/roam.stderr.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" && say_ok "auto-park every $INTERVAL min ${C_MUTED}($LABEL)${C_RESET}"
}

offer_github_repos() {  # with a signed-in GitHub CLI: pick from your own repos
  local list picks n z
  have gh && gh auth status >/dev/null 2>&1 || return 0
  list=$(gh repo list --limit 100 --json sshUrl,name,pushedAt,isArchived \
           --jq 'sort_by(.pushedAt) | reverse | .[] | select(.isArchived | not) | "\(.name)\t\(.sshUrl)\t\(.pushedAt[0:10])"' 2>/dev/null |
         while IFS="$TAB" read -r name url date; do
           projects | awk '{print $3}' | while read -r x; do remote_norm "$x"; echo; done | grep -q -x "$(remote_norm "$url")" ||
             printf '%s\t%s\t%s\n' "$name" "$url" "$date"
         done)
  [ -n "$list" ] || return 0
  say_info "Your GitHub repos that aren't in the pool yet (most recent first):"
  n=0
  printf '%s\n' "$list" | while IFS="$TAB" read -r name url date; do
    n=$((n + 1)); printf '    %s%2d%s  %s %s%s%s\n' "$C_ACCENT" "$n" "$C_RESET" "$(pad "$name" 28)" "$C_MUTED" "$date" "$C_RESET"
  done
  picks=$(ask "Numbers to add, e.g. 1 3 4 (⏎ = none)" "")
  for n in $picks; do
    z=$(printf '%s\n' "$list" | sed -n "${n}p")
    [ -n "$z" ] && add_project "$(printf '%s' "$z" | cut -f2)" "$(printf '%s' "$z" | cut -f1)"
  done
}

setup() {
  local target=${1:-} a name dir remote extra elsewhere d r seen root cs ch iv pools n found
  [ -t 0 ] || { echo "roam setup needs a terminal — it asks a few questions."; return 1; }
  clear
  header "setup" "$(short_name "$(scutil --get ComputerName)")"
  printf '\n  %sWork on the same projects from every Mac — always in sync.%s\n' "$C_BOLD" "$C_RESET"
  say_info "Seven quick steps. ⏎ takes the suggestion in (parentheses)."

  # ------------------------------------------------------------ 1. pool
  step 1 "Pool" "A pool is a folder all your Macs sync — iCloud Drive, Dropbox, kDrive, a network share.
  It holds the project list, each Mac's status and (optionally) Claude Code data. Never your code."
  if [ -z "$target" ] && [ -n "$POOL" ] && [ -f "$POOL/projects.conf" ]; then
    say_info "This Mac belongs to $(short_path "$POOL")"
    confirm "Keep it?" y && target=$POOL
  fi
  if [ -z "$target" ]; then
    found=$(mktemp)
    ( find_pools | sort -u > "$found" ) & spin_while $! "${C_MUTED}looking for existing pools…${C_RESET}"
    pools=$(cat "$found"); rm -f "$found"
    n=$(printf '%s' "$pools" | grep -c .)
    a=$( { [ -n "$pools" ] && printf '%s\n' "$pools" | while IFS= read -r p; do echo "Join $(short_path "$p")"; done
           echo "Create a new pool"; echo "Enter a path"; } | choose)
    if [ "$a" -le "$n" ]; then
      target=$(printf '%s\n' "$pools" | sed -n "${a}p")
    elif [ "$a" -eq $((n + 1)) ]; then
      found=$(sync_folders)
      if [ -n "$found" ]; then
        say_info "Where should it live?"
        a=$( { printf '%s\n' "$found" | awk -F"$TAB" '{print $1}'; echo "Somewhere else"; } | choose)
        root=$(printf '%s\n' "$found" | sed -n "${a}p" | cut -f2)
      fi
      [ -n "${root:-}" ] || root=$(ask "Folder" "$HOME")
      target=$(ask "Pool folder" "$(short_path "$root/roam")")
      target=$(printf '%s' "$target" | sed "s#^~#$HOME#; s#^iCloud Drive#$HOME/Library/Mobile Documents/com~apple~CloudDocs#")
      echo
      say_info "roam can carry Claude Code's per-project memory between your Macs."
      if confirm "Carry Claude Code memory?" y; then cs=1; else cs=0; fi
      ch=0
      if [ $cs = 1 ]; then
        say_info "Transcripts let you 'claude --resume' a session on another Mac, but they contain"
        say_info "everything a session saw — including printed credentials — and land in your sync folder."
        confirm "Carry session transcripts too?" y && ch=1
      fi
      while :; do
        iv=$(ask "Auto-park every … minutes" 10)
        case $iv in ""|*[!0-9]*) say_err "a number, please" ;; *) [ "$iv" -ge 1 ] && break ;; esac
      done
      new_pool "$target" $cs $ch "$iv" || { say_err "couldn't create $target"; return 1; }
    else
      target=$(ask "Path to the pool" "")
    fi
  fi
  target=$(printf '%s' "$target" | sed "s#^~#$HOME#")
  [ -n "$target" ] && [ -f "$target/projects.conf" ] || { say_err "no pool at '$target'"; return 1; }
  POOL=$(cd "$target" && pwd -P); use_pool
  say_ok "$(short_path "$POOL") ${C_MUTED}· $(projects | grep -c .) projects · $(mac_files | grep -c .) Macs${C_RESET}"

  # ------------------------------------------------------------ 2. projects folder
  step 2 "Projects folder" "Every project lives here — at the same path on each Mac (Claude Code keys its history by path)."
  a=$(ask "Folder" "$(short_path "$PROJECTS_DIR")")
  PROJECTS_DIR=$(printf '%s' "$a" | sed "s#^~#$HOME#")
  mkdir -p "$PROJECTS_DIR" "$(dirname "$CONFIG")"
  printf 'pool = %s\nprojects_dir = %s\nmac_id = %s\n' "$POOL" "$PROJECTS_DIR" "$MAC" > "$CONFIG"
  adopt_identity
  say_ok "$(short_path "$PROJECTS_DIR") ${C_MUTED}· saved to $(short_path "$CONFIG")${C_RESET}"

  # ------------------------------------------------------------ 3. git
  step 3 "Git access" "roam moves your work through the git remotes you already use."
  if ! xcode-select -p >/dev/null 2>&1; then
    say_err "Command Line Tools are missing — macOS will install them now. Then run roam setup again."
    xcode-select --install 2>/dev/null
    return 1
  fi
  say_ok "$(git --version | sed 's/ (.*//')"
  seen=""
  while read -r name dir remote extra; do
    [ -n "$remote" ] || continue
    d=$(printf '%s' "$remote" | sed -E 's#^(ssh://)?(git@)?(https?://)?([^:/]+).*#\4#')
    case " $seen " in *" $d "*) continue ;; esac
    seen="$seen $d"
    git_access "$remote"
  done <<EOF
$(projects)
EOF
  [ -n "$seen" ] || say_info "no projects yet — access is checked when you add one"

  # ------------------------------------------------------------ 4. projects
  step 4 "Projects" "Pick what this pool should keep in sync."
  while read -r name dir remote extra; do
    [ -n "$name" ] && [ ! -d "$PROJECTS_DIR/$dir/.git" ] || continue
    elsewhere=$(cloned_elsewhere "$remote" "$dir")
    [ -n "$elsewhere" ] || continue
    say_warn "$name is cloned here as $(short_path "$elsewhere"); in the pool its folder is $dir."
    say_info "Close Xcode and Claude Code for this project first — running sessions would lose their folder."
    if confirm "Rename it to $(short_path "$PROJECTS_DIR/$dir")? (Claude history and memory move along)" n; then
      mv "$elsewhere" "$PROJECTS_DIR/$dir" && claude_move "$elsewhere" "$PROJECTS_DIR/$dir" && say_ok "renamed"
    else
      say_info "skipped — roam leaves $name alone on this Mac until it's renamed (run roam setup again)"
    fi
  done <<EOF
$(projects)
EOF
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}
    [ -d "$d/.git" ] || continue
    r=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
    projects | awk '{print $3}' | while read -r x; do remote_norm "$x"; echo; done | grep -q -x "$(remote_norm "$r")" && continue
    confirm "$(basename "$d") is here but not in the pool. Add it?" y && add_project "$r" "$(basename "$d")"
  done
  offer_github_repos
  while :; do
    r=$(ask "Another project — git remote (⏎ = done)" "")
    [ -n "$r" ] || break
    add_project "$r" ""
  done
  say_ok "$(projects | grep -c .) projects in the pool"

  # ------------------------------------------------------------ 5.–7.
  step 5 "Command & auto-park" "Every $INTERVAL minutes roam parks unfinished work on the remote — it never touches your files while you work."
  install_agent

  step 6 "Bring everything here" "Cloning what's missing and resuming work from your other Macs."
  run_all resume

  step 7 "Prerequisites" "Does this Mac have what your projects need?"
  ( doctor_run ) & spin_while $! "${C_MUTED}checking…${C_RESET}"
  doctor_show
  if [ -n "$(awk -F"$US" '$1 == "missing" || $1 == "hint"' "$DOCTOR_FILE")" ] && confirm "Fix what can be fixed now?" y; then
    fix_run; doctor_run
  fi
  registry_write

  echo; rule
  printf '  %s %s%s is in the pool.%s\n\n' "$I_OK" "$C_BOLD" "$(short_name "$(scutil --get ComputerName)")" "$C_RESET"
  printf '    %sroam%s          dashboard\n' "$C_ACCENT" "$C_RESET"
  printf '    %sroam park%s     before you switch to another Mac\n' "$C_ACCENT" "$C_RESET"
  printf '    %sroam resume%s   when you sit down at a Mac — before opening Xcode or Claude Code\n\n' "$C_ACCENT" "$C_RESET"
  say_info "Another Mac?  brew install wombatfirst220/tap/roam && roam setup"
}

leave() {
  local name dir remote extra open=""
  while read -r name dir remote extra; do
    [ -d "$PROJECTS_DIR/$dir/.git" ] && git -C "$PROJECTS_DIR/$dir" rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null && open="$open $name"
  done <<EOF
$(projects)
EOF
  [ -n "$open" ] && say_warn "This Mac still has work parked on the remote:$open — resume it on another Mac first."
  confirm "Remove $(short_name "$(scutil --get ComputerName)") from the pool? Projects and files stay where they are." n || return 0
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$AGENT_PLIST" "$MACS_DIR/$MAC.txt" "$CONFIG"
  rm -rf "$POOL/sessions/$MAC"
  [ -L "$HOME/.local/bin/roam" ] && rm -f "$HOME/.local/bin/roam"
  say_ok "done. Rejoin any time: roam setup"
}

# ---------------------------------------------------------------- roam add
add_cmd() {  # [folder | git remote] [name] — no argument: pick a folder
  if [ -z "${1:-}" ]; then add_pick
  elif [ -d "$1" ]; then add_folder "$1"
  else add_project "$1" "${2:-}"; fi
}

choose_folder() {  # the macOS folder dialog → path on stdout (nothing if cancelled or no GUI)
  osascript -e 'try' \
    -e "return POSIX path of (choose folder with prompt \"Which project folder should roam bring to your other Macs?\" default location (POSIX file \"$PROJECTS_DIR\"))" \
    -e 'end try' 2>/dev/null | sed 's#/$##'
}

add_pick() {  # folders in the projects folder that aren't in the pool yet, or any folder via Finder
  local d r labels="" dirs="" n count pooled
  [ -t 0 ] || { echo "usage: roam add <folder | git remote>"; return 1; }
  header "add" "$(short_name "$(scutil --get ComputerName)")"
  pooled=$(projects | awk '{print $3}' | while read -r x; do remote_norm "$x"; echo; done)
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}
    projects | awk '{print $2}' | grep -q -x "$(basename "$d")" && continue
    if r=$(git -C "$d" remote get-url origin 2>/dev/null); then
      printf '%s\n' "$pooled" | grep -q -x "$(remote_norm "$r")" && continue
      labels="$labels$(basename "$d")   ${C_MUTED}$(remote_norm "$r")${C_RESET}"$'\n'
    else
      labels="$labels$(basename "$d")   ${C_MUTED}no repo yet — roam creates it on GitHub${C_RESET}"$'\n'
    fi
    dirs="$dirs$d"$'\n'
  done
  count=$(printf '%s' "$dirs" | grep -c .)
  printf '\n  %sWhich project should come along to your other Macs?%s\n\n' "$C_BOLD" "$C_RESET"
  n=$( { printf '%s' "$labels"; echo "Another folder…  ${C_MUTED}(opens Finder)${C_RESET}"; echo "A git address…"; } | choose) || return 1
  if [ "$n" -le "$count" ]; then add_folder "$(printf '%s' "$dirs" | sed -n "${n}p")"
  elif [ "$n" = $((count + 1)) ]; then
    d=$(choose_folder)
    [ -n "$d" ] || d=$(ask "Folder (drag it here from Finder)" "")
    d=$(printf '%s' "$d" | sed "s#^~#$HOME#; s#\\ # #g; s#/\$##")   # dragged paths come with escaped spaces
    [ -n "$d" ] && add_folder "$d"
  else
    r=$(ask "Git address (e.g. git@github.com:you/app.git)" "")
    [ -n "$r" ] && add_project "$r" ""
  fi
}

add_folder() {  # $1 a project folder on this Mac → in the pool (new repo on GitHub if it has none yet)
  local dir name root target
  [ -d "$1" ] || { say_err "no folder $1"; return 1; }
  dir=$(cd "$1" && pwd); name=$(basename "$dir")   # the path as Claude Code saw it (symlinks kept)
  root=$(mkdir -p "$PROJECTS_DIR" && cd "$PROJECTS_DIR" && pwd -P)
  # every Mac keeps a project at the same path (Claude Code keys its history by path)
  if [ "$(cd "$dir/.." && pwd -P)" != "$root" ]; then
    target="$PROJECTS_DIR/$name"
    [ -e "$target" ] && { say_err "$(short_path "$target") exists already — rename one of them first"; return 1; }
    say_warn "$(short_path "$dir") is outside $(short_path "$PROJECTS_DIR") — every Mac keeps projects there."
    say_info "Close Xcode and Claude Code for it first — a running session would lose its folder."
    confirm "Move it to $(short_path "$target")? (Claude Code history and memory move along)" y || return 1
    mv "$dir" "$target" && claude_move "$dir" "$target" || { say_err "couldn't move it"; return 1; }
    say_ok "moved to $(short_path "$target")"
    dir=$target
  fi
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    add_project "$(git -C "$dir" remote get-url origin)" "$name"
  else
    new_project "$dir"   # no remote yet: creates the GitHub repo, pushes, adds it to the pool
  fi
}

add_project() {  # $1 remote, $2 name (optional; also the folder name)
  local remote=$1 name=${2:-}
  [ -n "$remote" ] || { echo "usage: roam add <git remote> [name]"; return 1; }
  [ -n "$name" ] || name=$(basename "$remote" .git)
  name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._\n-' '-')
  if projects | awk '{print $3}' | while read -r x; do remote_norm "$x"; echo; done | grep -q -x "$(remote_norm "$remote")"; then
    say_ok "$remote is already in the pool"; return 0
  fi
  if projects | awk '{print $1}' | grep -q -x "$name"; then say_err "the name $name is taken — try: roam add $remote <name>"; return 1; fi
  git ls-remote -q --heads "$remote" >/dev/null 2>&1 || { say_err "$remote is not reachable"; return 1; }
  printf '%-12s %-12s %s\n' "$name" "$name" "$(ssh_remote "$remote")" >> "$PROJECTS_CONF"
  say_ok "added ${C_BOLD}$name${C_RESET} ${C_MUTED}— your other Macs get it with roam resume${C_RESET}"
}
