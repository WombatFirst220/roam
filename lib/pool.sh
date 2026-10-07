# roam — the pool registry, the park/resume runner with progress, and the dashboard.
#
# Every Mac writes <pool>/macs/<Mac>.txt on each command and in the background, so each Mac can see
# the others even while they sleep. Work in flight always comes fresh from the git remote.
#   key=value lines; lists use tabs:
#   project=<name>\t<branch>\t<dirty>\t<ahead>\t<parked yes|no>\t<HEAD>\t<working tree>     or  <name>\tmissing
#     HEAD and working tree (incl. uncommitted and untracked files) are hashes: equal on every Mac = in sync
#   local=<name>\t<path>          an ignored local file (name only — never contents)
#   issue=<level>\t<area>\t<text>  unmet prerequisite

TAB=$(printf '\t')

val() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
# kDrive sets aside a file it couldn't sync as <name>_blacklisted_<date>_<id>.txt — not a Mac of its own
mac_files() { ls "$MACS_DIR"/*.txt 2>/dev/null | grep -v -E '_blacklisted_|conflict'; }

# A finished file goes into the pool in place. A temp file inside the synced folder plus a rename made
# kDrive blacklist the file and keep a cut-off copy (2026-10-07) — so the temp file lives outside.
pool_put() {  # $1 finished file (removed), $2 its place in the pool
  cat "$1" > "$2" && rm -f "$1"
}
short_name() { printf '%s' "$1" | sed -E "s/^.*[’']s //; s/ (von|de|of) .*$//"; }
mac_label() { local n; n=$(val name "$MACS_DIR/$1.txt"); short_name "${n:-$1}"; }
short_path() { printf '%s' "$1" | sed "s#^$HOME#~#; s#^~/Library/Mobile Documents/com~apple~CloudDocs#iCloud Drive#; s#^~/Library/CloudStorage/##"; }

project_state() {  # $1 path → branch, dirty, ahead, parked, HEAD, working tree (tab separated) or "missing"
  local p=$1 branch dirty ahead parked=no head tree
  [ -d "$p/.git" ] || { echo missing; return; }
  branch=$(git -C "$p" symbolic-ref --short -q HEAD || echo "(detached)")
  dirty=$(git -C "$p" status --porcelain --untracked-files=normal 2>/dev/null | wc -l | tr -d ' ')
  ahead=$(git -C "$p" rev-list --count "@{u}..HEAD" 2>/dev/null || echo "?")
  git -C "$p" rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null && parked=yes
  head=$(git -C "$p" rev-parse -q --verify HEAD 2>/dev/null) head=${head:0:12}
  tree=$(cd "$p" && worktree_tree 2>/dev/null) tree=${tree:0:12}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$branch" "$dirty" "$ahead" "$parked" "${head:--}" "${tree:--}"
}

# In sync: every Mac that has the project is on the same branch and commit, with the same working tree
# (uncommitted and untracked files included). Unknown with only one Mac, or a Mac on roam before 1.8.
sync_verdict() {  # stdin: one project state per Mac → "sync", "differs" or nothing
  awk -F'\t' '$1 == "missing" || $1 == "" { next }
    $6 == "" || $6 == "-" { unknown = 1; next }
    { k = $1 FS $5 FS $6; n++; if (n == 1) first = k; else if (k != first) diff = 1 }
    END { if (diff) print "differs"; else if (n >= 2 && !unknown) print "sync" }'
}
sync_state() {  # $1 project → sync_verdict from the pool's status files
  local f
  for f in $(mac_files); do sed -n "s/^project=$1$TAB//p" "$f" | head -1; done | sync_verdict
}

registry_write() {
  local target="$MACS_DIR/$MAC.txt" tmp name dir remote extra f v
  mkdir -p "$MACS_DIR" || return
  rm -f "$MACS_DIR"/.$MAC.*.tmp "$MACS_DIR/${MAC}_blacklisted_"*.txt "$POOL/sessions/$MAC/"*_blacklisted_*.txt   # leftovers of older versions, kDrive's set-aside copies of our own files
  tmp=$(mktemp)
  {
    echo "mac=$MAC"
    echo "hwid=$(hardware_id)"
    echo "name=$(scutil --get ComputerName 2>/dev/null || echo "$MAC")"
    echo "model=$(sysctl -n hw.model 2>/dev/null), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "macos=$(sw_vers -productVersion)"
    echo "xcode=$(xcode_version)"
    echo "version=$ROAM_VERSION"
    v=$(age_pub) && [ -n "$v" ] && echo "age=$v"   # public key: the others encrypt secrets for it
    echo "seen=$(date +%s)"
    if [ -f "$DOCTOR_FILE" ]; then
      echo "doctor=$(stat -f %m "$DOCTOR_FILE") $(grep -c '^missing' "$DOCTOR_FILE") $(grep -c '^hint' "$DOCTOR_FILE")"
      awk -F"$US" -v OFS="$TAB" '$1 == "missing" || $1 == "hint" {print "issue=" $1, $2, $3}' "$DOCTOR_FILE"
    fi
    while read -r name dir remote extra; do
      [ -n "$name" ] || continue
      printf 'project=%s\t%s\n' "$name" "$(project_state "$PROJECTS_DIR/$dir")"
      [ -d "$PROJECTS_DIR/$dir/.git" ] && local_files "$PROJECTS_DIR/$dir" | while IFS= read -r f; do printf 'local=%s\t%s\n' "$name" "$f"; done
    done <<EOF
$(projects)
EOF
  } > "$tmp"
  # Only seen= moved: keep the file. kDrive puts every version another Mac replaced into the Trash —
  # a rewrite every 10 minutes filled it with hundreds. seen= still gets refreshed every HEARTBEAT seconds.
  if [ -f "$target" ] && [ $(( $(date +%s) - $(v=$(val seen "$target"); echo "${v:-0}") )) -lt "$HEARTBEAT" ] &&
     cmp -s <(grep -v '^seen=' "$tmp") <(grep -v '^seen=' "$target"); then rm -f "$tmp"; return 0; fi
  pool_put "$tmp" "$target"   # regardless of the last loop's exit status (an uncloned last project returns 1)
}

hardware_id() { ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}'; }

adopt_identity() {  # take over registry entries and snapshots this Mac left under older ids
  local hw me f old olds="" name dir remote extra sha
  [ -n "${ROAM_MAC:-}" ] && return 0   # id given explicitly: nothing to take over
  hw=$(hardware_id); me=$(scutil --get ComputerName 2>/dev/null)
  for f in $(mac_files); do
    old=$(basename "$f" .txt)
    [ "$old" = "$MAC" ] && continue
    # same machine: same hardware id, or — for entries from before hwid existed — the same computer name
    if [ -n "$hw" ] && [ "$(val hwid "$f")" = "$hw" ] || { [ -z "$(val hwid "$f")" ] && [ -n "$me" ] && [ "$(val name "$f")" = "$me" ]; }; then
      olds="$olds $old"; rm -f "$f"
    fi
  done
  # The Bonjour name (…-7) is only an old id if snapshots exist under it. Checked locally: fetching every
  # project to find out cost each roam command — and every background run — several seconds.
  if [ "$MAC_LOCAL" != "$MAC" ]; then
    case " $olds " in *" $MAC_LOCAL "*) ;; *)
      while read -r name dir remote extra; do
        [ -d "$PROJECTS_DIR/$dir/.git" ] || continue
        if git -C "$PROJECTS_DIR/$dir" rev-parse -q --verify "refs/remotes/roam/$MAC_LOCAL" >/dev/null ||
           git -C "$PROJECTS_DIR/$dir" rev-parse -q --verify "refs/roam/$MAC_LOCAL" >/dev/null; then olds="$olds $MAC_LOCAL"; break; fi
      done <<EOF
$(projects)
EOF
    esac
  fi
  [ -n "$olds" ] || return 0
  for old in $olds; do
    [ -d "$POOL/sessions/$old" ] || continue
    if [ -d "$POOL/sessions/$MAC" ]; then rm -rf "$POOL/sessions/$old"; else mv "$POOL/sessions/$old" "$POOL/sessions/$MAC"; fi
  done
  while read -r name dir remote extra; do
    [ -d "$PROJECTS_DIR/$dir/.git" ] || continue
    ( cd "$PROJECTS_DIR/$dir" && fetch_all
      for old in $olds; do
        sha=$(git rev-parse -q --verify "refs/remotes/roam/$old") || sha=$(git rev-parse -q --verify "refs/roam/$old") || continue
        if ! git rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null &&
           origin_git push "-q --force" "$sha:refs/roam/$MAC"; then
          git update-ref "refs/remotes/roam/$MAC" "$sha"; git update-ref "refs/roam/$MAC" "$sha"
          log "$name: snapshot of $old now belongs to $MAC"
        fi
        git rev-parse -q --verify "refs/remotes/roam/$old" >/dev/null && origin_git push -q ":refs/roam/$old"
        git update-ref -d "refs/remotes/roam/$old" 2>/dev/null; git update-ref -d "refs/roam/$old" 2>/dev/null
      done ) &
  done <<EOF
$(projects)
EOF
  wait
  log "identity: $MAC took over$olds"
}

other_local_files() {  # $1 project → "<mac name>\t<path>" from the other Macs' files
  local f
  for f in $(mac_files); do
    [ "$(basename "$f" .txt)" = "$MAC" ] && continue
    sed -n "s/^local=$1$TAB//p" "$f" | sed "s/^/$(val name "$f")$TAB/"
  done
}

# ---------------------------------------------------------------- park / resume with progress
report() {  # level name message → collected by run_all
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$REPORT_OUT"
  log "$1 $2: $3"
}

run_project() {  # $1 park|resume|auto, $2 name, $3 dir, $4 remote — runs in a subshell, only reports
  local mode=$1 name=$2 path="$PROJECTS_DIR/$3" remote=$4 elsewhere way
  if [ ! -d "$path/.git" ]; then
    [ "$mode" = resume ] || return 0
    elsewhere=$(cloned_elsewhere "$remote" "$3")
    if [ -n "$elsewhere" ]; then report err "$name" "already cloned as $(short_path "$elsewhere") — roam setup offers to rename it"; return; fi
    mkdir -p "$PROJECTS_DIR" || { report err "$name" "can't create $(short_path "$PROJECTS_DIR")"; return; }
    clone_project "$name" "$remote" "$path" || return
    report ok "$name" "cloned into $(short_path "$path")$CLONE_NOTE"
  fi
  cd "$path" || return
  if ! fetch_all; then
    if [ "$mode" = auto ]; then log "$name: remote unreachable: $(origin_why)"; return; fi   # being offline on the road is normal
    report err "$name" "remote unreachable: $(origin_why)"
  fi
  case $mode in
    park|auto) park_project "$name"; way=up ;;
    resume)    resume_project "$name"; way=down ;;
  esac
  if [ "$CLAUDE_SYNC" = 1 ]; then
    with_timeout "$SYNC_TIMEOUT" claude_sync "$name" "$path" $way
    [ $? = 124 ] && report err "$name" "Claude Code files: the pool didn't answer within ${SYNC_TIMEOUT}s — make the pool folder available offline in your sync app"
  fi
  if secrets_on "$name"; then
    with_timeout "$SYNC_TIMEOUT" secrets_sync "$name" $way
    [ $? = 124 ] && report err "$name" "secrets: the pool didn't answer within ${SYNC_TIMEOUT}s — make the pool folder available offline in your sync app"
  fi
  # where this Mac's AI sessions stopped, for the other Macs — never worth failing a run over
  sess_digest_write "$name" "$path" 2>/dev/null || log "$name: session digest failed"
  return 0
}

clone_project() {  # $1 name, $2 remote, $3 path — SSH first; whichever of SSH and HTTPS gets in here
  local name=$1 remote=$2 path=$3 ssh https err tried="" url
  ssh=$(ssh_remote "$remote") https=$(https_remote "$ssh")
  CLONE_NOTE=""
  for url in "$ssh" "$https"; do
    case " $tried " in *" $url "*) continue ;; esac
    tried="$tried $url"
    if err=$(git clone -q "$url" "$path" 2>&1); then
      # the pool keeps the SSH address; this Mac simply uses what works here
      [ "$url" != "$ssh" ] && CLONE_NOTE=" ${C_MUTED}(over HTTPS — SSH has no access from this Mac)${C_RESET}"
      [ "$remote" != "$ssh" ] && pool_set_remote "$name" "$ssh" && log "$name: pool address $remote → $ssh"
      return 0
    fi   # a failed clone leaves nothing behind, and never touches a folder that was already there
  done
  # git's own reason, in one line — and the usual cause behind it
  err=$(printf '%s\n' "$err" | grep -v '^Cloning' | sed 's/^fatal: //; s/^ERROR: //' | head -1)
  case $err in
    *"could not read Username"*|*"terminal prompts disabled"*|*"Authentication failed"*)
      report err "$name" "clone failed: no access over SSH or HTTPS here — add this Mac's SSH key (roam setup) or log in once: gh auth login" ;;
    *"not found"*|*"Permission denied"*|*"Could not read from remote"*)
      report err "$name" "clone failed: no access to $ssh from this Mac — ${err:-check your SSH key}" ;;
    *) report err "$name" "clone failed: ${err:-unknown reason}" ;;
  esac
  return 1
}

render_report() {  # $1 report file
  local level name msg icon
  while IFS="$TAB" read -r level name msg; do
    case $level in ok) icon=$I_OK ;; err) icon=$I_ERR ;; *) icon="${C_MUTED}·${C_RESET}" ;; esac
    if [ "$level" = info ]; then msg="${C_MUTED}$msg${C_RESET}"; fi
    printf '  %s %s %s\n' "$icon" "$(pad "${C_BOLD}$name${C_RESET}" 13)" "$msg"
  done < "$1"
}

run_all() {  # $1 park|resume|auto, $2 only this project (optional) → sets ERRORS
  local mode=$1 only=${2:-} name dir remote extra out verb
  ERRORS=0
  pool_prefer_ssh
  case $mode in park) verb="parking" ;; resume) verb="resuming" ;; *) verb="syncing" ;; esac
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    [ -z "$only" ] || [ "$name" = "$only" ] || continue
    out=$(mktemp)
    if [ "$mode" = auto ] || [ "$UI_FANCY" != 1 ]; then
      ( REPORT_OUT=$out; run_project "$mode" "$name" "$dir" "$remote" )
    else
      ( REPORT_OUT=$out; run_project "$mode" "$name" "$dir" "$remote" ) &
      spin_while $! "$(pad "${C_BOLD}$name${C_RESET}" 13) ${C_MUTED}${verb}…${C_RESET}"
    fi
    if [ "$mode" = auto ]; then
      grep "^err$TAB" "$out" | while IFS="$TAB" read -r _ n m; do notify "$n: $m"; done
    else
      render_report "$out"
    fi
    ERRORS=$((ERRORS + $(grep -c "^err$TAB" "$out")))
    rm -f "$out"
  done <<EOF
$(projects)
EOF
  cd "$HOME"
}

# ---------------------------------------------------------------- sync one project, on every Mac
# No server: a request is a file in the pool, requests/<Mac>/<id>.req, written by the asking Mac only.
# The Mac it's for picks it up in its background run — at once where launchd watches that folder, else
# within the auto-park interval — parks and resumes the project and answers in answers/<asking Mac>/.
# Requests older than 30 minutes are dropped: a Mac waking up tomorrow shouldn't act on today's click.
REQUEST_TTL=1800
SYNC_WAIT=${ROAM_SYNC_WAIT:-90}

request_send() {  # $1 Mac, $2 project → the request id
  local id tmp
  id="$(date +%s)-$MAC-$$-$RANDOM"
  mkdir -p "$POOL/requests/$1" || return 1
  tmp=$(mktemp)
  printf 'from=%s\nproject=%s\naction=sync\ntime=%s\n' "$MAC" "$2" "$(date +%s)" > "$tmp"
  pool_put "$tmp" "$POOL/requests/$1/$id.req" && echo "$id"
}

requests_handle() {  # answer the other Macs' sync requests for this Mac (in the background run)
  local f id from project time line name dir remote extra out tmp
  for f in "$POOL/requests/$MAC"/*.req; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .req) from=$(val from "$f") project=$(val project "$f") time=$(val time "$f")
    rm -f "$f"
    if [ $(( $(date +%s) - ${time:-0} )) -ge $REQUEST_TTL ]; then log "request from $from for $project expired — ignored"; continue; fi
    line=$(projects | awk -v n="$project" '$1 == n')
    [ -n "$line" ] || continue
    read -r name dir remote extra <<EOF
$line
EOF
    out=$(mktemp)
    # park (this Mac's work to the remote), resume (the asking Mac's work here, merged if both changed),
    # park again (a merge goes back, so the asking Mac ends up with exactly this state)
    ( REPORT_OUT=$out; run_project park "$name" "$dir" "$remote"; run_project resume "$name" "$dir" "$remote"
      : > "$out.park"; REPORT_OUT=$out.park; run_project park "$name" "$dir" "$remote"; rm -f "$out.park" )
    registry_write
    notify "$project synced — asked from $(mac_label "$from")"
    mkdir -p "$POOL/answers/$from"
    tmp=$(mktemp); { echo "mac=$MAC"; cat "$out"; } > "$tmp"
    pool_put "$tmp" "$POOL/answers/$from/$id.ans"
    rm -f "$out"
  done
}

sync_cmd() {  # [project] — the project in the same state on every Mac: park here, ask the others, take theirs
  local m f ids="" waiting="" id t0 errs=0 v verdict
  pick_project "${1:-}" "Sync which project?" || return 1
  lock
  header "sync $P_NAME" "$(short_name "$(scutil --get ComputerName)")"; echo
  run_all park "$P_NAME"; errs=$ERRORS
  # every other Mac that has the project: online and on roam 1.8+ → ask it; else say when it catches up
  for f in $(mac_files); do
    m=$(basename "$f" .txt); [ "$m" = "$MAC" ] && continue
    grep -q "^project=$P_NAME$TAB" "$f" || continue
    v=$(val version "$f")
    if ! version_ge "${v:-0}" 1.8.0; then say_info "$(mac_label "$m") runs roam ${v:-?} — from 1.8 on it can be synced from here"; continue; fi
    if [ $(( $(date +%s) - $(t=$(val seen "$f"); echo "${t:-0}") )) -ge "$ONLINE_SECS" ]; then
      say_info "$(mac_label "$m") is offline — it catches up when it's back (roam resume there)"; continue; fi
    id=$(request_send "$m" "$P_NAME") && { ids="$ids $id"; waiting="$waiting $m"; }
  done
  if [ -n "$ids" ]; then
    echo
    ( t0=$(date +%s)
      while [ $(( $(date +%s) - t0 )) -lt "$SYNC_WAIT" ]; do
        n=0; for id in $ids; do [ -f "$POOL/answers/$MAC/$id.ans" ] && n=$((n + 1)); done
        [ $n = $(echo $ids | wc -w) ] && exit 0
        sleep 2
      done ) & spin_while $! "${C_MUTED}waiting for$(for m in $waiting; do printf ' %s' "$(mac_label "$m")"; done)…${C_RESET}"
    for id in $ids; do
      f="$POOL/answers/$MAC/$id.ans"
      if [ -f "$f" ]; then
        m=$(val mac "$f")
        sed -n '/^mac=/!p' "$f" | while IFS="$TAB" read -r level name msg; do
          case $level in ok) printf '  %s %s %s\n' "$I_OK" "$(pad "${C_BOLD}$(mac_label "$m")${C_RESET}" 13)" "$msg" ;;
                        err) printf '  %s %s %s\n' "$I_ERR" "$(pad "${C_BOLD}$(mac_label "$m")${C_RESET}" 13)" "$msg" ;;
                        *) printf '  %s %s %s\n' "${C_MUTED}·${C_RESET}" "$(pad "${C_BOLD}$(mac_label "$m")${C_RESET}" 13)" "$msg" ;; esac
        done
        grep -q "^err$TAB" "$f" && errs=$((errs + 1))
        rm -f "$f"
      else
        say_info "no answer yet — the request stays valid for 30 min, the other Mac syncs when it picks it up"
      fi
    done
    echo
  fi
  # what the others parked meanwhile comes here now
  run_all resume "$P_NAME"; errs=$((errs + ERRORS))
  registry_write
  echo
  verdict=$(sync_state "$P_NAME")
  case $verdict in
    sync) printf '  %s %s%s is in sync%s — the same on every Mac\n' "${C_OK}≡${C_RESET}" "$C_BOLD" "$P_NAME" "$C_RESET" ;;
    differs) printf '  %s %s%s isn'"'"'t in sync yet%s — see above\n' "${C_WARN}≠${C_RESET}" "$C_BOLD" "$P_NAME" "$C_RESET" ;;
    *) printf '  %s synced here; whether every Mac is the same shows once they all run roam 1.8\n' "$I_OK" ;;
  esac
  ERRORS=$errs
}

finish_park() {
  echo
  if [ "$ERRORS" -eq 0 ]; then printf '  %s %sAll parked.%s On your next Mac: %sroam resume%s\n' "$I_OK" "$C_BOLD" "$C_RESET" "$C_ACCENT" "$C_RESET"
  else printf '  %s %s problem(s) — see above\n' "$I_ERR" "$ERRORS"; fi
}
finish_resume() {
  echo
  if [ "$ERRORS" -eq 0 ]; then printf '  %s %sReady.%s Open Xcode and Claude Code now.\n' "$I_OK" "$C_BOLD" "$C_RESET"
  else printf '  %s %s problem(s) — see above\n' "$I_ERR" "$ERRORS"; fi
}

# ---------------------------------------------------------------- dashboard
cell() {  # project state (tab separated) → short colored cell
  local branch dirty ahead parked t
  IFS="$TAB" read -r branch dirty ahead parked <<EOF
$1
EOF
  [ "$branch" = missing ] && { printf '%s—%s' "$C_LINE" "$C_RESET"; return; }
  [ -z "$branch" ] && { printf '%s?%s' "$C_MUTED" "$C_RESET"; return; }
  t="$(trunc "$branch" 12)"
  if [ "${dirty:-0}" = 0 ] && { [ "${ahead:-0}" = 0 ] || [ "$ahead" = "?" ]; }; then
    t="$t ${C_OK}✓${C_RESET}"
  else
    [ "${dirty:-0}" != 0 ] && t="$t ${C_WARN}●$dirty${C_RESET}"
    [ "${ahead:-0}" != 0 ] && [ "$ahead" != "?" ] && t="$t ${C_CYAN}↑$ahead${C_RESET}"
  fi
  [ "$parked" = yes ] && t="$t ${C_ACCENT}☁${C_RESET}"
  printf '%s' "$t"
}

fetch_everything() {
  local name dir remote extra
  while read -r name dir remote extra; do
    [ -d "$PROJECTS_DIR/$dir/.git" ] && ( cd "$PROJECTS_DIR/$dir" && fetch_all ) &
  done <<EOF
$(projects)
EOF
  wait
  registry_write
}

dashboard() {  # $1 = "quick": skip fetching from the remotes
  local f m macs="" now seen dot status doc missing hints n col name dir remote extra state states sha time from br line
  now=$(date +%s)
  if [ "${1:-}" != quick ]; then
    if [ "$UI_FANCY" = 1 ]; then ( fetch_everything ) & spin_while $! "${C_MUTED}checking the remotes…${C_RESET}"
    else fetch_everything; fi
  fi

  header "v$ROAM_VERSION" "pool · $(short_path "$POOL")"
  echo

  box_top "Macs"
  for f in $(mac_files); do
    m=$(basename "$f" .txt); macs="$macs $m"
    seen=$(val seen "$f")
    if [ "$m" = "$MAC" ]; then dot="${C_ACCENT}▸${C_RESET}"; status="${C_ACCENT}this Mac${C_RESET}"
    elif [ $((now - ${seen:-0})) -lt "$ONLINE_SECS" ]; then dot="${C_OK}●${C_RESET}"; status="online"
    else dot="${C_LINE}○${C_RESET}"; status="${C_MUTED}$(ago "${seen:-0}")${C_RESET}"; fi
    doc=$(val doctor "$f"); missing=$(echo "$doc" | awk '{print $2}'); hints=$(echo "$doc" | awk '{print $3}')
    if [ -z "$doc" ]; then doc="${C_MUTED}not checked${C_RESET}"
    elif [ "${missing:-0}" -gt 0 ]; then doc="${C_ERR}✗ $missing missing${C_RESET}"
    else doc="${C_OK}✓ ready${C_RESET}"; fi
    box_line "$dot $(pad "${C_BOLD}$(trunc "$(short_name "$(val name "$f")")" 18)${C_RESET}" 19) $(pad "$status" 12) ${C_MUTED}macOS $(pad "$(val macos "$f")" 8)Xcode $(pad "$(val xcode "$f" | sed 's/^$/–/')" 6)${C_RESET} $doc"
  done
  [ -n "$macs" ] || box_line "${C_MUTED}no Mac in this pool yet${C_RESET}"
  box_bottom

  n=$(echo $macs | wc -w | tr -d ' '); [ "$n" -lt 1 ] && n=1
  col=$(( ($(ui_width) - 6 - 14 - 12) / n )); [ $col -gt 26 ] && col=26   # 12: the sync column
  box_top "Projects"
  line="$(pad "" 14)"
  for m in $macs; do line="$line$(pad "${C_MUTED}$(trunc "$(mac_label "$m")" $((col - 2)))${C_RESET}" $col)"; done
  box_line "$line"
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    line="$(pad "${C_BOLD}$(trunc "$name" 13)${C_RESET}" 14)" states=""
    for m in $macs; do
      if [ "$m" = "$MAC" ]; then state=$(project_state "$PROJECTS_DIR/$dir")
      else state=$(sed -n "s/^project=$name$TAB//p" "$MACS_DIR/$m.txt"); fi
      line="$line$(pad "$(cell "$state")" $col)" states="$states$state"$'\n'
    done
    case $(printf '%s' "$states" | sync_verdict) in
      sync) line="$line${C_OK}≡ in sync${C_RESET}" ;;
      differs) line="$line${C_MUTED}≠ roam sync $name${C_RESET}" ;;
    esac
    box_line "$line"
  done <<EOF
$(projects)
EOF
  [ -n "$(projects)" ] || box_line "${C_MUTED}no projects yet — add one: roam add <git remote>${C_RESET}"
  box_line "${C_LINE}✓ clean · ●n uncommitted · ↑n unpushed · ☁ parked · — not cloned · ≡ the same on every Mac${C_RESET}"
  box_bottom

  box_top "In flight" "work parked on the remote"
  n=0
  while read -r name dir remote extra; do
    [ -d "$PROJECTS_DIR/$dir/.git" ] || continue
    while read -r sha time from _ _ br; do
      [ -n "$sha" ] || continue
      n=$((n + 1))
      if [ "$from" = "$MAC" ]; then
        box_line "$(pad "${C_BOLD}$name${C_RESET}" 14)${C_ACCENT}☁${C_RESET} from this Mac · $(ago "$time") · $br"
      elif [ "$sha" = "$(cat "$(git -C "$PROJECTS_DIR/$dir" rev-parse --absolute-git-dir)/roam-applied" 2>/dev/null)" ]; then
        box_line "$(pad "${C_BOLD}$name${C_RESET}" 14)${C_OK}✓${C_RESET} from $(mac_label "$from") · $(ago "$time") · $br ${C_MUTED}· resumed here${C_RESET}"
      else
        box_line "$(pad "${C_BOLD}$name${C_RESET}" 14)${C_WARN}☁${C_RESET} from $(mac_label "$from") · $(ago "$time") · $br  ${C_ACCENT}→ resume${C_RESET}"
      fi
    done <<EOF
$(git -C "$PROJECTS_DIR/$dir" for-each-ref --sort=-committerdate --format='%(objectname) %(committerdate:unix) %(refname:lstrip=3) %(subject)' refs/remotes/roam/ 2>/dev/null)
EOF
  done <<EOF
$(projects)
EOF
  [ $n -eq 0 ] && box_line "${C_MUTED}nothing — everything is committed and pushed${C_RESET}"
  box_bottom

  box_top "AI sessions" "newest per project"
  n=0
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    line=$(sess_rows "$name" "$PROJECTS_DIR/$dir" | head -1)
    [ -n "$line" ] || continue
    n=$((n + 1))
    box_line "$(pad "${C_BOLD}$(trunc "$name" 13)${C_RESET}" 14)$(sess_line "$line" "" $(( $(ui_width) - 6 - 14 - 2 - 28 )) short)"
  done <<EOF
$(projects)
EOF
  [ $n -eq 0 ] && box_line "${C_MUTED}no Claude Code or Codex sessions in these projects yet${C_RESET}"
  [ $n -gt 0 ] && box_line "${C_LINE}$(sess_icon claude) Claude  $(sess_icon codex) Codex  $(sess_icon gemini) Gemini  $(sess_icon copilot) Copilot  $(sess_icon opencode) opencode  ${C_OK}●${C_LINE} running${C_RESET}"
  box_bottom
  return 0
}

# ---------------------------------------------------------------- interactive
ACTIONS="Resume Park Sessions View New Doctor Fix Add Log Quit"
action_bar() {  # $1 selected index
  local i=0 a out=""
  for a in $ACTIONS; do
    if [ $i -eq "$1" ]; then out="$out${C_INV}${C_ACCENT} $a ${C_RESET} "
    else out="$out ${C_BOLD}$(printf '%s' "$a" | cut -c1)${C_RESET}${C_MUTED}$(printf '%s' "$a" | cut -c2-)${C_RESET}  "; fi
    i=$((i + 1))
  done
  printf '\r\033[K  %s %s←→ ⏎  or a letter%s' "$out" "$C_LINE" "$C_RESET"
}

pause() { printf '\n  %spress any key%s' "$C_MUTED" "$C_RESET"; read_key >/dev/null; }

interactive() {
  local sel=0 k act quick="" r n
  n=$(echo $ACTIONS | wc -w | tr -d ' ')
  trap 'tput cnorm 2>/dev/null; printf "\n"; exit 0' INT
  while :; do
    clear
    dashboard $quick
    quick=""
    echo
    action_bar $sel
    while :; do
      k=$(read_key)
      case $k in
        LEFT|h)  sel=$(( (sel + n - 1) % n )); action_bar $sel; continue ;;
        RIGHT|l) sel=$(( (sel + 1) % n )); action_bar $sel; continue ;;
        ENTER)   act=$(echo $ACTIONS | cut -d' ' -f$((sel + 1))) ;;
        r|R) act=Resume ;; p|P) act=Park ;; s|S) act=Sessions ;; v|V) act=View ;; n|N) act=New ;; d|D) act=Doctor ;; f|F) act=Fix ;;
        a|A) act=Add ;; L) act=Log ;; q|Q|ESC) act=Quit ;; u|U) act=Refresh ;;
        *) continue ;;
      esac
      break
    done
    printf '\r\033[K\n'
    case $act in
      Resume) printf '  %sResume%s %s· taking over work from your other Macs%s\n\n' "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
              ( lock; run_all resume; registry_write; finish_resume ); pause; quick=quick ;;
      Park)   printf '  %sPark%s %s· putting this Mac'"'"'s work on the remote%s\n\n' "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
              ( lock; run_all park; registry_write; finish_park ); pause; quick=quick ;;
      Doctor) ( doctor_run ) & spin_while $! "${C_MUTED}checking this Mac…${C_RESET}"
              clear; header "doctor" "$(short_name "$(scutil --get ComputerName)")"; doctor_show; registry_write; pause; quick=quick ;;
      Fix)    ( doctor_run ) & spin_while $! "${C_MUTED}checking this Mac…${C_RESET}"
              fix_run; doctor_run; registry_write; pause; quick=quick ;;
      Sessions) ( sessions_menu ); quick=quick ;;
      View)   ( cd / && read_cmd "" ); quick=quick ;;   # from / the picker always asks which project
      New)    ( new_project ); pause ;;
      Add)    ( add_cmd "" ); pause ;;
      Log)    echo; tail -n 25 "$LOG" 2>/dev/null | sed 's/^/  /' || say_info "no log yet"; pause; quick=quick ;;
      Quit)   echo; return 0 ;;
    esac
  done
}
