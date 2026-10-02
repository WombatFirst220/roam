# roam — the pool registry, the park/resume runner with progress, and the dashboard.
#
# Every Mac writes <pool>/macs/<Mac>.txt on each command and in the background, so each Mac can see
# the others even while they sleep. Work in flight always comes fresh from the git remote.
#   key=value lines; lists use tabs:
#   project=<name>\t<branch>\t<dirty>\t<ahead>\t<parked yes|no>     or  <name>\tmissing
#   local=<name>\t<path>          an ignored local file (name only — never contents)
#   issue=<level>\t<area>\t<text>  unmet prerequisite

TAB=$(printf '\t')

val() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
mac_files() { ls "$MACS_DIR"/*.txt 2>/dev/null; }
short_name() { printf '%s' "$1" | sed -E "s/^.*[’']s //; s/ (von|de|of) .*$//"; }
mac_label() { local n; n=$(val name "$MACS_DIR/$1.txt"); short_name "${n:-$1}"; }
short_path() { printf '%s' "$1" | sed "s#^$HOME#~#; s#^~/Library/Mobile Documents/com~apple~CloudDocs#iCloud Drive#; s#^~/Library/CloudStorage/##"; }

project_state() {  # $1 path → branch, dirty, ahead, parked (tab separated) or "missing"
  local p=$1 branch dirty ahead parked=no
  [ -d "$p/.git" ] || { echo missing; return; }
  branch=$(git -C "$p" symbolic-ref --short -q HEAD || echo "(detached)")
  dirty=$(git -C "$p" status --porcelain --untracked-files=normal 2>/dev/null | wc -l | tr -d ' ')
  ahead=$(git -C "$p" rev-list --count "@{u}..HEAD" 2>/dev/null || echo "?")
  git -C "$p" rev-parse -q --verify "refs/remotes/roam/$MAC" >/dev/null && parked=yes
  printf '%s\t%s\t%s\t%s\n' "$branch" "$dirty" "$ahead" "$parked"
}

registry_write() {
  local target="$MACS_DIR/$MAC.txt" tmp name dir remote extra f
  mkdir -p "$MACS_DIR" || return
  tmp="$MACS_DIR/.$MAC.$$.tmp"
  {
    echo "mac=$MAC"
    echo "name=$(scutil --get ComputerName 2>/dev/null || echo "$MAC")"
    echo "model=$(sysctl -n hw.model 2>/dev/null), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "macos=$(sw_vers -productVersion)"
    echo "xcode=$(xcode_version)"
    echo "version=$ROAM_VERSION"
    echo "seen=$(date +%s)"
    if [ -f "$DOCTOR_FILE" ]; then
      echo "doctor=$(stat -f %m "$DOCTOR_FILE") $(grep -c '^missing' "$DOCTOR_FILE") $(grep -c '^hint' "$DOCTOR_FILE")"
      awk -F"$US" -v OFS="$TAB" '$1 != "ok" {print "issue=" $1, $2, $3}' "$DOCTOR_FILE"
    fi
    while read -r name dir remote extra; do
      [ -n "$name" ] || continue
      printf 'project=%s\t%s\n' "$name" "$(project_state "$PROJECTS_DIR/$dir")"
      [ -d "$PROJECTS_DIR/$dir/.git" ] && local_files "$PROJECTS_DIR/$dir" | while IFS= read -r f; do printf 'local=%s\t%s\n' "$name" "$f"; done
    done <<EOF
$(projects)
EOF
  } > "$tmp" && mv "$tmp" "$target"
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
  local mode=$1 name=$2 path="$PROJECTS_DIR/$3" remote=$4 elsewhere
  if [ ! -d "$path/.git" ]; then
    [ "$mode" = resume ] || return 0
    elsewhere=$(cloned_elsewhere "$remote" "$3")
    if [ -n "$elsewhere" ]; then report err "$name" "already cloned as $(short_path "$elsewhere") — roam setup offers to rename it"; return; fi
    mkdir -p "$PROJECTS_DIR" && git clone -q "$remote" "$path" 2>/dev/null || { report err "$name" "clone failed"; return; }
    report ok "$name" "cloned into $(short_path "$path")"
  fi
  cd "$path" || return
  if ! fetch_all; then
    if [ "$mode" = auto ]; then log "$name: remote unreachable"; return; fi   # being offline on the road is normal
    report err "$name" "remote unreachable"
  fi
  case $mode in
    park|auto) park_project "$name"; [ "$CLAUDE_SYNC" = 1 ] && claude_sync "$name" "$path" up ;;
    resume)    resume_project "$name"; [ "$CLAUDE_SYNC" = 1 ] && claude_sync "$name" "$path" down ;;
  esac
  return 0
}

render_report() {  # $1 report file
  local level name msg icon
  while IFS="$TAB" read -r level name msg; do
    case $level in ok) icon=$I_OK ;; err) icon=$I_ERR ;; *) icon="${C_MUTED}·${C_RESET}" ;; esac
    if [ "$level" = info ]; then msg="${C_MUTED}$msg${C_RESET}"; fi
    printf '  %s %s %s\n' "$icon" "$(pad "${C_BOLD}$name${C_RESET}" 13)" "$msg"
  done < "$1"
}

run_all() {  # $1 park|resume|auto → sets ERRORS
  local mode=$1 name dir remote extra out verb
  ERRORS=0
  case $mode in park) verb="parking" ;; resume) verb="resuming" ;; *) verb="syncing" ;; esac
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
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
  local f m macs="" now seen dot status doc missing hints n col name dir remote extra state sha time from br line
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
    elif [ $((now - ${seen:-0})) -lt $(( INTERVAL * 60 + 300 )) ]; then dot="${C_OK}●${C_RESET}"; status="online"
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
  col=$(( ($(ui_width) - 6 - 14) / n )); [ $col -gt 26 ] && col=26
  box_top "Projects"
  line="$(pad "" 14)"
  for m in $macs; do line="$line$(pad "${C_MUTED}$(trunc "$(mac_label "$m")" $((col - 2)))${C_RESET}" $col)"; done
  box_line "$line"
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    line="$(pad "${C_BOLD}$(trunc "$name" 13)${C_RESET}" 14)"
    for m in $macs; do
      if [ "$m" = "$MAC" ]; then state=$(project_state "$PROJECTS_DIR/$dir")
      else state=$(sed -n "s/^project=$name$TAB//p" "$MACS_DIR/$m.txt"); fi
      line="$line$(pad "$(cell "$state")" $col)"
    done
    box_line "$line"
  done <<EOF
$(projects)
EOF
  [ -n "$(projects)" ] || box_line "${C_MUTED}no projects yet — add one: roam add <git remote>${C_RESET}"
  box_line "${C_LINE}✓ clean · ●n uncommitted · ↑n unpushed · ☁ parked · — not cloned${C_RESET}"
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
  return 0
}

# ---------------------------------------------------------------- interactive
ACTIONS="Resume Park Doctor Fix Add Log Quit"
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
  local sel=0 k act quick="" r
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
        LEFT|h)  sel=$(( (sel + 6) % 7 )); action_bar $sel; continue ;;
        RIGHT|l) sel=$(( (sel + 1) % 7 )); action_bar $sel; continue ;;
        ENTER)   act=$(echo $ACTIONS | cut -d' ' -f$((sel + 1))) ;;
        r|R) act=Resume ;; p|P) act=Park ;; d|D) act=Doctor ;; f|F) act=Fix ;;
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
      Add)    r=$(ask "Git remote of the project (e.g. git@github.com:you/app.git)" "")
              [ -n "$r" ] && add_project "$r" ""; pause ;;
      Log)    echo; tail -n 25 "$LOG" 2>/dev/null | sed 's/^/  /' || say_info "no log yet"; pause; quick=quick ;;
      Quit)   echo; return 0 ;;
    esac
  done
}
