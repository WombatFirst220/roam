# roam — sync core: work-in-progress snapshots as commits under refs/roam/<Mac> on the git remote (origin).
#
# A snapshot is a commit whose tree is the whole working directory (uncommitted and untracked files
# included, .gitignore respected). First parent = HEAD; further parents = this Mac's previous snapshot
# and the last snapshot taken over from another Mac. Whether another Mac's snapshot builds on ours is
# decided by ancestry — clocks across Macs are never trusted. Subject line: "roam <Mac> <branch>".
# A snapshot exists only while a Mac has something that isn't on the remote yet.
# roam never pushes branches: a push to main may trigger a deployment, that stays your call.
#
# Every function reports through `report ok|info|err <project> <message>`.

is_clean() { [ -z "$(git status --porcelain --untracked-files=normal)" ]; }

worktree_tree() {  # tree object of the working directory incl. untracked files; the real index stays untouched
  local idx
  idx=$(mktemp)
  cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || rm -f "$idx"
  GIT_INDEX_FILE=$idx git add -A . >/dev/null 2>&1
  GIT_INDEX_FILE=$idx git write-tree
  rm -f "$idx"
}

in_the_middle() {  # merge, rebase, cherry-pick or bisect in progress
  local g
  g=$(git rev-parse --git-dir)
  [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ] || [ -f "$g/MERGE_HEAD" ] || [ -f "$g/CHERRY_PICK_HEAD" ] || [ -f "$g/BISECT_LOG" ]
}

# The pool keeps SSH addresses, but on a Mac whose SSH key belongs to another account they get no access —
# the same repo over HTTPS often does (gh login, keychain). So every talk with origin tries SSH, then HTTPS.
origin_git() {  # $1 push|fetch, $2 options ("-q --force"), rest: refspecs → status; git's reason in ORIGIN_ERR
  local cmd=$1 opts=$2 url https
  shift 2
  ORIGIN_ERR=$(git $cmd $opts origin "$@" 2>&1) && return 0
  url=$(git remote get-url origin 2>/dev/null) https=$(https_remote "$url")
  [ -n "$url" ] && [ "$https" != "$url" ] || return 1
  case $https in
    https://github.com/*) have gh && gh auth status >/dev/null 2>&1 &&
      set -- -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$cmd" $opts "$https" "$@" ||
      set -- "$cmd" $opts "$https" "$@" ;;
    *) set -- "$cmd" $opts "$https" "$@" ;;
  esac
  ORIGIN_ERR=$(GIT_TERMINAL_PROMPT=0 git "$@" 2>&1)
}

origin_why() {  # ORIGIN_ERR → the reason in a few words
  local e
  e=$(printf '%s\n' "$ORIGIN_ERR" | sed 's/^fatal: //; s/^ERROR: //; s/^error: //' | grep -v -e '^$' -e '^Please make sure' -e '^and the repository' | head -1)
  case $ORIGIN_ERR in
    *"Could not resolve host"*|*"Network is unreachable"*|*"timed out"*|*"Failed to connect"*|*"Connection refused"*)
      echo "offline?" ;;
    *"could not read Username"*|*"terminal prompts disabled"*|*"Authentication failed"*|*"Permission denied"*|\
    *"not found"*|*"Could not read from remote"*|*"403"*)
      echo "no access from this Mac over SSH or HTTPS — add this Mac's SSH key (roam setup) or log in once: gh auth login" ;;
    *) echo "${e:-unknown reason}" ;;
  esac
}

fetch_all() {
  origin_git fetch "-q --prune" '+refs/heads/*:refs/remotes/origin/*' '+refs/roam/*:refs/remotes/roam/*'
}

snap_branch() { git log -1 --format=%s "$1" | awk '{print $3}'; }

matching_snapshot() {  # $1 tree, $2 HEAD, $3 branch, $4.. snapshots → the one that equals exactly this state
  local tree=$1 head=$2 branch=$3 s
  shift 3
  for s in "$@"; do
    [ -n "$s" ] && git cat-file -e "$s" 2>/dev/null || continue
    [ "$(git rev-parse "$s^{tree}")" = "$tree" ] && [ "$(git rev-parse "$s^")" = "$head" ] &&
      [ "$(snap_branch "$s")" = "$branch" ] && { echo "$s"; return; }
  done
}

current_matches() {  # which of the snapshots $@ equals the current state?
  matching_snapshot "$(worktree_tree)" "$(git rev-parse HEAD)" "$(git symbolic-ref --short -q HEAD || echo -)" "$@"
}

changes() {  # git diff --shortstat → "3 files +12 −4"
  local s
  s=$(git diff --shortstat "$@" | awk '{f=$1; for(i=2;i<=NF;i++){if($i~/^insertion/)a=$(i-1); if($i~/^deletion/)d=$(i-1)} printf "%s file%s", f, (f==1?"":"s"); if(a)printf " +%s",a; if(d)printf " −%s",d}')
  echo "${s:-no open changes}"
}

drop_own_snapshot() {  # delete this Mac's ref locally and on the remote
  if git rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null; then
    origin_git push -q ":refs/roam/$MAC" || return 1
    git update-ref -d "refs/remotes/roam/$MAC"
  fi
  git update-ref -d "refs/roam/$MAC" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- park
park_project() {  # $1 name; cwd is the project
  local name=$1 g head branch tree old applied new f size parents
  g=$(git rev-parse --git-dir)
  head=$(git rev-parse -q --verify HEAD) || { report info "$name" "no commits yet — skipped"; return; }
  if in_the_middle; then report err "$name" "merge/rebase in progress — not parked"; return; fi

  # Clean and fully pushed: nothing in flight. Remove an old snapshot, otherwise the other Macs
  # would keep seeing it as open work.
  if is_clean && [ -n "$(git for-each-ref --contains "$head" --count=1 refs/remotes/origin/)" ]; then
    rm -f "$g/roam-applied"
    if git rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null; then
      if drop_own_snapshot; then report ok "$name" "all pushed — old snapshot removed"
      else report err "$name" "couldn't remove the old snapshot from the remote: $(origin_why)"; fi
    else
      git update-ref -d "refs/roam/$MAC" 2>/dev/null
      report ok "$name" "nothing in flight"
    fi
    return
  fi

  f=$(git ls-files --others --exclude-standard | grep -E "$SECRET_PATTERN" | head -3 | tr '\n' ' ')
  if [ -n "$f" ]; then report err "$name" "untracked secret-looking files (${f% }) — add them to .gitignore"; return; fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    size=$(stat -f %z "$f")
    if [ "$size" -gt "$MAX_BYTES" ]; then report err "$name" "$f is $((size / 1048576)) MB — add it to .gitignore"; return; fi
  done <<EOF
$(git ls-files --others --exclude-standard)
EOF

  branch=$(git symbolic-ref --short -q HEAD || echo "-")
  tree=$(worktree_tree)
  applied=$(cat "$g/roam-applied" 2>/dev/null)
  if [ -n "$(matching_snapshot "$tree" "$head" "$branch" "$applied")" ]; then
    # exactly the snapshot taken over from another Mac — already on the remote; a copy would ping-pong
    report ok "$name" "unchanged since resume — already on the remote"
    return
  fi
  old=$(git rev-parse -q --verify "refs/roam/$MAC")
  if [ -n "$(matching_snapshot "$tree" "$head" "$branch" "$old")" ]; then
    new=$old
  else
    parents="-p $head"
    [ -n "$old" ] && parents="$parents -p $old"
    if [ -n "$applied" ] && git cat-file -e "$applied" 2>/dev/null &&
       ! { [ -n "$old" ] && git merge-base --is-ancestor "$applied" "$old"; }; then
      parents="$parents -p $applied"
    fi
    new=$(echo "roam $MAC $branch" | git commit-tree "$tree" $parents) || { report err "$name" "couldn't create the snapshot commit"; return; }
    git update-ref "refs/roam/$MAC" "$new"
  fi
  if [ "$(git rev-parse -q --verify "refs/remotes/roam/$MAC")" = "$new" ]; then
    report ok "$name" "already parked · $branch · $(changes "$head" "$new")"
    return
  fi
  if origin_git push "-q --force" "refs/roam/$MAC:refs/roam/$MAC"; then
    git update-ref "refs/remotes/roam/$MAC" "$new"
    report ok "$name" "parked · $branch · $(changes "$head" "$new")"
  else
    report err "$name" "push to the remote failed: $(origin_why)"
  fi
}

# ---------------------------------------------------------------- resume
foreign_snapshots() {  # other Macs' snapshots, newest first: "<sha> <time> <mac>"
  git for-each-ref --sort=-committerdate --format='%(objectname) %(committerdate:unix) %(refname:lstrip=3)' refs/remotes/roam/ |
    awk -v m="$MAC" '$3 != m'
}

committed_upstream() {  # $1 tree, $2 HEAD, $3 upstream: is this exact tree a commit on the way up?
  git rev-list --max-count=500 --format=%T "$2..$3" | grep -q -x "$1"
}

fast_forward() {  # $1 name. Nothing new from other Macs: fast-forward a clean branch
  local name=$1 g applied head up n
  g=$(git rev-parse --git-dir)
  up=$(git rev-parse -q --verify "@{u}" 2>/dev/null) || { report info "$name" "branch has no upstream — nothing to pull"; return; }
  head=$(git rev-parse HEAD)
  applied=$(cat "$g/roam-applied" 2>/dev/null)

  if ! is_clean; then
    # The uncommitted changes here are exactly what upstream contains at some commit between HEAD and
    # upstream (another Mac committed them — maybe with more commits on top): moving to upstream loses
    # nothing.
    if [ "$head" != "$up" ] && git merge-base --is-ancestor "$head" "$up" &&
       committed_upstream "$(worktree_tree)" "$head" "$up"; then
      git reset -q --hard "$up" && git clean -q -fd && rm -f "$g/roam-applied"
      drop_own_snapshot || report err "$name" "couldn't remove this Mac's old snapshot from the remote: $(origin_why)"
      report ok "$name" "your changes were committed on another Mac — now at $(git rev-parse --abbrev-ref '@{u}')"
      return
    fi
    # What's here is exactly a snapshot we took over, and its Mac has since withdrawn it (committed and
    # pushed). If upstream has the same content, resetting loses nothing.
    if [ -n "$applied" ] && [ -n "$(current_matches "$applied")" ] &&
       [ -z "$(git for-each-ref --points-at "$applied" refs/remotes/roam/)" ]; then
      if git merge-base --is-ancestor "$head" "$up" && [ "$(git rev-parse "$up^{tree}")" = "$(git rev-parse "$applied^{tree}")" ]; then
        git reset -q --hard "$up" && git clean -q -fd && rm -f "$g/roam-applied"
        report ok "$name" "that work got committed on the other Mac — now at $(git rev-parse --abbrev-ref '@{u}')"
        return
      fi
      report err "$name" "the other Mac withdrew its snapshot, but upstream differs. Look: git diff @{u} · drop: git reset --hard @{u}"
      return
    fi
    if [ "$head" = "$up" ]; then report info "$name" "local changes, up to date"
    else report info "$name" "local changes — not pulling ($(git rev-list --count HEAD..@{u}) new commits on the remote)"; fi
    return
  fi
  [ "$head" = "$up" ] && { report ok "$name" "up to date"; return; }
  if git merge-base --is-ancestor "$head" "$up"; then
    n=$(git rev-list --count "$head..$up")
    git merge -q --ff-only "$up" && report ok "$name" "pulled $n new commit$([ "$n" = 1 ] || echo s)"
  elif ! git merge-base --is-ancestor "$up" "$head"; then
    report err "$name" "local branch and remote have diverged — please merge yourself"
  else
    report ok "$name" "ahead of the remote — push when you're ready"
  fi
}

resume_project() {  # $1 name
  local name=$1 g foreign sha time from branch own known target applied head
  g=$(git rev-parse --git-dir)
  git rev-parse -q --verify HEAD >/dev/null || { report info "$name" "no commits yet"; return; }
  foreign=$(foreign_snapshots | head -1)
  applied=$(cat "$g/roam-applied" 2>/dev/null)
  if [ -z "$foreign" ]; then fast_forward "$name"; return; fi
  set -- $foreign; sha=$1 time=$2 from=$3
  if [ "$sha" = "$applied" ]; then
    report ok "$name" "work from $(mac_label "$from") already here"
    return
  fi
  if in_the_middle; then report err "$name" "merge/rebase in progress — nothing taken over"; return; fi
  own=$(git rev-parse -q --verify "refs/roam/$MAC")

  # Identical already (e.g. the same file arrived on both Macs): just note it, nothing to change
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$sha^")" ] && [ "$(worktree_tree)" = "$(git rev-parse "$sha^{tree}")" ]; then
    printf '%s\n' "$sha" > "$g/roam-applied"
    drop_own_snapshot || report err "$name" "couldn't remove this Mac's old snapshot from the remote: $(origin_why)"
    report ok "$name" "same as on $(mac_label "$from") already"
    return
  fi

  # 1. Commits: the local branch must be contained in the snapshot, or commits would get lost.
  branch=$(snap_branch "$sha")
  target=$(git rev-parse "$sha^")
  if [ "$branch" != "-" ] && git show-ref -q --verify "refs/heads/$branch" &&
     ! git merge-base --is-ancestor "refs/heads/$branch" "$target"; then
    report err "$name" "$branch has commits here that $(mac_label "$from")'s snapshot lacks. Look: git log --oneline $branch...refs/remotes/roam/$from^"
    return
  fi
  # 2. Local changes may only be dropped if they're safely parked and the snapshot builds on them.
  #    Otherwise both Macs were edited in parallel.
  if ! is_clean; then
    known=$(current_matches "$own" "$applied")
    if [ -z "$known" ] || ! git merge-base --is-ancestor "$known" "$sha"; then
      report err "$name" "edited here and on $(mac_label "$from") in parallel — nothing taken over. 'roam park' saves this side; compare: git diff refs/remotes/roam/$from"
      return
    fi
    git reset -q --hard && git clean -q -fd   # unchanged copy lives in $known (also on the remote)
  fi

  if [ "$branch" != "-" ]; then
    if git show-ref -q --verify "refs/heads/$branch"; then
      head=$(git rev-parse "refs/heads/$branch")
      [ "$(git symbolic-ref --short -q HEAD)" = "$branch" ] || git checkout -q "$branch" || { report err "$name" "couldn't switch to $branch"; return; }
      [ "$head" = "$target" ] || git merge -q --ff-only "$target" || { report err "$name" "fast-forward of $branch failed"; return; }
    else
      git checkout -q -b "$branch" "$target" || { report err "$name" "couldn't create $branch"; return; }
      git show-ref -q --verify "refs/remotes/origin/$branch" && git branch -q --set-upstream-to="origin/$branch"
    fi
  else
    git checkout -q --detach "$target" || { report err "$name" "checkout failed"; return; }
  fi

  # 3. Working directory = snapshot tree, index back to HEAD: changes show up as uncommitted again,
  #    new files as untracked (what was staged is not preserved).
  git read-tree -u --reset "$sha" && git reset -q || { report err "$name" "couldn't restore the working directory"; return; }
  printf '%s\n' "$sha" > "$g/roam-applied"
  # Our own snapshot is now contained in the one we took over — leaving it would offer it again later
  drop_own_snapshot || report err "$name" "couldn't remove this Mac's old snapshot from the remote: $(origin_why)"
  report ok "$name" "resumed from $(mac_label "$from") · $(ago "$time") · $branch · $(changes HEAD "$sha")"
  # More than one other Mac with open work: only the newest was taken over
  foreign_snapshots | while read -r s _ m; do
    git merge-base --is-ancestor "$s" "$sha" || report err "$name" "$(mac_label "$m") has open work too that isn't here — resume there and merge"
  done
}

# ---------------------------------------------------------------- Claude Code
claude_key() { printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g'; }

# A sync app sometimes leaves a transcript as a file of NUL bytes: right size and date, content never
# downloaded. rsync would see nothing to do — or worse, spread it over the good copy.
is_placeholder() {  # $1 file: occupies disk space, yet starts with nothing but NUL bytes
  [ "$(stat -f %b "$1" 2>/dev/null || echo 0)" -gt 0 ] && [ -z "$(head -c 512 "$1" | tr -d '\000')" ]
}

claude_sync() {  # $1 name, $2 project path, $3 up|down
  local local_dir="$HOME/.claude/projects/$(claude_key "$2")" store="$CLAUDE_STORE/$1" filter="" src dst bad f
  # Session transcripts (for claude --resume) contain everything a session saw, including printed
  # credentials. claude_history = 0 in the pool settings limits this to memory.
  [ "$CLAUDE_HISTORY" = 1 ] || filter="--include=memory/*** --exclude=*"
  if [ "$3" = up ]; then src=$local_dir dst=$store; else src=$store dst=$local_dir; fi
  [ -d "$src" ] || return 0
  mkdir -p "$dst" || return
  bad=$(mktemp)
  # Placeholders never travel; a good copy on the other side repairs one there.
  if [ "$CLAUDE_HISTORY" = 1 ]; then
    while IFS= read -r f; do
      f=${f#./}
      if is_placeholder "$src/$f"; then printf '/%s\n' "$f" >> "$bad"
      elif [ -f "$dst/$f" ] && is_placeholder "$dst/$f"; then cp -p "$src/$f" "$dst/$f" && log "$1: repaired the empty transcript $f"; fi
    done <<EOF
$(cd "$src" && find . -type f -name '*.jsonl')
EOF
  fi
  # --update: the newer file wins. Transcripts have unique names; conflicts can only happen
  # with memory files edited on two Macs at the same time.
  rsync -a --update $filter --exclude-from="$bad" "$src/" "$dst/"
  rm -f "$bad"
}

placeholder_transcripts() {  # $1 project path → this Mac's transcripts that are only NUL bytes
  local d="$HOME/.claude/projects/$(claude_key "$1")" f
  [ -d "$d" ] || return 0
  find "$d" -type f -name '*.jsonl' | while IFS= read -r f; do is_placeholder "$f" && echo "$f"; done
}
