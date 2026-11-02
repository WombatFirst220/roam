# roam — renaming a project: roam rename, and every other Mac following on its own.
#
# A project's name, folder and git address can all change (an app gets a new name, its repo on GitHub
# too). roam rename rewrites the line in projects.conf and moves what the pool keeps under the old name
# (Claude Code memory and transcripts, secrets, session digests). This Mac's folder and its Claude Code
# history move along. The line keeps was=<old folder>[,<older>…]: another Mac that still has the old
# folder moves it on its next run, Claude history included — once nothing has its working directory in
# it and the new address holds the same history. Without was= it would clone the project a second time.
# GitHub keeps redirecting a renamed repo, so roam can tell: doctor, resume and roam add notice it.

repo_moved() {  # $1 remote → the SSH address GitHub now gives this repo, if it was renamed or moved (needs gh)
  local n full
  n=$(remote_norm "$1")
  case $n in github.com/*/*) n=${n#github.com/} ;; *) return 0 ;; esac
  have gh || return 0
  full=$(gh api "repos/$n" --jq .full_name 2>/dev/null) || return 0
  [ -n "$full" ] && [ "$(printf '%s' "$full" | tr 'A-Z' 'a-z')" != "$n" ] && printf 'git@github.com:%s.git\n' "$full"
  return 0
}

pool_moved_to() {  # $1 remote → the pool project whose GitHub repo now is this one (asks GitHub for each, in parallel)
  local want name dir remote extra tmp i=0
  want=$(remote_norm "$1")
  case $want in github.com/*/*) ;; *) return 0 ;; esac
  tmp=$(mktemp -d)
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    case $(remote_norm "$remote") in github.com/*/*) ;; *) continue ;; esac
    ( m=$(repo_moved "$remote"); [ -n "$m" ] && printf '%s\t%s\n' "$name" "$(remote_norm "$m")" > "$tmp/$i" ) &
    i=$((i + 1))
  done <<EOF
$(projects)
EOF
  wait
  cat "$tmp"/* 2>/dev/null | awk -F'\t' -v w="$want" '$2 == w { print $1; exit }'
  rm -rf "$tmp"
}

repo_label() { basename "$(remote_norm "$1")"; }   # git@github.com:a/b.git → b

was_dirs() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^was=//p' | tr ',' ' '; }   # $1 extras → old folders

rename_source() {  # $1 extras, $2 the project's folder now → an old folder of it that is still on this Mac
  local d
  for d in $(was_dirs "$1"); do
    [ "$d" != "$2" ] && [ -d "$PROJECTS_DIR/$d/.git" ] || continue
    projects | awk -v d="$d" '$2 == d { f = 1 } END { exit !f }' && continue   # another project lives there now
    echo "$PROJECTS_DIR/$d"; return
  done
}

cwd_users() {  # $1 folder → the programs whose working directory is in it ("zsh, claude"); roam itself aside
  local d
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  lsof -a -d cwd -F pcn 2>/dev/null | awk -v d="$d" -v me="$$" '
    /^p/ { pid = substr($0, 2) } /^c/ { cmd = substr($0, 2) }
    /^n/ { n = substr($0, 2); if ((n == d || index(n, d "/") == 1) && pid != me) print cmd }' |
    sort -u | paste -sd, - | sed 's/,/, /g'
}

# Claude Code keys history and memory by the folder's path. Merged, never "the newer folder wins":
# transcripts like claude_sync merges them, MEMORY.md keeps the lines of both, other memory files the newer.
claude_merge_dirs() {  # $1 from, $2 into, $3 project (for the log) → $1 is gone, unless something in it couldn't be merged
  local from=$1 into=$2 f s d keep=0 m
  [ -d "$from" ] || return 0
  [ "$from" = "$into" ] && return 0
  if [ ! -e "$into" ]; then mkdir -p "$(dirname "$into")" && mv "$from" "$into"; return; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f=${f#./} s="$from/$f" d="$into/$f"
    if [ ! -e "$d" ]; then mkdir -p "$(dirname "$d")" && cp -p "$s" "$d" || keep=1
    elif cmp -s "$s" "$d" || is_placeholder "$s"; then :
    elif is_placeholder "$d"; then cp -p "$s" "$d" || keep=1
    else
      case $f in
        *.jsonl) transcript_meet "$s" "$d" "$3" "$f"; is_prefix "$s" "$d" || [ "$(LC_ALL=C grep -vxF -f "$d" "$s" | grep -c .)" = 0 ] || keep=1 ;;
        MEMORY.md|*/MEMORY.md)
          m=$(mktemp); LC_ALL=C awk '$0 == "" || !seen[$0]++' "$d" "$s" > "$m" && pool_put "$m" "$d" || keep=1 ;;
        *) [ "$s" -nt "$d" ] && { cp -p "$s" "$d" || keep=1; } ;;
      esac
    fi
  done <<EOF
$(cd "$from" && find . -type f)
EOF
  if [ $keep = 0 ]; then rm -rf "$from"; else log "$3: kept $from — not everything in it could be merged yet"; fi
}

claude_dir_of() { echo "$HOME/.claude/projects/$(claude_key "$1")"; }

pool_rename_line() {  # $1 old name, $2 new name (also the folder), $3 remote, $4 was= list
  local tmp; tmp=$(mktemp)
  awk -v n="$1" -v nn="$2" -v r="$3" -v w="$4" '
    /^[[:space:]]*(#|$)/ || $1 != n { print; next }
    { extra = ""; for (i = 4; i <= NF; i++) if (index($i, "was=") != 1) extra = extra " " $i
      if (w != "") extra = extra " was=" w
      printf "%-12s %-12s %s%s\n", nn, nn, r, extra }
  ' "$PROJECTS_CONF" > "$tmp" && pool_put "$tmp" "$PROJECTS_CONF"
}

pool_rename_data() {  # $1 old name, $2 new name — what the pool keeps per project name
  local d f
  claude_merge_dirs "$CLAUDE_STORE/$1" "$CLAUDE_STORE/$2" "$2"
  if [ -d "$POOL/secrets/$1" ]; then
    mkdir -p "$POOL/secrets/$2"
    for f in "$POOL/secrets/$1"/*; do [ -f "$f" ] && [ ! -e "$POOL/secrets/$2/${f##*/}" ] && mv "$f" "$POOL/secrets/$2/"; done
    rm -rf "$POOL/secrets/$1"
  fi
  for d in "$POOL/sessions"/*/; do
    [ -f "$d$1.txt" ] && mv -f "$d$1.txt" "$d$2.txt"
  done
  return 0
}

origin_like() {  # $1 current origin URL, $2 new pool address → the new address in the same form (HTTPS stays HTTPS)
  case $1 in https://*) https_remote "$2" ;; *) printf '%s' "$2" ;; esac
}

rename_suggest() {  # $1 old folder, $2 old remote, $3 new remote → a likely new name
  local d r
  # a folder here that holds the repo under another name: someone renamed it already
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}
    [ -d "$d/.git" ] && [ "$(basename "$d")" != "$1" ] || continue
    projects | awk -v x="$(basename "$d")" '$2 == x { f = 1 } END { exit !f }' && continue
    r=$(remote_norm "$(git -C "$d" remote get-url origin 2>/dev/null)")
    [ -n "$r" ] && { [ "$r" = "$(remote_norm "$3")" ] || [ "$r" = "$(remote_norm "$2")" ]; } && { basename "$d"; return; }
  done
  [ "$(remote_norm "$3")" != "$(remote_norm "$2")" ] && repo_label "$3"
}

rename_cmd() {  # [project] [new name] [new remote] — the project under a new name, on every Mac
  local old_name old_dir old_remote extra new new_remote line old_path new_path users was cur f v m tmp moved=""
  pick_project "${1:-}" "Rename which project?" || return 1
  line=$(projects | awk -v n="$P_NAME" '$1 == n')
  read -r old_name old_dir old_remote extra <<EOF
$line
EOF
  header "rename $old_name" "$(short_name "$(scutil --get ComputerName)")"; echo
  new_remote=${3:-}
  if [ -z "$new_remote" ]; then
    tmp=$(mktemp)
    ( repo_moved "$old_remote" > "$tmp" ) & spin_while $! "${C_MUTED}asking GitHub…${C_RESET}"
    moved=$(cat "$tmp"); rm -f "$tmp"
    new_remote=${moved:-$old_remote}
    [ -n "$moved" ] && say_info "on GitHub it's $(repo_label "$moved") now ($(remote_norm "$moved"))"
  fi
  new_remote=$(ssh_remote "$new_remote")
  new=${2:-}
  if [ -z "$new" ]; then
    [ -t 0 ] || { say_err "the new name? roam rename $old_name <new name>"; return 1; }
    new=$(ask "New name" "$(rename_suggest "$old_dir" "$old_remote" "$new_remote")")
  fi
  new=$(printf '%s' "$new" | tr -c 'A-Za-z0-9._\n-' '-')
  [ -n "$new" ] || { say_err "no name given"; return 1; }
  if [ "$new" = "$old_name" ] && [ "$new" = "$old_dir" ] && [ "$(remote_norm "$new_remote")" = "$(remote_norm "$old_remote")" ]; then
    say_ok "$old_name is called that already"; return 0
  fi
  if projects | awk -v n="$new" -v o="$old_name" '($1 == n || $2 == n) && $1 != o { f = 1 } END { exit !f }'; then
    say_err "the pool has a project called $new already"; return 1
  fi
  old_path="$PROJECTS_DIR/$old_dir" new_path="$PROJECTS_DIR/$new"
  cd "$HOME" || return 1
  # this Mac's folder: maybe still under the old name, maybe renamed already (by hand, along with the repo)
  if [ -d "$old_path" ] && [ -e "$new_path" ] && ! [ "$old_path" -ef "$new_path" ]; then
    say_err "both $(short_path "$old_path") and $(short_path "$new_path") are here — keep one of them, then run this again"; return 1
  fi
  if [ ! -d "$old_path" ] && [ -e "$new_path" ]; then
    cur=$(remote_norm "$(git -C "$new_path" remote get-url origin 2>/dev/null)")
    if [ "$cur" != "$(remote_norm "$new_remote")" ] && [ "$cur" != "$(remote_norm "$old_remote")" ]; then
      say_err "$(short_path "$new_path") is here already, with another repo (${cur:-none})"; return 1
    fi
  fi
  lock
  if [ -d "$old_path/.git" ] && [ "$old_path" != "$new_path" ]; then
    if ( cd "$old_path" && in_the_middle ); then say_err "a merge or rebase is going on in $(short_path "$old_path") — finish it first"; return 1; fi
    [ -f "$(git -C "$old_path" rev-parse --git-path index.lock)" ] && { say_err "git is busy in $(short_path "$old_path") — try again in a moment"; return 1; }
    users=$(cwd_users "$old_path")
    if [ -n "$users" ]; then
      say_warn "still open in $(short_path "$old_path"): $users"
      say_info "A terminal or Claude Code session there would lose its folder — close it, or rename anyway."
      [ -t 0 ] && confirm "Rename anyway?" n || return 1
    fi
    if [ "$old_path" -ef "$new_path" ]; then   # only the case changes (the disk ignores case): via a third name
      mv "$old_path" "$old_path.roam-$$" && mv "$old_path.roam-$$" "$new_path"
    else mv "$old_path" "$new_path"; fi || { say_err "couldn't move $(short_path "$old_path")"; return 1; }
    say_ok "folder $(short_path "$new_path")"
  elif [ -d "$new_path/.git" ]; then say_ok "folder $(short_path "$new_path") ${C_MUTED}(renamed already)${C_RESET}"
  else say_info "not on this Mac — roam resume brings it as $(short_path "$new_path")"; fi
  if [ -d "$(claude_dir_of "$old_path")" ] && [ "$old_path" != "$new_path" ]; then
    claude_merge_dirs "$(claude_dir_of "$old_path")" "$(claude_dir_of "$new_path")" "$new" && say_ok "Claude Code history and memory came along"
  fi
  if [ -d "$new_path/.git" ]; then
    cur=$(git -C "$new_path" remote get-url origin 2>/dev/null)
    if [ "$(remote_norm "$cur")" != "$(remote_norm "$new_remote")" ] && [ "$(remote_norm "$cur")" = "$(remote_norm "$old_remote")" ]; then
      git -C "$new_path" remote set-url origin "$(origin_like "$cur" "$new_remote")" && say_ok "git address $(remote_norm "$new_remote")"
    fi
  fi
  # the pool: the line, and what it keeps under the old name
  was=$( { was_dirs "$extra"; [ "$old_dir" != "$new" ] && echo "$old_dir"; } | tr ' ' '\n' | grep . | grep -v -x "$new" | awk '!s[$0]++' | paste -sd, -)
  pool_rename_line "$old_name" "$new" "$new_remote" "$was"
  [ "$old_name" != "$new" ] && pool_rename_data "$old_name" "$new"
  say_ok "pool: ${C_BOLD}$old_name${C_RESET} → ${C_BOLD}$new${C_RESET}"
  registry_write
  # the other Macs follow on their next run — from roam 1.10 on. An older one would clone it a second time
  while IFS= read -r f; do [ -n "$f" ] || continue
    m=$(basename "$f" .txt); [ "$m" = "$MAC" ] && continue
    v=$(val version "$f")
    if version_ge "${v:-0}" 1.10.0; then say_info "$(mac_label "$m") follows on its next run"
    else say_warn "$(mac_label "$m") runs roam ${v:-?} — update it before its next resume (brew upgrade roam), or it clones $new a second time"; fi
  done <<EOF
$(mac_files)
EOF
  return 0
}

# On another Mac: the pool says the folder is <new>, this Mac still has <old>. → 0 when it's at its new place
rename_follow() {  # $1 name, $2 old path, $3 new path, $4 remote, $5 mode
  local name=$1 old=$2 new=$3 remote=$4 mode=$5 users url r same="" told="$CACHE/renamed-$1" msg
  cd "$HOME" || return 1
  if ( cd "$old" && in_the_middle ); then report err "$name" "renamed to $name on another Mac — finish the merge in $(short_path "$old"), then it moves"; return 1; fi
  ( cd "$old" && git_busy "$name" "the folder moves" ) && return 1
  users=$(cwd_users "$old")
  if [ -n "$users" ]; then
    msg="renamed from $(basename "$old") on another Mac — close $users in $(short_path "$old"), then roam moves the folder"
    if [ "$mode" = auto ]; then
      [ -f "$told" ] || { mkdir -p "$CACHE"; : > "$told"; notify "$name: $msg"; }; log "$name: $msg"
    else report err "$name" "$msg"; fi
    return 1
  fi
  # the same repository? Its history has to be at the new address (GitHub redirects a renamed repo anyway)
  url=$(git -C "$old" remote get-url origin 2>/dev/null)
  if [ "$(remote_norm "$url")" != "$(remote_norm "$remote")" ]; then
    git -C "$old" remote set-url origin "$(origin_like "$url" "$remote")" || return 1
    if ! ( cd "$old" && fetch_all ); then
      git -C "$old" remote set-url origin "$url"
      [ "$mode" = auto ] || report err "$name" "renamed from $(basename "$old") on another Mac — $remote isn't reachable from here yet, the folder stays until it is"
      return 1
    fi
    for r in $(git -C "$old" for-each-ref --format='%(objectname)' refs/remotes/origin/); do
      git -C "$old" merge-base HEAD "$r" >/dev/null 2>&1 && { same=1; break; }
    done
    if [ -z "$same" ]; then
      git -C "$old" remote set-url origin "$url"; ( cd "$old" && fetch_all )
      report err "$name" "the pool renamed $(basename "$old") to $name, but $remote is another repository — roam leaves $(short_path "$old") alone"
      return 1
    fi
  fi
  mv "$old" "$new" || { report err "$name" "couldn't move $(short_path "$old") to $(short_path "$new")"; return 1; }
  msg=""; [ -d "$(claude_dir_of "$old")" ] && msg=", Claude Code history included"
  claude_merge_dirs "$(claude_dir_of "$old")" "$(claude_dir_of "$new")" "$name"
  rm -f "$told"
  log "$name: followed the rename — $old → $new"
  report ok "$name" "renamed from $(basename "$old") — the folder is $(short_path "$new") now$msg"
  [ "$mode" = auto ] && notify "$(basename "$old") is $name now — the folder is $(short_path "$new")"
  return 0
}
