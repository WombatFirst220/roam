# roam — secrets: ignored files a project can't run without travel encrypted through the pool.
#
# What travels: ignored .env* files (not .example/.sample/.template) and the local=… files of
# projects.conf, each at most 1 MB. Only with carry_secrets = 1 in the pool settings, and only with age.
# Each Mac has its own key (~/.config/roam/age.key, it never leaves the Mac) and publishes the public
# half as age= in its status file. Every Mac packs its copy for all the keys it knows into
# secrets/<project>/<Mac>.age — one writer per file, so the sync app never has two versions to reconcile.
# Taking over decides per file with the hash both Macs last shared (.git/roam-secrets-seen), like
# ancestry for snapshots: changed only there → replaced here; changed on both → yours stays, theirs
# lands next to it as <file>.from-<Mac>.

AGE_KEY="$HOME/.config/roam/age.key"

age_pub() { [ -f "$AGE_KEY" ] && have age-keygen && age-keygen -y "$AGE_KEY" 2>/dev/null; }
age_ensure_key() {
  [ -f "$AGE_KEY" ] && return 0
  have age-keygen || return 1
  mkdir -p "$(dirname "$AGE_KEY")" && ( umask 077; age-keygen -o "$AGE_KEY" >/dev/null 2>&1 )
}
age_recipients() {  # every key the Macs in the pool published, and this Mac's own
  { age_pub; for f in $(mac_files); do val age "$f"; done; } | grep '^age1' | sort -u
}
sha_of() { shasum -a 256 < "$1" | cut -c1-64; }

secret_files() {  # $1 project name; cwd is the project → relative paths that travel
  local extra
  extra=$(projects | awk -v n="$1" '$1 == n { for (i = 4; i <= NF; i++) print $i }' | sed -n 's/^local=//p' | tr ',' '\n')
  { find . \( -name node_modules -o -name .git -o -name .build -o -name build -o -name DerivedData -o -name .next \
              -o -name Pods -o -name .venv \) -prune -o -type f -name '.env*' -print | sed 's#^\./##'
    printf '%s\n' "$extra"
  } | grep -v -E '\.from-[^/]*$|\.(example|sample|template)$' | grep . | sort -u |
  while IFS= read -r f; do
    [ -f "$f" ] && [ "$(stat -f %z "$f")" -le 1048576 ] && git check-ignore -q -- "$f" && echo "$f"
  done
}

seen_get() { awk -F'\t' -v p="$2" '$2 == p { print $1; exit }' "$1" 2>/dev/null; }
seen_set() {  # $1 seen file, $2 path, $3 hash
  { awk -F'\t' -v p="$2" '$2 != p' "$1" 2>/dev/null; printf '%s\t%s\n' "$3" "$2"; } > "$1.tmp" && mv "$1.tmp" "$1"
}

secrets_sync() {  # $1 name, $2 up|down; cwd is the project
  age_ensure_key   # every Mac needs a key, even without secrets of its own: or nothing can be encrypted for it
  if [ "$2" = up ]; then secrets_up "$1"; else secrets_down "$1"; fi
}

secrets_up() {  # $1 name
  local name=$1 g files dir out rec stamp f
  g=$(git rev-parse --git-dir)
  files=$(secret_files "$name")
  dir="$POOL/secrets/$name" out="$POOL/secrets/$name/$MAC.age"
  if [ -z "$files" ]; then rm -f "$out" "$g/roam-secrets-stamp"; return 0; fi
  age_ensure_key || { report err "$name" "carry_secrets is on, but age is missing — brew install age"; return; }
  rec=$(mktemp); age_recipients > "$rec"
  # unchanged files for unchanged keys: leave the bundle alone (every rewrite lands in other Macs' Trash)
  stamp=$( { cat "$rec"; printf '%s\n' "$files" | while IFS= read -r f; do printf '%s %s\n' "$(sha_of "$f")" "$f"; done; } | shasum -a 256 | cut -c1-64)
  if [ -f "$out" ] && [ "$(cat "$g/roam-secrets-stamp" 2>/dev/null)" = "$stamp" ]; then rm -f "$rec"; return 0; fi
  mkdir -p "$dir" || { rm -f "$rec"; return 1; }
  if printf '%s\n' "$files" | tar -cf - -T - 2>/dev/null | age -e -R "$rec" -o "$out.tmp" 2>/dev/null; then
    mv "$out.tmp" "$out"
    printf '%s\n' "$stamp" > "$g/roam-secrets-stamp"
    # what's shared now is the common state: a later change on another Mac may replace it here
    printf '%s\n' "$files" | while IFS= read -r f; do seen_set "$g/roam-secrets-seen" "$f" "$(sha_of "$f")"; done
    log "$name: secrets packed for $(grep -c . "$rec") Mac key(s): $(printf '%s\n' "$files" | tr '\n' ' ')"
  else
    rm -f "$out.tmp"; report err "$name" "couldn't encrypt the secrets for the pool"
  fi
  rm -f "$rec"
}

secrets_down() {  # $1 name — takes over the newest bundle of another Mac
  local name=$1 g b from tmp f t l s new="" conflicts="" res
  g=$(git rev-parse --git-dir)
  b=$(ls -t "$POOL/secrets/$name"/*.age 2>/dev/null | grep -v -F "/$MAC.age" | head -1)
  [ -n "$b" ] || return 0
  from=$(basename "$b" .age)
  have age || { report err "$name" "$(mac_label "$from") carries secrets for this project — brew install age"; return; }
  tmp=$(mktemp -d); res=$(mktemp)
  if ! { [ -f "$AGE_KEY" ] && age -d -i "$AGE_KEY" "$b" 2>/dev/null | tar -xf - -C "$tmp" 2>/dev/null; }; then
    age_ensure_key
    report info "$name" "$(mac_label "$from")'s secrets aren't encrypted for this Mac yet — they will be after its next park"
    rm -rf "$tmp" "$res"; return
  fi
  ( cd "$tmp" && find . -type f ) | while IFS= read -r f; do
    f=${f#./}
    case "/$f/" in */../*) continue ;; esac                           # never outside the project
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue    # never over a tracked file
    t=$(sha_of "$tmp/$f"); s=$(seen_get "$g/roam-secrets-seen" "$f")
    if [ ! -f "$f" ]; then
      mkdir -p "$(dirname "$f")" && cp -p "$tmp/$f" "$f" && seen_set "$g/roam-secrets-seen" "$f" "$t" && echo "new $f"
    else
      l=$(sha_of "$f")
      if [ "$l" = "$t" ]; then seen_set "$g/roam-secrets-seen" "$f" "$t"
      elif [ "$l" = "$s" ]; then cp -p "$tmp/$f" "$f" && seen_set "$g/roam-secrets-seen" "$f" "$t" && echo "new $f"
      elif [ "$t" = "$s" ]; then :                                       # only changed here: the next park shares it
      else cp -p "$tmp/$f" "$f.from-$from" && echo "conflict $f"; fi
    fi
  done > "$res"
  new=$(sed -n 's/^new //p' "$res" | head -3 | tr '\n' ' ')
  conflicts=$(sed -n 's/^conflict //p' "$res" | head -3 | tr '\n' ' ')
  [ -n "$new" ] && report ok "$name" "secrets from $(mac_label "$from"): ${new% }"
  [ -n "$conflicts" ] && report err "$name" "changed here and on $(mac_label "$from"): ${conflicts% } — yours stays, theirs is next to it as …from-$from"
  rm -rf "$tmp" "$res"
}
