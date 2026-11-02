# roam — the project browser: your GitHub repos, the folders in your projects folder and the pool in one
# list. Add what isn't in roam yet, take out what shouldn't be, rename what GitHub renamed.
#   roam projects        the list on the command line     b in the app: the same list, with keys
#   roam remove [project]  out of roam — the folder and the repo stay where they are, on every Mac
#
# One row per repository (tab separated):
#   kind  name  address  folder here  last push  private|public|archived  pool name  new address  description
#   kind: moved (in roam, renamed on GitHub) · gone (in roam, GitHub doesn't know it any more) · roam (in roam)
#         · new (not in roam: a folder here, a repo on GitHub, or both) · archived (on GitHub, archived)

repo_lookup() {  # $1 remote → GitHub's owner/name for it now, "!gone" if GitHub doesn't know it, nothing if it can't tell
  local n out
  n=$(remote_norm "$1")
  case $n in github.com/*/*) n=${n#github.com/} ;; *) return 0 ;; esac
  if out=$(gh api "repos/$n" --jq .full_name 2>&1); then printf '%s\n' "$out"
  else case $out in *"Not Found"*|*"HTTP 404"*) echo "!gone" ;; esac; fi
  return 0
}

browse_rows() {  # → the rows described above, the ones that need you first, then newest first
  local tmp name dir remote extra n d r i=0 full
  tmp=$(mktemp -d)
  : > "$tmp/gh"; : > "$tmp/local"; : > "$tmp/pool"
  if have gh && gh auth status >/dev/null 2>&1; then
    gh repo list --limit 300 --json name,sshUrl,pushedAt,isArchived,isPrivate,description --jq '.[] |
      [.sshUrl, .name, .pushedAt[0:10], (if .isArchived then "archived" elif .isPrivate then "private" else "public" end),
       ((.description // "") | gsub("[\t\n\r]"; " "))] | @tsv' 2>/dev/null |
      while IFS="$TAB" read -r r name d v desc; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(remote_norm "$r")" "$r" "$name" "$d" "$v" "$desc"; done > "$tmp/gh"
    : > "$tmp/gh.ok"
  fi
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}; [ -d "$d" ] || continue
    if [ -d "$d/.git" ]; then
      r=$(git -C "$d" remote get-url origin 2>/dev/null)
      printf '%s\t%s\t%s\t%s\t%s\n' "${r:+$(remote_norm "$r")}" "$(basename "$d")" "$d" "$(git -C "$d" log -1 --format=%cs 2>/dev/null)" "${r:+$(ssh_remote "$r")}"
    else printf '\t%s\t%s\t\t\n' "$(basename "$d")" "$d"; fi
  done > "$tmp/local"
  # pool entries GitHub's list doesn't have: renamed, gone — or just someone else's repo (asked in parallel)
  while read -r name dir remote extra; do
    [ -n "$name" ] || continue
    n=$(remote_norm "$remote")
    printf '%s\t%s\t%s\t%s\n' "$n" "$name" "$dir" "$(ssh_remote "$remote")" >> "$tmp/pool"
    [ -f "$tmp/gh.ok" ] || continue
    case $n in github.com/*/*) ;; *) continue ;; esac
    grep -q "^$n$TAB" "$tmp/gh" && continue
    ( full=$(repo_lookup "$remote")
      if [ "$full" = "!gone" ]; then printf '%s\tgone\t\n' "$name"
      elif [ -n "$full" ] && [ "$(printf '%s' "$full" | tr 'A-Z' 'a-z')" != "${n#github.com/}" ]; then
        printf '%s\tmoved\tgit@github.com:%s.git\n' "$name" "$full"; fi > "$tmp/m.$i" ) &
    i=$((i + 1))
  done <<EOF
$(projects)
EOF
  wait
  cat "$tmp"/m.* 2>/dev/null | while IFS="$TAB" read -r name k r; do printf '%s\t%s\t%s\t%s\n' "$name" "$k" "$r" "$(remote_norm "$r")"; done > "$tmp/moved"
  awk -F'\t' -v OFS='\t' '
    FILENAME ~ /\/gh$/    { g_ssh[$1] = $2; g_name[$1] = $3; g_date[$1] = $4; g_vis[$1] = $5; g_desc[$1] = $6; g_order[++ng] = $1; next }
    FILENAME ~ /\/local$/ { nl++; l_key[nl] = $1; l_dir[nl] = $2; l_path[nl] = $3; l_date[nl] = $4; l_url[nl] = $5
                            if ($1 != "") l_by_norm[$1] = nl; l_by_dir[$2] = nl; next }
    FILENAME ~ /\/moved$/ { m_kind[$1] = $2; m_ssh[$1] = $3; m_norm[$1] = $4; next }
    FILENAME ~ /\/pool$/  { np++; p_norm[np] = $1; p_name[np] = $2; p_dir[np] = $3; p_ssh[np] = $4; next }
    function d(x) { return x == "" ? "-" : x }
    function row(kind, name, ssh, path, date, vis, pname, newssh, desc,   o) {
      o = (kind == "moved" ? 0 : kind == "gone" ? 1 : kind == "roam" ? 2 : kind == "new" ? 3 : 4)
      # "-" for an empty field: read with IFS=tab would run two tabs together
      print o, (date == "" ? "0000-00-00" : date), kind, name, d(ssh), d(path), d(date), d(vis), d(pname), d(newssh), d(desc)
    }
    END {
      for (i = 1; i <= np; i++) {
        n = p_norm[i]; kind = "roam"; t = n; newssh = ""
        if (p_name[i] in m_kind) { kind = m_kind[p_name[i]]; if (kind == "moved") { t = m_norm[p_name[i]]; newssh = m_ssh[p_name[i]] } }
        li = (p_dir[i] in l_by_dir) ? l_by_dir[p_dir[i]] : (t in l_by_norm) ? l_by_norm[t] : (n in l_by_norm) ? l_by_norm[n] : 0
        path = li ? l_path[li] : ""; if (li) l_used[li] = 1
        date = (t in g_date) ? g_date[t] : (li ? l_date[li] : "")
        if (t in g_ssh) g_used[t] = 1; if (n in g_ssh) g_used[n] = 1
        if (li && l_key[li] != "") { if (l_key[li] in g_ssh) g_used[l_key[li]] = 1 }
        row(kind, p_name[i], p_ssh[i], path, date, g_vis[t], p_name[i], newssh, g_desc[t])
      }
      for (i = 1; i <= nl; i++) {
        if (i in l_used) continue
        k = l_key[i]; if (k in g_ssh) { if (k in g_used) continue; g_used[k] = 1 }
        row((g_vis[k] == "archived" ? "archived" : "new"), l_dir[i], (k in g_ssh) ? g_ssh[k] : l_url[i], l_path[i],
            (k in g_date) ? g_date[k] : l_date[i], g_vis[k], "", "", g_desc[k])
      }
      for (j = 1; j <= ng; j++) {
        k = g_order[j]; if (k in g_used) continue
        row((g_vis[k] == "archived" ? "archived" : "new"), g_name[k], g_ssh[k], "", g_date[k], g_vis[k], "", "", g_desc[k])
      }
    }' "$tmp/gh" "$tmp/local" "$tmp/moved" "$tmp/pool" | sort -t "$TAB" -k1,1n -k2,2r | cut -f3-
  rm -rf "$tmp"
}

browse_undash() {  # the fields of a row just read: "-" back to empty
  [ "$ssh" = - ] && ssh=""; [ "$path" = - ] && path=""; [ "$date" = - ] && date=""; [ "$vis" = - ] && vis=""
  [ "$pname" = - ] && pname=""; [ "$newssh" = - ] && newssh=""; [ "$desc" = - ] && desc=""; return 0
}

browse_mark() {  # $1 kind → REPLY: its mark (plain)
  case $1 in moved) REPLY="↪" ;; gone) REPLY="✗" ;; roam) REPLY="●" ;; new) REPLY="○" ;; *) REPLY="·" ;; esac
}

projects_cmd() {  # the browser's list, plain
  local kind name ssh path date vis pname newssh desc where n=0
  header "projects" "$(short_path "$PROJECTS_DIR")"; echo
  have gh && gh auth status >/dev/null 2>&1 || say_info "GitHub CLI not signed in (gh auth login) — only folders here and the pool"
  while IFS="$TAB" read -r kind name ssh path date vis pname newssh desc; do
    [ -n "$kind" ] || continue
    browse_undash
    n=$((n + 1)); browse_mark "$kind"
    where=""
    [ -n "$path" ] && where="$(short_path "$path")"
    case $kind in
      moved) where="renamed on GitHub to $(repo_label "$newssh")${path:+, here $(short_path "$path")} — roam rename $name" ;;
      gone) where="GitHub doesn't know $(remote_norm "$ssh") any more — roam remove $name" ;;
      roam) where="${where:-not on this Mac}" ;;
      new) if [ -n "$ssh" ]; then where="${where:+$where · }$(remote_norm "$ssh")"; else where="${where:+$where · }no git repo yet"; fi ;;
      archived) where="archived" ;;
    esac
    printf '  %s %s %s%s%s\n' "$REPLY" "$(pad "${C_BOLD}$name${C_RESET}" 24)" "$C_MUTED" "$where${date:+ · $date}" "$C_RESET"
  done <<EOF
$(browse_rows)
EOF
  [ $n -gt 0 ] || say_info "nothing here yet"
  echo; say_info "● in roam · ○ not yet: roam add · ↪ renamed on GitHub · ✗ gone · b in the app adds and removes with one key"
}

remove_cmd() {  # [project] — out of roam on every Mac; folders and the repo stay
  local name dir remote extra line f open=""
  pick_project "${1:-}" "Take which project out of roam?" || return 1
  line=$(projects | awk -v n="$P_NAME" '$1 == n')
  read -r name dir remote extra <<EOF
$line
EOF
  # work parked on the remote would stay there unseen: say so
  if [ -d "$P_PATH/.git" ]; then
    open=$(git -C "$P_PATH" for-each-ref --format='%(refname:lstrip=3)' refs/remotes/roam/ 2>/dev/null | while read -r f; do printf '%s ' "$(mac_label "$f")"; done)
    [ -n "$open" ] && say_warn "work parked on the remote from: ${open}— resume it somewhere first, or it stays there unseen"
  fi
  if [ -t 0 ]; then
    confirm "Take $name out of roam? Its folder stays on every Mac, the repo on GitHub too" n || return 1
  fi
  lock
  pool_remove_line "$name"
  for f in "$POOL/sessions"/*/"$name.txt"; do [ -f "$f" ] && rm -f "$f"; done
  registry_write
  say_ok "${C_BOLD}$name${C_RESET} is out of roam ${C_MUTED}— $(short_path "$P_PATH") stays; roam add brings it back, its Claude memory too${C_RESET}"
}

pool_remove_line() {  # $1 project name
  local tmp; tmp=$(mktemp)
  awk -v n="$1" '/^[[:space:]]*(#|$)/ || $1 != n' "$PROJECTS_CONF" > "$tmp" && pool_put "$tmp" "$PROJECTS_CONF"
}

browse_add() {  # $1 address (may be empty), $2 folder here (may be empty), $3 suggested name — in roam
  local name
  if [ -n "$2" ]; then add_folder "$2"; return; fi
  name=$3
  [ -t 0 ] && name=$(ask "Name (also the folder on every Mac)" "$3")
  add_project "$1" "$name" || return 1
  say_info "this Mac gets it with roam resume (r in the app), like the others"
}
