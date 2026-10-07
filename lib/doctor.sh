# roam — prerequisites: `roam doctor` checks, `roam fix` repairs.
#
# What a project needs is detected from its contents: *.xcodeproj → Xcode, an iOS SDK new enough for
# the deployment target, a simulator, a signing certificate for each team; package.json → Node and
# installed packages; supabase/config.toml, deno.json, docker-compose.yml → those tools; X.example →
# X should exist locally. Plus: ignored local files (credentials, config) another Mac in the pool has
# but this one lacks. Per project extras in projects.conf: needs=cmd1,cmd2 and local=path1,path2.
#
# Result line (separator \037): level  area  text  fix-command  how-to
#   level: ok | missing (blocks work) | hint (only some parts need it — backend, deployment, devices)
#          | info (worth knowing, never counted as a problem)

DOCTOR_FILE="$CACHE/doctor.tsv"
# ignored paths no Mac needs to hand over: build output, dependencies, editor state
NOISE='(^|/)(build|DerivedData|node_modules|\.build|\.swiftpm|xcuserdata|\.DS_Store|\.temp|\.branches|out|dist|\.next|\.pgdata|Pods|\.gradle|\.idea|\.vscode|__pycache__|\.venv|coverage|\.cache)(/|$)|\.xcuserstate$|\.xcuserdatad/?$|\.log$|(^|/)\.claude/settings\.local\.json$'

US=$(printf '\037')   # field separator that isn't whitespace, so empty fields survive `read`
res() { printf "%s$US%s$US%s$US%s$US%s\n" "$1" "$2" "$3" "${4:-}" "${5:-}"; }

version_ge() {  # $1 >= $2
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

have() { command -v "$1" >/dev/null 2>&1 || [ -x "/opt/homebrew/bin/$1" ] || [ -x "/usr/local/bin/$1" ] || [ -x "$HOME/.orbstack/bin/$1" ]; }

xcode_version() { xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}'; }

SIGNING_TEAMS=""
signing_teams() {  # team IDs (OU) of all valid signing identities, computed once per run
  [ -n "$SIGNING_TEAMS" ] && { echo "$SIGNING_TEAMS"; return; }
  SIGNING_TEAMS=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p' |
    while IFS= read -r n; do
      security find-certificate -c "$n" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null |
        sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p'
    done | sort -u | tr '\n' ' ')
  SIGNING_TEAMS=${SIGNING_TEAMS:- }
  echo "$SIGNING_TEAMS"
}

remote_norm() {  # git@host:a/b.git, https://host/a/b → host/a/b (lower case)
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's#^(ssh://)?git@([^:/]+)[:/]#\2/#; s#^https?://([^@/]*@)?##; s#\.git$##; s#/$##'
}

# The pool keeps SSH addresses: they work on every Mac with a key, without a stored password. HTTPS is
# what a browser hands out, so roam turns it into SSH where the host's SSH address is predictable.
ssh_remote() {  # https://github.com/a/b(.git) → git@github.com:a/b.git; anything else unchanged
  printf '%s' "$1" | sed -E '/^https?:\/\/([^@\/]*@)?(github\.com|gitlab\.com|bitbucket\.org|codeberg\.org)\/[^\/]+\/[^\/]+/{
    s#/$##; s#\.git$##
    s#^https?://([^@/]*@)?([^/]+)/([^/]+)/([^/]+)$#git@\2:\3/\4.git#
  }'
}
https_remote() {  # git@github.com:a/b.git → https://github.com/a/b.git; anything else unchanged
  printf '%s' "$1" | sed -E 's#^(ssh://)?git@(github\.com|gitlab\.com|bitbucket\.org|codeberg\.org)[:/]([^/]+)/([^/]+)$#https://\2/\3/\4#'
}

pool_set_remote() {  # $1 project name, $2 new remote — rewrites that one line of projects.conf, atomically
  local tmp="$PROJECTS_CONF.$$.tmp"
  awk -v n="$1" -v r="$2" '
    /^[[:space:]]*(#|$)/ || $1 != n { print; next }
    { extra = ""; for (i = 4; i <= NF; i++) extra = extra " " $i; printf "%-12s %-12s %s%s\n", $1, $2, r, extra }
  ' "$PROJECTS_CONF" > "$tmp" && mv "$tmp" "$PROJECTS_CONF"
}

pool_prefer_ssh() {  # HTTPS addresses in the pool become SSH (see ssh_remote); clones fall back to HTTPS anyway
  local name dir remote extra ssh
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    ssh=$(ssh_remote "$remote")
    [ "$ssh" != "$remote" ] || continue
    pool_set_remote "$name" "$ssh" && log "$name: pool address $remote → $ssh"
  done <<EOF
$(projects)
EOF
}

cloned_elsewhere() {  # $1 remote, $2 expected dir name → path of an existing clone under another name
  local want d
  want=$(remote_norm "$1")
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}
    [ -d "$d/.git" ] && [ "$(basename "$d")" != "$2" ] || continue
    [ "$(remote_norm "$(git -C "$d" remote get-url origin 2>/dev/null)")" = "$want" ] && { echo "$d"; return; }
  done
}

local_files() {  # ignored but present files of a project, without build noise
  git -C "$1" ls-files --others --ignored --exclude-standard --directory 2>/dev/null | grep -v -E "$NOISE"
}

xcode_projects() { find "$1" -maxdepth 4 -name project.pbxproj -not -path '*/node_modules/*' -not -path '*/.build/*' -not -path '*/build/*' 2>/dev/null; }

check_mac() {
  local v
  if have git && xcode-select -p >/dev/null 2>&1; then res ok "This Mac" "Git $(git --version | awk '{print $3}')"
  else res missing "This Mac" "Git / Command Line Tools" "xcode-select --install"; fi
  if [ -n "$POOL" ] && [ -w "$POOL" ]; then res ok "This Mac" "Pool $(short_path "$POOL")"
  else res missing "This Mac" "pool folder not writable: $POOL" "" "check your sync app, then run roam setup"; fi
  # Files the sync app holds online only (a size, no blocks on disk): reading one can hang, or hand out NUL bytes.
  # stat doesn't download anything.
  v=$( { find "$POOL" -type f -size +0c -print0 2>/dev/null | xargs -0 stat -f %b 2>/dev/null; } | grep -c '^0$')
  [ "${v:-0}" -gt 0 ] && res hint "This Mac" "$v file$([ "$v" = 1 ] || echo s) in the pool $([ "$v" = 1 ] && echo is || echo are) online only on this Mac" "" "make the pool folder available offline in your sync app (kDrive: Make available offline · iCloud Drive: Keep Downloaded)"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then res ok "This Mac" "Auto-park every $INTERVAL min"
  else res missing "This Mac" "Auto-park is not running" "roam setup"; fi
  have roam && res ok "This Mac" "roam on PATH" || res hint "This Mac" "roam is not on PATH" "" "add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to ~/.zshrc"
  have brew && res ok "This Mac" "Homebrew" || res hint "This Mac" "Homebrew (most fixes use it)" "" "https://brew.sh"
  if have claude; then
    v=$(claude --version 2>/dev/null | awk '{print $1}'); res ok "This Mac" "Claude Code $v"
  else res hint "This Mac" "Claude Code" "" "https://claude.com/claude-code"; fi
  have jq && res ok "This Mac" "jq (AI session details)" || res hint "This Mac" "jq — roam sessions shows only titles without it" "brew install jq"
  if secrets_anywhere; then
    have age && res ok "This Mac" "age (secrets travel encrypted)" || res missing "This Mac" "age — secrets can't travel without it" "brew install age"
  fi
}

check_xcode() {  # once per run, if any project uses Xcode
  if [ -z "$(xcode_version)" ] || xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
    res missing Xcode "full Xcode" "" "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
    return
  fi
  res ok Xcode "Xcode $(xcode_version)"
  xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 ||
    res missing Xcode "first-launch setup after install/update" "sudo xcodebuild -runFirstLaunch"
  if xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS'; then
    res ok Xcode "iOS Simulator $(xcrun simctl list runtimes 2>/dev/null | sed -n 's/^iOS \([0-9.]*\).*/\1/p' | tail -1)"
  else
    res hint Xcode "iOS Simulator runtime" "xcodebuild -downloadPlatform iOS"
  fi
}

check_docker() {  # $1 project — Docker CLI, or an installed but never started OrbStack / Docker Desktop
  if have docker; then res ok "$1" "Docker"
  elif [ -d /Applications/OrbStack.app ]; then
    res hint "$1" "Docker (web/deployment): OrbStack is installed but was never started" "open -a OrbStack" "OrbStack sets up the docker command on its first start"
  elif [ -d /Applications/Docker.app ]; then
    res hint "$1" "Docker (web/deployment): Docker Desktop is installed but not running" "open -a Docker"
  else res hint "$1" "Docker (web/deployment)" "brew install --cask orbstack"; fi
}

check_project() {  # $1 name, $2 path, $3 remote, $4 extra columns
  local name=$1 path=$2 remote=$3 extra=$4 pbx target sdk teams t d f mgr elsewhere c required n m
  if [ ! -d "$path/.git" ]; then
    elsewhere=$(cloned_elsewhere "$remote" "$(basename "$path")")
    if [ -n "$elsewhere" ]; then res missing "$name" "cloned as $(short_path "$elsewhere") instead of $(short_path "$path")" "" "roam setup offers to rename it"
    else res missing "$name" "not on this Mac yet" "roam resume"; fi
    return
  fi
  if git -C "$path" ls-remote -q --heads origin >/dev/null 2>&1; then res ok "$name" "Remote reachable"
  else res missing "$name" "remote not reachable: $remote" "" "add your SSH key at your git host (roam setup walks you through it)"; fi
  # Claude Code files (transcripts, memory) the sync app left as NUL bytes: resume restores them from the pool's copy
  n=0 m=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$CLAUDE_STORE/$name/$f" ] && ! is_placeholder "$CLAUDE_STORE/$name/$f"; then n=$((n + 1)); else m=$((m + 1)); fi
  done <<EOF
$(placeholder_files "$path")
EOF
  [ $n -gt 0 ] && res hint "$name" "$n Claude Code file$([ $n = 1 ] || echo s) here $([ $n = 1 ] && echo is || echo are) empty (the sync app never downloaded $([ $n = 1 ] && echo it || echo them))" "roam resume" "roam resume restores them from the pool"
  [ $m -gt 0 ] && res info "$name" "$m Claude Code file$([ $m = 1 ] || echo s) here $([ $m = 1 ] && echo is || echo are) empty, with no good copy in the pool"

  # Xcode (Mac-wide parts are covered once by check_xcode)
  pbx=$(xcode_projects "$path")
  if [ -n "$pbx" ] && [ -n "$(xcode_version)" ]; then
    target=$(printf '%s\n' "$pbx" | while IFS= read -r f; do grep -h 'IPHONEOS_DEPLOYMENT_TARGET' "$f"; done | grep -o '[0-9][0-9.]*' | sort -t. -k1,1n -k2,2n | tail -1)
    if [ -n "$target" ]; then
      sdk=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)
      if [ -n "$sdk" ] && version_ge "$sdk" "$target"; then res ok "$name" "iOS SDK $sdk ≥ target iOS $target"
      else res missing "$name" "iOS SDK ${sdk:-none} is too old for target iOS $target" "" "install a newer Xcode"; fi
    fi
    teams=$(printf '%s\n' "$pbx" | while IFS= read -r f; do sed -n 's/.*DEVELOPMENT_TEAM = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' "$f"; done | sort -u)
    for t in $teams; do
      case " $(signing_teams) " in
        *" $t "*) res ok "$name" "Signing certificate for team $t" ;;
        *) res hint "$name" "no signing certificate for team $t (devices/TestFlight)" "" "Xcode › Settings › Accounts: sign in; the certificate is created on first build" ;;
      esac
    done
  fi

  # Node
  find "$path" -maxdepth 3 -name package.json -not -path '*/node_modules/*' 2>/dev/null | while IFS= read -r f; do
    d=$(dirname "$f"); c=${d#$path/}; [ "$d" = "$path" ] && c="."
    if ! have node; then res hint "$name" "Node ($c)" "brew install node"; continue; fi
    if [ ! -d "$d/node_modules" ]; then
      mgr="npm install"
      [ -f "$d/package-lock.json" ] && mgr="npm ci"
      [ -f "$d/pnpm-lock.yaml" ] && mgr="pnpm install"
      [ -f "$d/yarn.lock" ] && mgr="yarn install"
      res hint "$name" "packages in $c not installed" "cd \"$d\" && $mgr"
    else res ok "$name" "Node $(node --version 2>/dev/null) · packages in $c"; fi
  done

  [ -n "$(find "$path" -maxdepth 3 -path '*/supabase/config.toml' 2>/dev/null)" ] && {
    have supabase && res ok "$name" "Supabase CLI" || res hint "$name" "Supabase CLI (backend)" "brew install supabase/tap/supabase"; }
  [ -n "$(find "$path" -maxdepth 3 -name deno.json -not -path '*/node_modules/*' 2>/dev/null)" ] && {
    have deno && res ok "$name" "Deno" || res hint "$name" "Deno (backend)" "brew install deno"; }
  [ -n "$(find "$path" -maxdepth 3 \( -name 'docker-compose*.yml' -o -name 'compose.yml' -o -name Dockerfile \) -not -path '*/node_modules/*' 2>/dev/null)" ] && {
    check_docker "$name"; }

  # extra commands from projects.conf: needs=swiftlint,fastlane
  for c in $(printf '%s' "$extra" | tr ' ' '\n' | sed -n 's/^needs=//p' | tr ',' ' '); do
    have "$c" && res ok "$name" "$c" || res missing "$name" "$c" "brew install $c"
  done

  # local files: local=… are required (missing → ✗). Everything else is information only — shown once
  # per project, never counted as a problem: optional templates and files only another Mac has.
  required=" $(printf '%s' "$extra" | tr ' ' '\n' | sed -n 's/^local=//p' | tr ',' ' ') "
  for f in $required; do
    [ -e "$path/$f" ] && res ok "$name" "$f present" ||
      res missing "$name" "$f" "" "not in git — copy it from your password manager or another Mac"
  done
  f=$(git -C "$path" ls-files 2>/dev/null | grep -E '\.example$' | while IFS= read -r t; do
        [ "${required#* ${t%.example} }" != "$required" ] && continue
        [ -e "$path/${t%.example}" ] || printf '%s\n' "${t%.example}"
      done)
  [ -n "$f" ] && res info "$name" "optional, not here: $(list_short "$f")" "" "from templates (*.example) — only needed for local overrides"
  other_local_files "$name" | while IFS="$TAB" read -r m f; do
    [ -e "$path/$f" ] || printf '%s\t%s\n' "$m" "$f"
  done | sort | awk -F"$TAB" '{ if ($1 != m) { if (m != "") print m "\t" l; m = $1; l = $2 } else l = l "\034" $2 } END { if (m != "") print m "\t" l }' |
  while IFS="$TAB" read -r m f; do
    f=$(printf '%s' "$f" | tr '\034' '\n')
    res info "$name" "only on $(short_name "$m"), not in git: $(list_short "$f")" "" "copy what you need from that Mac or your password manager"
  done
}

list_short() {  # lines → "a, b, c +5 more"
  local n
  n=$(printf '%s\n' "$1" | grep -c .)
  if [ "$n" -le 3 ]; then printf '%s\n' "$1" | paste -sd, - | sed 's/,/, /g'
  else printf '%s +%s more' "$(printf '%s\n' "$1" | head -3 | paste -sd, - | sed 's/,/, /g')" $((n - 3)); fi
}

doctor_run() {
  local name dir remote extra
  mkdir -p "$CACHE"
  {
    check_mac
    while read -r name dir remote extra; do
      [ -n "$name" ] && [ -n "$(xcode_projects "$PROJECTS_DIR/$dir")" ] && { check_xcode; break; }
    done <<EOF
$(projects)
EOF
    while read -r name dir remote extra; do
      [ -n "$name" ] && check_project "$name" "$PROJECTS_DIR/$dir" "$remote" "$extra"
    done <<EOF
$(projects)
EOF
  } > "$DOCTOR_FILE.$$"
  mv "$DOCTOR_FILE.$$" "$DOCTOR_FILE"   # regardless of the last check's exit status
}

doctor_if_due() {  # background: at most hourly — xcodebuild and security are not free
  [ -f "$DOCTOR_FILE" ] && [ -z "$(find "$DOCTOR_FILE" -mmin +60 2>/dev/null)" ] || doctor_run
}

doctor_show() {
  local level area text cmd howto prev="" icon missing hints fixable w
  [ -f "$DOCTOR_FILE" ] || return
  w=$(( $(ui_width) - 8 ))
  while IFS="$US" read -r level area text cmd howto; do
    if [ "$area" != "$prev" ]; then printf '\n  %s%s%s\n' "$C_BOLD" "$area" "$C_RESET"; prev=$area; fi
    case $level in
      ok)      icon=$I_OK ;;
      missing) icon=$I_ERR ;;
      info)    icon="${C_MUTED}ⓘ${C_RESET}" ;;
      *)       icon=$I_WARN ;;
    esac
    if [ "$level" = ok ] || [ "$level" = info ]; then printf '    %s %s%s%s\n' "$icon" "$C_MUTED" "$text" "$C_RESET"
    else printf '    %s %s\n' "$icon" "$text"; fi
    [ -n "$cmd" ] && printf '      %sfix%s %s%s%s\n' "$C_ACCENT" "$C_RESET" "$C_CYAN" "$(trunc "$cmd" $w)" "$C_RESET"
    [ -n "$howto" ] && printf '      %s→ %s%s\n' "$C_MUTED" "$howto" "$C_RESET"
  done < "$DOCTOR_FILE"
  missing=$(grep -c "^missing" "$DOCTOR_FILE"); hints=$(grep -c "^hint" "$DOCTOR_FILE")
  fixable=$(awk -F"$US" '$1 != "ok" && $1 != "info" && $4 != ""' "$DOCTOR_FILE" | grep -c .)
  echo
  rule
  if [ "$missing" -eq 0 ] && [ "$hints" -eq 0 ]; then
    printf '  %s %sAll set — this Mac has everything your projects need.%s\n' "$I_OK" "$C_BOLD" "$C_RESET"
  else
    printf '  %s%s missing%s · %s%s hints%s' "$C_ERR" "$missing" "$C_RESET" "$C_WARN" "$hints" "$C_RESET"
    [ "$fixable" -gt 0 ] && printf ' · %s fixable → %sroam fix%s' "$fixable" "$C_ACCENT" "$C_RESET"
    echo
  fi
}

fix_run() {
  local level area text cmd howto n=0
  [ -t 0 ] || { echo "roam fix needs a terminal (it asks before every step)."; return; }
  while IFS="$US" read -r level area text cmd howto; do
    case $level in ok|info) continue ;; esac
    n=$((n + 1))
    printf '\n  %s %s%s%s · %s\n' "$([ "$level" = missing ] && echo "$I_ERR" || echo "$I_WARN")" "$C_BOLD" "$area" "$C_RESET" "$text"
    if [ -n "$cmd" ]; then
      printf '    %s$ %s%s\n' "$C_CYAN" "$cmd" "$C_RESET"
      if confirm "Run it?" y; then
        if ( cd "$HOME" && eval "$cmd" ) </dev/tty; then say_ok "done"; else say_err "failed"; fi
      fi
    else
      printf '    %syour turn:%s %s\n' "$C_WARN" "$C_RESET" "$howto"
    fi
  done <<EOF
$(cat "$DOCTOR_FILE")
EOF
  [ $n -eq 0 ] && say_ok "Nothing to fix — this Mac has everything."
}
