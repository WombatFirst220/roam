# roam — start a project: `roam new [name|folder]`.
# Creates (or adopts) a folder, writes a fitting .gitignore and README, creates the GitHub repo,
# pushes, and adds it to the pool — every other Mac gets it with its next `roam resume`.

gitignore_for() {  # $1 kind: xcode | swiftpm | node | other
  printf '# macOS\n.DS_Store\n._*\n\n'
  case $1 in
    xcode)
      printf '# Xcode\nxcuserdata/\n*.xcuserstate\n*.xcuserdatad\nDerivedData/\nbuild/\n*.ipa\n*.dSYM\n*.dSYM.zip\n*.hmap\n\n'
      printf '# Swift Package Manager\n.build/\n.swiftpm/\nPackages/\n\n'
      printf '# local configuration (keep a Local.xcconfig.example in git instead)\nLocal.xcconfig\n\n' ;;
    swiftpm)
      printf '# Swift Package Manager\n.build/\n.swiftpm/\nPackages/\nxcuserdata/\nDerivedData/\n\n' ;;
    node)
      printf '# Node\nnode_modules/\ndist/\nbuild/\n.next/\ncoverage/\n*.log\n\n' ;;
  esac
  printf '# secrets — never in git\n.env\n.env.*\n!.env.example\n*.pem\n*.p8\n*.p12\n*.key\n\n'
  printf '# Claude Code — personal overrides stay local\n.claude/settings.local.json\n'
}

kind_label() {  # $1 kind → words (a function: bash 3.2 mis-parses case inside $( ))
  case $1 in
    xcode) echo "an Xcode project" ;;
    swiftpm) echo "a Swift package" ;;
    node) echo "a Node project" ;;
    *) echo "a project" ;;
  esac
}

detect_kind() {  # $1 folder → xcode | swiftpm | node | other
  if [ -n "$(find "$1" -maxdepth 3 -name '*.xcodeproj' 2>/dev/null | head -1)" ]; then echo xcode
  elif [ -f "$1/Package.swift" ]; then echo swiftpm
  elif [ -f "$1/package.json" ]; then echo node
  else echo other; fi
}

new_project() {  # $1 optional: name, or path of an existing folder
  local arg=${1:-} dir name kind kind_n vis login gid remote adopt=0 msg
  [ -t 0 ] || { echo "roam new needs a terminal — it asks a few questions."; return 1; }
  header "new" "$(short_name "$(scutil --get ComputerName)")"
  printf '\n  %sStart a project — on every Mac in one go.%s\n' "$C_BOLD" "$C_RESET"

  if ! have gh || ! gh auth status >/dev/null 2>&1; then
    say_err "roam new creates the repo with the GitHub CLI."
    say_info "Install it: brew install gh — then sign in: gh auth login"
    say_info "Other git hosts: create the repo there, then  roam add <git remote>"
    return 1
  fi
  login=$(gh api user --jq '.login + " " + (.id|tostring)' 2>/dev/null)
  gid=${login#* }; login=${login%% *}

  # ------------------------------------------------------------ which folder?
  if [ -z "$arg" ] && [ "$(dirname "$PWD")" = "$PROJECTS_DIR" ] && [ ! -d "$PWD/.git/refs/remotes/origin" ]; then
    confirm "Publish this folder, $(basename "$PWD")?" y && arg=$PWD
  fi
  if [ -n "$arg" ] && [ -d "$arg" ]; then
    dir=$(cd "$arg" && pwd -P); adopt=1
  else
    name=${arg:-$(ask "Project name" "")}
    [ -n "$name" ] || return 1
    case $name in */*) [ -d "$name" ] && { dir=$(cd "$name" && pwd -P); adopt=1; } ;; esac
    [ $adopt = 1 ] || dir="$PROJECTS_DIR/$name"
    [ -d "$dir" ] && adopt=1
  fi
  name=$(basename "$dir")
  case $name in *[!A-Za-z0-9._-]*) say_err "use letters, digits, . _ - for the name"; return 1 ;; esac
  if projects | awk '{print $1}' | grep -q -x "$name"; then say_err "$name is already in the pool"; return 1; fi
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    say_info "$name already has a remote — adding it to the pool instead."
    add_project "$(git -C "$dir" remote get-url origin)" "$name"
    return
  fi
  if [ "$(dirname "$dir")" != "$PROJECTS_DIR" ]; then
    say_warn "$(short_path "$dir") is outside $(short_path "$PROJECTS_DIR") — other Macs will put it at $(short_path "$PROJECTS_DIR/$name")."
    confirm "Continue anyway?" n || return 1
  fi
  if gh repo view "$login/$name" >/dev/null 2>&1; then
    say_err "github.com/$login/$name exists already — clone it with: roam add git@github.com:$login/$name.git"; return 1
  fi

  # ------------------------------------------------------------ what kind?
  echo
  if [ $adopt = 1 ]; then kind=$(detect_kind "$dir"); else kind=""; fi
  if [ -z "$kind" ] || [ "$kind" = other ]; then
    say_info "What are you building?"
    kind_n=$(printf '%s\n' "iOS / macOS app (Xcode)" "Swift package" "Web / Node" "Something else" | choose)
    kind=$(echo "xcode swiftpm node other" | cut -d' ' -f"$kind_n")
  else
    say_ok "looks like $(kind_label "$kind")"
  fi

  say_info "Who can see it on GitHub?"
  vis=$(printf '%s\n' "Private — only you" "Public — everyone" | choose)
  [ "$vis" = 2 ] && vis=public || vis=private   # only an explicit choice makes it public

  # ------------------------------------------------------------ build it
  echo
  mkdir -p "$dir" || return 1
  cd "$dir" || return 1
  if [ ! -d .git ]; then git init -q -b main && say_ok "git repository"; fi
  if [ "$vis" = public ] && [ -n "$login" ]; then
    say_info "Public repos show the commit author. Your git identity here: $(git config user.name) <$(git config user.email)>"
    if confirm "Commit as $login (GitHub's private noreply address) instead?" y; then
      git config user.name "$login"
      git config user.email "$gid+$login@users.noreply.github.com"
      say_ok "commits in this repo: $login"
    fi
  fi
  [ -f .gitignore ] || { gitignore_for "$kind" > .gitignore; say_ok ".gitignore for $(echo "$kind" | sed 's/xcode/Xcode/; s/swiftpm/Swift packages/; s/node/Node/; s/other/general use/')"; }
  [ -f README.md ] || { printf '# %s\n' "$name" > README.md; say_ok "README.md"; }

  # nothing secret may slip into the first commit
  if [ -n "$(git ls-files --others --exclude-standard | grep -E "$SECRET_PATTERN")" ]; then
    say_err "secret-looking files would be committed: $(git ls-files --others --exclude-standard | grep -E "$SECRET_PATTERN" | head -3 | tr '\n' ' ')"
    say_info "add them to .gitignore and run roam new again"
    return 1
  fi
  # the exported fallback identity is meant for snapshots only — here the repo's own identity counts
  [ -n "$(git config user.name)" ] && unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  git add -A
  if git rev-parse -q --verify HEAD >/dev/null; then msg=""; else msg="Start $name"; fi
  [ -n "$msg" ] && git commit -q -m "$msg" && say_ok "first commit"

  remote=$(printf "${ROAM_NEW_REMOTE:-git@github.com:%s/%s.git}" "$login" "$name")
  ( gh repo create "$login/$name" "--$vis" >/dev/null 2>&1 ) & spin_while $! "${C_MUTED}creating github.com/$login/${name}…${C_RESET}"
  gh repo view "$login/$name" >/dev/null 2>&1 || { say_err "couldn't create the repo on GitHub"; return 1; }
  say_ok "github.com/$login/$name ${C_MUTED}($vis)${C_RESET}"
  git remote add origin "$remote" 2>/dev/null || git remote set-url origin "$remote"
  git push -q -u origin main 2>/dev/null || { say_err "push failed — check SSH access (roam setup)"; return 1; }
  say_ok "pushed"

  printf '%-12s %-12s %s\n' "$name" "$name" "$(ssh_remote "$remote")" >> "$PROJECTS_CONF"
  registry_write
  say_ok "in the pool — your other Macs get it with ${C_ACCENT}roam resume${C_RESET}"

  if [ "$kind" = xcode ] && [ -z "$(find "$dir" -maxdepth 3 -name '*.xcodeproj' 2>/dev/null | head -1)" ]; then
    echo
    say_info "Next: in Xcode › File › New › Project…, save it into $(short_path "$dir")"
    say_info "and untick “Create Git repository” — the folder already is one."
    confirm "Open Xcode now?" y && open -a Xcode
  fi
  echo
  printf '  %s %s%s is ready.%s %s%s%s\n' "$I_OK" "$C_BOLD" "$name" "$C_RESET" "$C_MUTED" "$(short_path "$dir")" "$C_RESET"
}

# ---------------------------------------------------------------- what goes into the repo
# Whatever in a project isn't committed is either new — it goes into the repo with the next commit — or
# stays out: a rule in a .gitignore, in .git/info/exclude or in your global ignore file says so. roam
# switches a file or folder between the two by editing the project's .gitignore, and nothing else.
repo_outside() {  # $1 project path → "state<TAB>path<TAB>rule file<TAB>line<TAB>pattern" per line
  # state: new (goes in with the next commit), junk (macOS or sync-app file — roam skips it, git doesn't),
  # out (stays out). Folders end in /. New first, then junk, then out; each sorted by path.
  ( cd "$1" 2>/dev/null || exit 0
    # a folder holding nothing but .DS_Store isn't new work: junk is looked at file by file
    st=$(git status --porcelain -z --ignored --untracked-files=normal -- . "${JUNK[@]}" 2>/dev/null | tr '\0' '\n')
    printf '%s\n' "$st" | sed -n 's/^?? //p' | sort | while IFS= read -r f; do [ -n "$f" ] && printf 'new\t%s\t\t\t\n' "$f"; done
    git ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' | sort |
      while IFS= read -r f; do [ -n "$f" ] && is_junk "$f" && printf 'junk\t%s\t\t\t\n' "$f"; done
    printf '%s\n' "$st" | sed -n 's/^!! //p' | grep . | sort | tr '\n' '\0' |
      git check-ignore -v -z --no-index --stdin 2>/dev/null | tr '\0' '\n' |
      while IFS= read -r src && IFS= read -r line && IFS= read -r pat && IFS= read -r f; do
        printf 'out\t%s\t%s\t%s\t%s\n' "$f" "$src" "$line" "$pat"
      done
    exit 0 )
}

repo_rule() {  # $1 rule file, $2 pattern → REPLY: where the rule lives, in words
  case $1 in
    .gitignore|*/.gitignore) REPLY="$1: $2" ;;
    *info/exclude) REPLY="this repo's info/exclude: $2" ;;
    *) REPLY="your global ignore file: $2" ;;
  esac
}

gitignore_add() {  # $1 .gitignore, $2 line — on a line of its own, also when the file ends without a newline
  [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ] && echo >> "$1"
  printf '%s\n' "$2" >> "$1"
}

repo_toggle() {  # $1 project path, then one repo_outside line (state, path, rule file, line, pattern) → REPLY; 1: unchanged
  local p=$1 state=$2 f=$3 src=${4:-} line=${5:-} pat=${6:-} gi="$1/.gitignore" keep had=0 changed n rel
  REPLY=""
  keep=$(mktemp); [ -f "$gi" ] && { had=1; cp -p "$gi" "$keep"; }
  changed=$gi
  case $state in
    new|junk)
      if [ "$state" = junk ]; then
        # by name, anywhere: Finder leaves the next one in another folder tomorrow
        n=${f%/}; n=${n##*/}; case $n in $'Icon\r') n='Icon?' ;; esac
        gitignore_add "$gi" "$n"
      else
        # exactly this path, from the project's root; [ * ? \ taken literally, a leading # or ! too
        n=$(printf '%s' "$f" | sed 's/[][*?\\]/\\&/g; s/^[#!]/\\&/')
        gitignore_add "$gi" "/$n"
      fi
      if git -C "$p" check-ignore -q --no-index -- "$f"; then
        REPLY="${f%/} stays out of the repo — .gitignore changed, commit it"; rm -f "$keep"; return 0
      fi ;;
    out)
      rel=$f; case $src in */.gitignore) rel=${f#"${src%.gitignore}"} ;; esac
      n=${pat#/}; n=${n%/}
      if case $src in .gitignore|*/.gitignore) true ;; *) false ;; esac && [ "$n" = "${rel%/}" ] && [ -n "$line" ]; then
        # the rule names exactly this: take it out
        changed="$p/$src"; [ "$src" = .gitignore ] || cp -p "$changed" "$keep"
        sed -i '' "${line}d" "$changed"
      else
        # a broader rule (*.log, build/) or one outside the project: an exception for this path
        n=$(printf '%s' "$f" | sed 's/[][*?\\]/\\&/g')
        gitignore_add "$gi" "!/$n"
      fi
      if ! git -C "$p" check-ignore -q --no-index -- "$f"; then
        REPLY="${f%/} goes into the repo with your next commit — .gitignore changed, commit it"; rm -f "$keep"; return 0
      fi
      repo_rule "$src" "$pat"
      REPLY="git can't take ${f%/} in while a folder above it stays out ($REPLY) — nothing changed" ;;
  esac
  # didn't work: everything back as it was
  if [ "$changed" != "$gi" ] || [ $had = 1 ]; then cp -p "$keep" "$changed"; else rm -f "$gi"; fi
  rm -f "$keep"
  [ -n "$REPLY" ] || REPLY="${f%/}: nothing changed"
  return 1
}

ignore_cmd() {  # [project] [path] — what isn't in the repo; with a path: switch it between "goes in" and "stays out"
  local rows row state f src line pat
  pick_project "${1:-}" "Which project?" || return 1
  [ -d "$P_PATH/.git" ] || { say_err "$P_NAME isn't on this Mac"; return 1; }
  rows=$(repo_outside "$P_PATH")
  if [ -z "${2:-}" ]; then
    header "$P_NAME" "what isn't in the repo"; echo
    [ -n "$rows" ] || { say_ok "everything here is in the repo"; return 0; }
    printf '%s\n' "$rows" | while IFS="$TAB" read -r state f src line pat; do
      case $state in
        new)  printf '  %s+%s %s %s· goes in with the next commit%s\n' "$C_WARN" "$C_RESET" "$f" "$C_MUTED" "$C_RESET" ;;
        junk) printf '  %s+%s %s %s· macOS or sync-app file: roam skips it, git would take it%s\n' "$C_MUTED" "$C_RESET" "$(printf '%s' "$f" | tr '\r' '?')" "$C_MUTED" "$C_RESET" ;;
        out)  repo_rule "$src" "$pat"; printf '  %s−%s %s %s· stays out · %s%s\n' "$C_LINE" "$C_RESET" "$f" "$C_MUTED" "$REPLY" "$C_RESET" ;;
      esac
    done
    printf '\n  %sswitch one between "goes in" and "stays out": roam ignore %s <path>%s\n' "$C_MUTED" "$P_NAME" "$C_RESET"
    return 0
  fi
  row=$(printf '%s\n' "$rows" | awk -F'\t' -v f="${2%/}" '{ p = $2; sub(/\/$/, "", p) } p == f { print; exit }')
  [ -n "$row" ] || { say_err "${2%/} isn't outside the repo — committed files stay in (git rm --cached takes one out)"; return 1; }
  IFS="$TAB" read -r state f src line pat <<ROW
$row
ROW
  if repo_toggle "$P_PATH" "$state" "$f" "$src" "$line" "$pat"; then say_ok "$P_NAME: $REPLY"; else say_err "$P_NAME: $REPLY"; return 1; fi
}
