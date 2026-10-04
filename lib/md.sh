# roam — markdown reader: renderer (awk, ANSI) + scrolling pager (bash).
# Pure bash 3.2 + BSD awk. awk always runs with LC_ALL=C, so length()/substr() are byte-based on
# every macOS; display width is computed by hand (UTF-8 lead/continuation bytes, wide CJK/emoji).
# Input is untrusted (any repo's files, other Macs' session digests): control characters and escape
# sequences are removed before rendering. ROAM_MD=glow or ROAM_MD=mdcat hands off to those instead.

read -r -d '' _MD_AWK <<'AWK' || true
function sgr(x) { return COLOR ? ESC "[" x "m" : "" }
function rep(ch, n,   s) { s = ""; while (n-- > 0) s = s ch; return s }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# ---------------------------------------------------------------- width math (UTF-8 aware, ANSI aware)
function vlen(s,   t, n) {
  if (index(s, ESC) == 0 && s !~ HIGH) return length(s)
  t = s
  if (index(t, ESC)) { gsub(OSCRE, "", t); gsub(SGRRE, "", t) }
  if (t !~ HIGH) return length(t)
  gsub(VS16, "", t)
  n = length(t) - gsub(CONT, "", t)
  n += gsub(L4, "&", t) + gsub(LW3, "&", t)
  return n
}
function vtrunc(s, w,   out, i, j, c, o, cl, cw, n, len) {   # first w columns of s; rest in TRUNC_REST
  out = ""; n = 0; i = 1; len = length(s)
  while (i <= len) {
    c = substr(s, i, 1)
    if (c == ESC) {
      if (substr(s, i + 1, 1) == "[") { j = i + 2; while (j <= len && substr(s, j, 1) !~ /[A-Za-z]/) j++; out = out substr(s, i, j - i + 1); i = j + 1; continue }
      if (substr(s, i + 1, 1) == "]") { j = index(substr(s, i), ST); if (j) { out = out substr(s, i, j + 1); i += j + 1; continue } }
    }
    o = ORD[c]; cl = o < 192 ? 1 : o >= 240 ? 4 : o >= 224 ? 3 : 2
    cw = (o >= 240 || (o >= 227 && o <= 237)) ? 2 : 1
    if (substr(s, i, 3) == VS16) cw = 0
    if (n + cw > w) break
    out = out substr(s, i, cl); n += cw; i += cl
  }
  TRUNC_REST = substr(s, i)
  return out
}
function pad(s, w,   n) { n = vlen(s); return n < w ? s rep(" ", w - n) : s }
function fit(s, w) { return vlen(s) > w ? vtrunc(s, w - 1) "…" : s }

# ---------------------------------------------------------------- inline markdown → ANSI
function ph(x) { PH[++PHN] = x; return "\001" PHN "\002" }
function linkon(url, label) {
  if (OSC8) return ESC "]8;;" url ST cLINK
  return cLINK
}
function linkoff(url, base, txt,   r) {
  r = cLINKOFF base
  if (OSC8) return r ESC "]8;;" ST
  if (url !~ /^(https?|mailto|ftp):/ || url == txt) return r
  if (!(url in LINKNO)) { LINKNO[url] = ++NLINKS; LINKS[NLINKS] = url }
  return r cMUTED "[" LINKNO[url] "]" sgr(39) base
}
function emph(s, re, dl, on, off,   inner) {
  while (match(s, re)) {
    inner = substr(s, RSTART + dl, RLENGTH - 2 * dl)
    s = substr(s, 1, RSTART - 1) ph(on) inner ph(off) substr(s, RSTART + RLENGTH)
  }
  return s
}
function uemph(s, dl, on, off,   re, pre, post, inner, b, a) {  # _x_ / __x__ only at word boundaries
  re = dl == 2 ? "__[^_ ]([^_]*[^_ ])?__" : "_[^_ ]([^_]*[^_ ])?_"
  while (match(s, re)) {
    b = RSTART > 1 ? substr(s, RSTART - 1, 1) : " "; a = substr(s, RSTART + RLENGTH, 1)
    if (b ~ /[A-Za-z0-9]/ || a ~ /[A-Za-z0-9]/) { s = substr(s, 1, RSTART - 1) ph(rep("_", dl)) substr(s, RSTART + dl); continue }
    inner = substr(s, RSTART + dl, RLENGTH - 2 * dl)
    s = substr(s, 1, RSTART - 1) ph(on) inner ph(off) substr(s, RSTART + RLENGTH)
  }
  return s
}
function inl(s, base,   i, j, k, r, tk, body, txt, url, m, alt, id, rs, rl) {
  PHN = 0
  while (match(s, /\\[^A-Za-z0-9 ]/)) s = substr(s, 1, RSTART - 1) ph(substr(s, RSTART + 1, 1)) substr(s, RSTART + 2)
  # code spans (any number of backticks)
  while ((i = index(s, "`")) > 0) {
    k = i; while (substr(s, k, 1) == "`") k++
    tk = substr(s, i, k - i); r = substr(s, k); j = index(r, tk)
    if (!j) { s = substr(s, 1, i - 1) ph(tk) r; continue }
    body = substr(r, 1, j - 1); sub(/^ /, "", body); sub(/ $/, "", body)
    s = substr(s, 1, i - 1) ph(cICODE NBSP body NBSP cICODEOFF base) substr(r, j + length(tk))
  }
  # autolinks <https://…>
  while (match(s, /<(https?|mailto):[^ >]+>/)) {
    url = substr(s, RSTART + 1, RLENGTH - 2)
    s = substr(s, 1, RSTART - 1) ph(linkon(url)) ph(url) ph(linkoff(url, base, url)) substr(s, RSTART + RLENGTH)
  }
  # images ![alt](src) → ▣ alt
  while (match(s, /!\[[^]]*\]\([^)]*\)/)) {
    m = substr(s, RSTART, RLENGTH); alt = m; sub(/^!\[/, "", alt); sub(/\]\(.*$/, "", alt)
    s = substr(s, 1, RSTART - 1) ph(cMUTED "▣" (alt != "" ? " " : "")) alt ph(sgr(39) base) substr(s, RSTART + RLENGTH)
  }
  # links [text](url "title")
  while (match(s, /\[[^]]*\]\([^)]*\)/)) {
    m = substr(s, RSTART, RLENGTH); txt = m; sub(/^\[/, "", txt); sub(/\]\(.*$/, "", txt)
    url = m; sub(/^\[[^]]*\]\(/, "", url); sub(/\)$/, "", url); sub(/[ \t]+".*"$/, "", url); gsub(/^<|>$/, "", url)
    if (txt == "") txt = url
    s = substr(s, 1, RSTART - 1) ph(linkon(url)) txt ph(linkoff(url, base, txt)) substr(s, RSTART + RLENGTH)
  }
  # reference links [text][id] / [text][] / [id]
  while (match(s, /\[[^]]+\](\[[^]]*\])?/)) {
    m = substr(s, RSTART, RLENGTH); txt = m; sub(/^\[/, "", txt); sub(/\].*$/, "", txt)
    id = m; sub(/^\[[^]]*\]/, "", id); gsub(/^\[|\]$/, "", id); if (id == "") id = txt
    id = tolower(id)
    if (id in REF) s = substr(s, 1, RSTART - 1) ph(linkon(REF[id])) txt ph(linkoff(REF[id], base, txt)) substr(s, RSTART + RLENGTH)
    else s = substr(s, 1, RSTART - 1) ph("[") substr(m, 2) substr(s, RSTART + RLENGTH)
  }
  # inline HTML: <img alt> → ▣ alt, <a href>text</a> → link
  while (match(s, /<img[^>]*>/)) {
    rs = RSTART; rl = RLENGTH; m = substr(s, rs, rl); alt = ""
    if (match(m, /alt="[^"]*"/)) alt = substr(m, RSTART + 5, RLENGTH - 6)
    s = substr(s, 1, rs - 1) ph(cMUTED "▣" (alt != "" ? " " alt : "") sgr(39) base) substr(s, rs + rl)
  }
  while (match(s, /<a [^>]*href="[^"]*"[^>]*>/)) {
    rs = RSTART; rl = RLENGTH; m = substr(s, rs, rl); match(m, /href="[^"]*"/); url = substr(m, RSTART + 6, RLENGTH - 7)
    r = substr(s, rs + rl); j = index(r, "</a>"); if (!j) j = length(r) + 1
    s = substr(s, 1, rs - 1) ph(linkon(url)) substr(r, 1, j - 1) ph(linkoff(url, base, substr(r, 1, j - 1))) substr(r, j + 4)
  }
  # bare URLs
  while (match(s, /https?:\/\/[^ <>)"\001]+/)) {
    url = substr(s, RSTART, RLENGTH); sub(/[.,;:!?]+$/, "", url)
    s = substr(s, 1, RSTART - 1) ph(linkon(url)) ph(url) ph(linkoff(url, base, url)) substr(s, RSTART + length(url))
  }
  gsub(/<br *\/?>/, " \004 ", s)
  while (match(s, /<kbd>/)) s = substr(s, 1, RSTART - 1) ph(cKBD NBSP) substr(s, RSTART + 5)
  while (match(s, /<\/kbd>/)) s = substr(s, 1, RSTART - 1) ph(NBSP cKBDOFF base) substr(s, RSTART + 6)
  gsub(/<\/?[A-Za-z][^>]*>/, "", s)
  gsub(/&nbsp;/, " ", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s)
  gsub(/&#39;/, "\047", s); gsub(/&copy;/, "©", s); gsub(/&mdash;/, "—", s); gsub(/&amp;/, "\\&", s)
  # emphasis
  s = emph(s, "\\*\\*\\*[^* ]([^*]*[^* ])?\\*\\*\\*", 3, cB cI, cBOFF cIOFF base)
  s = emph(s, "\\*\\*[^* ]([^*]|\\*[^*])*\\*\\*", 2, cB, cBOFF base)
  s = uemph(s, 2, cB, cBOFF base)
  s = emph(s, "~~[^~]+~~", 2, cS, cSOFF base)
  s = emph(s, "\\*[^* ]([^*]*[^* ])?\\*", 1, cI, cIOFF base)
  s = uemph(s, 1, cI, cIOFF base)
  while (match(s, /\001[0-9]+\002/)) s = substr(s, 1, RSTART - 1) PH[substr(s, RSTART + 1, RLENGTH - 2) + 0] substr(s, RSTART + RLENGTH)
  return s
}

# ---------------------------------------------------------------- word wrap (keeps styles + links across lines)
function scanstate(w,   seq, p, n, i, a) {   # fold SGR codes into the active attribute set ST_
  if (index(w, ESC) == 0) return
  while (match(w, ANYESC)) {
    seq = substr(w, RSTART, RLENGTH); w = substr(w, RSTART + RLENGTH)
    if (substr(seq, 2, 1) != "[") { LK_ = substr(seq, 6, length(seq) - 7); continue }
    p = substr(seq, 3, length(seq) - 3); if (p == "") p = "0"
    n = split(p, a, ";")
    for (i = 1; i <= n; i++) {
      if (a[i] == 38 || a[i] == 48) { AT[a[i]] = a[i] ";" a[i + 1] ";" a[i + 2]; i += 2 }
      else if (a[i] == 0) { split("", AT) }
      else if (a[i] == 22) { delete AT[1]; delete AT[2] }
      else if (a[i] == 23 || a[i] == 24 || a[i] == 29) delete AT[a[i] - 20]
      else if (a[i] == 39 || a[i] == 49) delete AT[a[i] - 1]
      else AT[a[i]] = a[i]
    }
    ST_ = ""
    for (i in AT) ST_ = ST_ (ST_ == "" ? "" : ";") AT[i]
    if (ST_ != "") ST_ = ESC "[" ST_ "m"
  }
}
function lkoff() { return LK_ != "" ? ESC "]8;;" ST : "" }
function lkon()  { return LK_ != "" ? ESC "]8;;" LK_ ST : "" }
function wrap(text, width, base,   n, words, i, w, wl, line, ll, nl, part) {
  nl = 0; ST_ = ""; LK_ = ""; split("", AT); line = base; ll = 0
  if (width < 4) width = 4
  n = split(text, words, " ")
  for (i = 1; i <= n; i++) {
    w = words[i]; if (w == "") continue
    if (w == "\004") { WL[++nl] = line lkoff(); line = base ST_ lkon(); ll = 0; continue }
    wl = vlen(w)
    if (ll > 0 && ll + 1 + wl > width) { WL[++nl] = line lkoff(); line = base ST_ lkon(); ll = 0 }
    while (wl > width - ll) {              # a single word longer than the line: hard split
      part = vtrunc(w, width - ll - (ll > 0)); if (ll > 0) line = line " "
      line = line part; scanstate(part); WL[++nl] = line lkoff(); line = base ST_ lkon(); ll = 0
      w = TRUNC_REST; wl = vlen(w)
    }
    if (w == "") continue
    if (ll > 0) { line = line " "; ll++ }
    line = line w; ll += wl; scanstate(w)
  }
  if (ll > 0 || nl == 0) WL[++nl] = line lkoff()
  return nl
}

# ---------------------------------------------------------------- output
function qprefix(   s, i) {
  if (QD == 0) return ""
  s = ""
  for (i = 1; i <= QD; i++) s = s (i == QD && ALERTC != "" ? ALERTC : cQBAR) "▎" RS0 " "
  return s
}
function out(line) { print MARGIN qprefix() line RS0; OUTN++; LASTBLANK = 0 }
function blank() { if (OUTN && !LASTBLANK) { if (QD) print MARGIN qprefix(); else print ""; LASTBLANK = 1 } }
function sep() { if (NEEDBLANK) blank(); NEEDBLANK = 0 }
function avail() { return CW - 2 * QD }

function flush_para(   text, n, i, base, w, p1, pn) {
  if (PBN == 0) return
  text = ""
  for (i = 1; i <= PBN; i++) text = text (i > 1 ? " " : "") trim(PB[i])
  PBN = 0
  base = QD ? cQUOTE : ""
  if (LD > 0) {
    if (ITEMFIRST) { p1 = IP1; ITEMFIRST = 0 } else p1 = IPN
    pn = IPN; if (ITEMDONE) base = cMUTED
  } else { p1 = ""; pn = "" }
  w = avail() - IPW
  if (!ITEMCONT) sep()
  ITEMCONT = 0
  n = wrap(inl(text, base), w, base)
  for (i = 1; i <= n; i++) out((i == 1 ? p1 : pn) WL[i])
}
function flush_all() { flush_para(); if (INTABLE) flush_table(); if (ICODE) flush_code("") }
function endlist() { if (LD) { LD = 0; IPW = 0; IP1 = ""; IPN = ""; NEEDBLANK = 1 } }

function heading(lv, text,   n, i, w, t) {
  flush_all(); endlist()
  if (OUTN) { blank(); if (lv <= 2) { print ""; LASTBLANK = 1 } }
  NEEDBLANK = 0
  text = trim(text); w = avail()
  if (lv == 1) {
    n = wrap(inl(text, cH1), w - 2, cH1)
    for (i = 1; i <= n; i++) out(cH1 " " pad(WL[i], vlen(WL[i])) cH1 " ")
  } else if (lv == 2) {
    n = wrap(inl(text, cH2), w - 2, cH2)
    for (i = 1; i <= n; i++) out((i == 1 ? cH2 "◆ " : "  ") WL[i])
    out(cLINE rep("─", w))
  } else if (lv == 3) {
    n = wrap(inl(text, cH3), w - 2, cH3)
    for (i = 1; i <= n; i++) out((i == 1 ? cH3 "▸ " : "  ") WL[i])
  } else {
    t = lv == 4 ? cH4 : cH5
    n = wrap(inl(text, t), w, t)
    for (i = 1; i <= n; i++) out(WL[i])
  }
  NEEDBLANK = 1
}

function hl(s, lang,   i, m, pre, rest) {   # tiny highlighter: comments, strings, diff, prompts
  if (!COLOR) return s
  if (lang ~ /^(diff|patch)$/) {
    if (s ~ /^\+/) return cADD s sgr(39)
    if (s ~ /^-/) return cDEL s sgr(39)
    if (s ~ /^@@/) return cH4 s sgr("22;39")
    return s
  }
  rest = ""
  if (lang == "" || lang ~ /^(sh|bash|zsh|shell|console|fish|ya?ml|toml|py|python|rb|ruby|conf|ini|make|makefile|dockerfile|r|perl|text)$/) {
    if (match(s, /(^|[ \t])#/)) { rest = substr(s, RSTART); s = substr(s, 1, RSTART - 1) }
  } else if (match(s, /(^|[ \t])\/\//)) { rest = substr(s, RSTART); s = substr(s, 1, RSTART - 1) }
  pre = ""
  while (match(s, /"[^"]*"|\047[^\047]*\047/)) { pre = pre substr(s, 1, RSTART - 1) cSTR substr(s, RSTART, RLENGTH) sgr(39); s = substr(s, RSTART + RLENGTH) }
  s = pre s
  if (lang ~ /^(console|shell)$/ && s ~ /^\$ /) s = cH2 "$" sgr("22;39") substr(s, 2)
  if (rest != "") s = s cCOMMENT rest sgr("23;39")
  return s
}
function flush_code(lang,   i, w, line, pre, n, lbl) {
  ICODE = 0
  while (CBN > 0 && CB[CBN] ~ /^[ \t]*$/) CBN--
  sep()
  pre = (LD > 0 && CODEIND > 0) ? rep(" ", IPW) : ""
  w = avail() - vlen(pre)
  lbl = lang != "" ? lang " " : ""
  if (!COLOR) out(pre "┌" rep("─", w - 2 - vlen(lbl)) lbl)
  else out(pre cCODE rep(" ", w - vlen(lbl)) cCODELBL lbl)
  for (i = 1; i <= CBN; i++) {
    line = CB[i]; gsub(/\t/, "    ", line); gsub(ESC, "^[", line)
    if (vlen(line) > w - 2) line = vtrunc(line, w - 3) cMUTED "›" sgr(39)
    else line = hl(line, lang)
    if (COLOR) out(pre cCODE " " pad(line, w - 1))
    else out(pre "│ " line)
  }
  if (COLOR) out(pre cCODE rep(" ", w)); else out(pre "└" rep("─", w - 1))
  CBN = 0; NEEDBLANK = 1
}

function splitrow(line, arr,   n, i) {
  line = trim(line); gsub(/\\\|/, "\005", line)
  sub(/^\|/, "", line); sub(/\|$/, "", line)
  n = split(line, arr, "|")
  for (i = 1; i <= n; i++) { arr[i] = trim(arr[i]); gsub(/\005/, "|", arr[i]) }
  return n
}
function tline(l, m, r,   c, s) {
  s = cLINE l
  for (c = 1; c <= NC; c++) s = s rep("─", TW[c] + 2) (c < NC ? m : r)
  return s
}
function flush_table(   r, c, n, cells, AL, tot, w, mx, mi, h, k, line, cell, t, base, sum) {
  INTABLE = 0; sep()
  NC = splitrow(TROW[0], cells)
  n = splitrow(TSEP, cells)
  for (c = 1; c <= NC; c++) { t = cells[c]; AL[c] = (t ~ /^:.*:$/) ? "c" : (t ~ /:$/) ? "r" : "l"; TW[c] = 1 }
  for (r = 0; r <= TRN; r++) {
    n = splitrow(TROW[r], cells)
    for (c = 1; c <= NC; c++) {
      base = r == 0 ? cB cTH : ""
      TC[r, c] = c <= n ? inl(cells[c], base) : ""
      if (vlen(TC[r, c]) > TW[c]) TW[c] = vlen(TC[r, c])
    }
  }
  w = avail() - (3 * NC + 1)
  while (1) {
    sum = 0; mx = 0; mi = 0
    for (c = 1; c <= NC; c++) { sum += TW[c]; if (TW[c] > mx) { mx = TW[c]; mi = c } }
    if (sum <= w || mx <= 4) break
    TW[mi]--
  }
  out(tline("╭", "┬", "╮"))
  for (r = 0; r <= TRN; r++) {
    h = 1
    for (c = 1; c <= NC; c++) {
      base = r == 0 ? cB cTH : ""
      k = wrap(TC[r, c], TW[c], base); TL[c] = k; if (k > h) h = k
      for (t = 1; t <= k; t++) TX[c, t] = WL[t]
    }
    for (t = 1; t <= h; t++) {
      line = cLINE "│" RS0
      for (c = 1; c <= NC; c++) {
        cell = t <= TL[c] ? TX[c, t] : ""
        k = TW[c] - vlen(cell)
        if (AL[c] == "r") cell = rep(" ", k) cell
        else if (AL[c] == "c") cell = rep(" ", int(k / 2)) cell rep(" ", k - int(k / 2))
        else cell = cell rep(" ", k)
        line = line " " cell RS0 " " cLINE "│" RS0
      }
      out(fit(line, avail()))
    }
    if (r == 0) out(tline("├", "┼", "┤"))
  }
  out(tline("╰", "┴", "╯"))
  NEEDBLANK = 1
}

function front_matter(   i, k, v) {
  if (!FMN) return
  out(cLINE "╭─ " cMUTED "front matter")
  for (i = 1; i <= FMN; i++) out(cLINE "│ " cMUTED fit(FM[i], avail() - 2))
  out(cLINE "╰─")
  NEEDBLANK = 1
}

BEGIN {
  ESC = "\033"; ST = ESC "\\"
  if (W < 30) W = 80
  MARGIN = "  "; CW = W - 4
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
  HIGH = "[" sprintf("%c", 128) "-" sprintf("%c", 255) "]"
  CONT = "[" sprintf("%c", 128) "-" sprintf("%c", 191) "]"
  L4 = "[" sprintf("%c", 240) "-" sprintf("%c", 247) "]"
  LW3 = "[" sprintf("%c", 227) "-" sprintf("%c", 237) "]"
  VS16 = sprintf("%c%c%c", 239, 184, 143)
  NBSP = sprintf("%c%c", 194, 160)
  SGRRE = ESC "\\[[0-9;]*m"
  OSCRE = ESC "\\]8;;[^" ESC "]*" ESC "\\\\"
  ANYESC = ESC "(\\[[0-9;]*m|\\]8;;[^" ESC "]*" ESC "\\\\)"
  RS0 = sgr(0)
  cH1 = sgr("1;38;5;231;48;5;98"); cH2 = sgr("1;38;5;213"); cH3 = sgr("1;38;5;141"); cH4 = sgr("1;38;5;81"); cH5 = sgr("1;38;5;250")
  cLINE = sgr("38;5;238"); cMUTED = sgr("38;5;244"); cQUOTE = sgr("3;38;5;250"); cQBAR = sgr("38;5;98")
  cCODE = sgr("48;5;236;38;5;252"); cCODELBL = sgr("38;5;244;48;5;236"); cICODE = sgr("38;5;215;48;5;237"); cICODEOFF = sgr("39;49")
  cLINK = sgr("4;38;5;81"); cLINKOFF = sgr("24;39"); cKBD = sgr("1;38;5;252;48;5;239"); cKBDOFF = sgr("22;39;49")
  cB = sgr(1); cBOFF = sgr(22); cI = sgr(3); cIOFF = sgr(23); cS = sgr(9); cSOFF = sgr(29); cTH = sgr("38;5;141")
  cBUL = sgr("38;5;213"); cNUM = sgr("38;5;141"); cOK = sgr("38;5;114"); cBOX = sgr("38;5;244")
  cSTR = sgr("38;5;150"); cCOMMENT = sgr("3;38;5;244"); cADD = sgr("38;5;114"); cDEL = sgr("38;5;203")
  ALC["NOTE"] = sgr("38;5;75"); ALC["TIP"] = sgr("38;5;114"); ALC["IMPORTANT"] = sgr("38;5;141"); ALC["WARNING"] = sgr("38;5;221"); ALC["CAUTION"] = sgr("38;5;203")
  ALI["NOTE"] = "ℹ Note"; ALI["TIP"] = "✦ Tip"; ALI["IMPORTANT"] = "❢ Important"; ALI["WARNING"] = "▲ Warning"; ALI["CAUTION"] = "◆ Caution"
  BUL[1] = "•"; BUL[2] = "◦"; BUL[3] = "▪"; BUL[4] = "▫"
}

# pass 1: collect reference-style link definitions
FNR == NR {
  if (match($0, /^ *\[[^]]+\]:[ \t]+[^ \t]+/)) {
    m = substr($0, RSTART, RLENGTH); lab = m; sub(/^ *\[/, "", lab); sub(/\]:.*$/, "", lab)
    u = m; sub(/^ *\[[^]]+\]:[ \t]+/, "", u); gsub(/^<|>$/, "", u)
    REF[tolower(lab)] = u; ISDEF[FNR] = 1
  }
  next
}

# pass 2: render
{
  line = $0; sub(/\r$/, "", line)
  if (FNR == 1 && line ~ /^---[ \t]*$/) { INFM = 1; next }
  if (INFM) { if (line ~ /^(---|\.\.\.)[ \t]*$/) { INFM = 0; front_matter() } else FM[++FMN] = line; next }

  if (INCODE) {
    raw = line
    if (CODEQD) { for (q = 0; q < CODEQD; q++) sub(/^ *> ?/, "", raw) }
    t = raw; sub(/^ +/, "", t)
    if (substr(t, 1, FENCEN) == FENCE && t ~ /^(`+|~+)[ \t]*$/) { INCODE = 0; flush_code(CODELANG); next }
    if (CODEIND) { for (q = 0; q < CODEIND && substr(raw, 1, 1) == " "; q++) raw = substr(raw, 2) }
    CB[++CBN] = raw; next
  }
  if (INCOMMENT) { if ((i = index(line, "-->")) == 0) next; INCOMMENT = 0; line = substr(line, i + 3); if (line ~ /^[ \t]*$/) next }
  had = line !~ /^[ \t]*$/
  while ((i = index(line, "<!--")) > 0) {
    j = index(substr(line, i), "-->")
    if (j) line = substr(line, 1, i - 1) substr(line, i + j + 2)
    else { INCOMMENT = 1; line = substr(line, 1, i - 1); break }
  }
  if (had && line ~ /^[ \t]*$/) next
  if (ISDEF[FNR]) next

  # indented code block (outside lists)
  if (ICODE) { if (line ~ /^(    |\t)/ || line ~ /^[ \t]*$/) { sub(/^(    |\t)/, "", line); CB[++CBN] = line; next } flush_code("") }

  # blockquote depth
  qd = 0
  while (match(line, /^ *> ?/)) { qd++; line = substr(line, RLENGTH + 1) }
  if (qd != QD) { flush_all(); if (QD == 0 || qd == 0) { endlist(); NEEDBLANK = 1; if (qd < QD) QD = qd; sep() }; if (qd == 0) ALERTC = ""; QD = qd }
  if (QD && match(line, /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/)) {
    k = substr(line, 3, RLENGTH - 3); ALERTC = ALC[k]; out(ALERTC sgr(1) ALI[k]); next
  }

  # table body
  if (INTABLE) { if (line ~ /\|/ && line !~ /^[ \t]*$/) { TROW[++TRN] = line; next } flush_table() }

  # blank
  if (line ~ /^[ \t]*$/) {
    flush_para(); NEEDBLANK = 1; AFTERBLANK = 1
    if (QD) blank()
    next
  }

  # fenced code
  if (match(line, /^ *(```+|~~~+)/)) {
    rs = RSTART; rl = RLENGTH; flush_para(); t = substr(line, rs, rl); CODEIND = t; sub(/[`~]+$/, "", CODEIND); CODEIND = length(CODEIND)
    if (LD && CODEIND < 2 && AFTERBLANK) endlist()
    FENCE = substr(t, CODEIND + 1); FENCEN = length(FENCE)
    CODELANG = substr(line, rs + rl); CODELANG = trim(CODELANG); sub(/[ {].*$/, "", CODELANG); CODELANG = tolower(CODELANG)
    INCODE = 1; CODEQD = QD; CBN = 0; AFTERBLANK = 0; next
  }

  # ATX heading
  if (match(line, /^ *#+([ \t]|$)/)) {
    t = line; sub(/^ */, "", t); n = 0; while (substr(t, n + 1, 1) == "#") n++
    if (n <= 6) { t = substr(t, n + 1); sub(/[ \t]+#+[ \t]*$/, "", t); heading(n, t); AFTERBLANK = 0; next }
  }
  # setext heading
  if (PBN > 0 && LD == 0 && line ~ /^ *=+[ \t]*$/) { t = PB[1]; for (i = 2; i <= PBN; i++) t = t " " PB[i]; PBN = 0; heading(1, t); next }
  if (PBN > 0 && LD == 0 && line ~ /^ *-+[ \t]*$/) { t = PB[1]; for (i = 2; i <= PBN; i++) t = t " " PB[i]; PBN = 0; heading(2, t); next }
  # horizontal rule
  if (line ~ /^ *(-[ \t]*-[ \t]*-[- \t]*|\*[ \t]*\*[ \t]*\*[* \t]*|_[ \t]*_[ \t]*_[_ \t]*)$/) {
    flush_all(); endlist(); blank(); out(cLINE rep("─", avail())); NEEDBLANK = 1; AFTERBLANK = 0; next
  }
  # table header (previous line had pipes, this one is the separator)
  if (PBN == 1 && PB[1] ~ /\|/ && line ~ /^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$/) {
    TROW[0] = PB[1]; PBN = 0; TSEP = line; TRN = 0; INTABLE = 1; flush_para(); next
  }

  # list item
  if (match(line, /^ *([-*+]|[0-9]+[.)])([ \t]+|$)/)) {
    rs = RSTART; rl = RLENGTH; flush_para()
    m = substr(line, rs, rl); ind = m; sub(/[^ ].*$/, "", ind); ind = length(ind)
    mk = trim(m); txt = substr(line, rs + rl)
    if (LD == 0) { if (!OUTN || NEEDBLANK) sep(); LD = 1; LS[1] = ind }
    else if (ind > LS[LD] + 1 && LD < 8) { LD++; LS[LD] = ind }
    else { while (LD > 1 && ind < LS[LD] - 1) LD--; if (AFTERBLANK) sep() }
    NEEDBLANK = 0; ITEMCONT = 1
    indent = rep("  ", LD - 1)
    if (mk ~ /^[0-9]/) bul = cNUM mk RS0 " "; else bul = cBUL BUL[(LD - 1) % 4 + 1] RS0 " "
    ITEMDONE = 0
    if (match(txt, /^\[[ xX]\][ \t]/)) {
      if (substr(txt, 2, 1) == " ") bul = cBOX "☐" RS0 " "; else { bul = cOK "✔" RS0 " "; ITEMDONE = 1 }
      txt = substr(txt, 5)
    }
    IP1 = indent bul; IPW = vlen(IP1); IPN = rep(" ", IPW); ITEMFIRST = 1
    PB[++PBN] = txt; if (txt == "") { PBN = 0; out(IP1); ITEMFIRST = 0 }
    AFTERBLANK = 0; next
  }
  # inside a list: indented text continues the item, otherwise the list ends after a blank line
  if (LD) {
    if (AFTERBLANK && line !~ /^  /) endlist()
    else if (AFTERBLANK) { ITEMCONT = 0; NEEDBLANK = 1 }
  }

  # indented code block
  if (PBN == 0 && LD == 0 && line ~ /^(    |\t)/) { flush_all(); ICODE = 1; CBN = 0; sub(/^(    |\t)/, "", line); CB[++CBN] = line; next }

  # HTML block lines
  if (line ~ /^ *<\/?[A-Za-z]/) {
    if (match(line, /^ *<h[1-6][ >]/)) { n = substr(line, RSTART + RLENGTH - 2, 1) + 0; t = line; gsub(/<[^>]*>/, "", t); heading(n, t); next }
    if (line ~ /<summary>/) { t = line; gsub(/<[^>]*>/, "", t); flush_para(); sep(); out(cB "▸ " inl(t, cB)); next }
    t = line; gsub(/<\/?(div|p|center|details|picture|source|section|span)[^>]*>/, "", t)
    if (t ~ /^[ \t]*$/) { flush_para(); next }
    line = t
  }

  # paragraph text (hard break: two trailing spaces or a backslash)
  if (line ~ /(  |\\)$/) { sub(/\\$/, "", line); line = line " \004" }
  PB[++PBN] = line; AFTERBLANK = 0
}

END {
  flush_all(); if (INCODE) flush_code(CODELANG)
  if (NLINKS) {
    QD = 0; blank(); out(cLINE rep("─", avail())); out(cMUTED "Links")
    for (i = 1; i <= NLINKS; i++) out(cMUTED "[" i "] " sgr(39) fit(LINKS[i], avail() - 6))
  }
}
AWK

md_has_osc8() {  # terminals that render OSC 8 hyperlinks (Terminal.app does not)
  case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm|ghostty|vscode|Hyper|Tabby|rio) return 0 ;; esac
  case "${TERM:-}" in xterm-kitty|xterm-ghostty|alacritty|foot*) return 0 ;; esac
  [ -n "${KITTY_WINDOW_ID:-}${WEZTERM_PANE:-}${GHOSTTY_RESOURCES_DIR:-}" ]
}

md_render() {  # $1 file, $2 width (default: terminal) → ANSI text on stdout
  local f=$1 w=${2:-} color=0 osc=0 clean
  [ -n "$w" ] || w=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
  [ "${w:-0}" -ge 20 ] 2>/dev/null || w=80   # no terminal, or one that reports 0 columns
  [ "$w" -gt 120 ] && w=120
  if [ -t 1 ] || [ "${MD_FORCE_COLOR:-}" = 1 ]; then [ -z "${NO_COLOR:-}" ] && color=1; fi
  [ "$color" = 1 ] && md_has_osc8 && osc=1
  clean=$(mktemp -t roam-md) || return 1
  LC_ALL=C tr -d '\000-\010\013\014\015\016-\037\177' < "$f" > "$clean"   # keeps tab and newline
  LC_ALL=C awk -v W="$w" -v COLOR="$color" -v OSC8="$osc" "$_MD_AWK" "$clean" "$clean"
  rm -f "$clean"
}

md_pager() {  # $1 file with rendered lines, $2 title. j/k ↑↓ space/b d/u g/G / n/N q
  local file=$1 title=${2:-} L=() P=() l i c step top=0 rows cols h n k rest q="" hit=-1 frame pct oldtrap
  local IFS=$'\n'; set -f   # word-split on newlines only (blank lines become " " so they survive)
  L=($(sed 's/^$/ /' "$file"))
  P=($(sed $'s/\033\\[[0-9;]*m//g; s/\033\\]8;;[^\033]*\033\\\\//g; s/^$/ /' "$file"))
  set +f; IFS=$' \t\n'
  n=${#L[@]}
  read -r rows cols < <(stty size </dev/tty 2>/dev/null || echo "24 80")
  [ "${rows:-0}" -ge 5 ] 2>/dev/null || rows=24
  h=$((rows - 1))
  if [ "$n" -le "$h" ] || [ ! -t 1 ]; then cat "$file"; return; fi
  printf '\033[?1049h\033[?25l' >/dev/tty
  oldtrap=$(trap -p INT)
  trap 'k=q' INT   # ctrl-c leaves the pager, not roam
  while :; do
    [ "$top" -gt $((n - h)) ] && top=$((n - h)); [ "$top" -lt 0 ] && top=0
    frame=$'\033[H'
    for ((i = top; i < top + h; i++)); do
      if [ "$i" -ge "$n" ]; then frame+=$'\033[K\n'
      elif [ "$i" -eq "$hit" ]; then frame+=$'\033[7m'"${P[$i]}"$'\033[0m\033[K\n'
      else frame+="${L[$i]}"$'\033[K\n'; fi
    done
    pct=$(( (top + h) * 100 / n )); [ "$pct" -gt 100 ] && pct=100
    frame+=$'\033[48;5;236m\033[38;5;141m ◆ '"$title"$' \033[38;5;244m'" $((top + 1))–$((top + h > n ? n : top + h))/$n · $pct%  ${q:+/$q · }j/k space/b g/G / n q "$'\033[K\033[0m'
    printf '%s' "$frame" >/dev/tty
    IFS= read -rsn1 k </dev/tty || [ "${k:-}" = q ] || break
    if [ "$k" = $'\033' ]; then
      IFS= read -rsn2 -t 1 rest </dev/tty
      case $rest in '[5'|'[6'|'[1'|'[4') IFS= read -rsn1 -t 1 _ </dev/tty ;; esac
      case $rest in '[A') k=k ;; '[B') k=j ;; '[5') k=b ;; '[6') k=' ' ;; '[H'|'[1') k=g ;; '[F'|'[4') k=G ;; '') k=q ;; *) k=x ;; esac
    fi
    case $k in
      j|'') top=$((top + 1)) ;;
      k) top=$((top - 1)) ;;
      ' '|f) top=$((top + h - 1)) ;;
      b) top=$((top - h + 1)) ;;
      d) top=$((top + h / 2)) ;;
      u) top=$((top - h / 2)) ;;
      g) top=0 ;;
      G) top=$((n - h)) ;;
      q|Q) break ;;
      /|n|N)
        if [ "$k" = / ]; then
          printf '\033[%d;1H\033[K\033[?25h/' "$rows" >/dev/tty
          stty echo </dev/tty; IFS= read -r q </dev/tty; stty -echo </dev/tty
          printf '\033[?25l' >/dev/tty; hit=$top; [ "$hit" -ge 0 ] || hit=0; k=n; hit=$((hit - 1))
        fi
        [ -n "$q" ] || continue
        shopt -s nocasematch
        step=1; [ "$k" = N ] && step=$((n - 1))
        for ((c = 1, i = (hit + step) % n; c <= n; c++, i = (i + step) % n)); do [[ ${P[$i]} == *"$q"* ]] && break; done
        shopt -u nocasematch
        if [ "$c" -le "$n" ]; then hit=$i; top=$((i - h / 3)); fi
        ;;
    esac
  done
  printf '\033[?25h\033[?1049l' >/dev/tty
  eval "${oldtrap:-trap - INT}"
}

md_view() {  # $1 markdown file, $2 title — rendered in the pager (ROAM_MD=glow|mdcat: those instead)
  local f=$1 tmp
  [ -r "$f" ] || return 1
  if [ -t 1 ]; then
    case ${ROAM_MD:-} in glow|mdcat) command -v "$ROAM_MD" >/dev/null 2>&1 && { "$ROAM_MD" -p "$f"; return; } ;; esac
  else md_render "$f"; return; fi
  tmp=$(mktemp -t roam-md) || return 1
  md_render "$f" >"$tmp"
  md_pager "$tmp" "${2:-$(basename "$f")}"
  rm -f "$tmp"
}

md_files() {  # $1 project dir → "rank<TAB>kind<TAB>relpath<TAB>mtime<TAB>lines" for the files worth reading, best first
  local dir=$1 f
  {
    git -C "$dir" ls-files -co --exclude-standard -- '*.md' '*.markdown' '*.mdc' '*.txt' '.cursorrules' '.windsurfrules' 2>/dev/null
    for f in CLAUDE.local.md .claude/CLAUDE.md; do [ -f "$dir/$f" ] && echo "$f"; done
  } | awk -F/ '
    { p = $0; n = $NF; u = toupper(n); d = NF - 1; r = 0; k = "" }
    d == 0 && u ~ /^README/                                  { r = 10; k = "readme" }
    d == 0 && u ~ /^(CLAUDE(\.LOCAL)?|AGENTS|GEMINI)\.MD$/  { r = 20; k = "agent" }
    p ~ /^(\.claude\/CLAUDE\.md|\.github\/copilot-instructions\.md)$/ { r = 21; k = "agent" }
    d == 0 && n ~ /^\.(cursorrules|windsurfrules)$/          { r = 22; k = "agent" }
    p ~ /^\.cursor\/rules\//                                 { r = 23; k = "agent" }
    d >= 1 && u ~ /^(CLAUDE|AGENTS)\.MD$/ && r == 0          { r = 25; k = "agent" }
    d == 0 && u ~ /^(TODO|ROADMAP|BACKLOG|PLAN|NOTES)/       { r = 30; k = "plan" }
    d == 0 && u ~ /^(CHANGELOG|CHANGES|HISTORY|RELEASES?)/   { r = 40; k = "changes" }
    d == 0 && u ~ /^(CONTRIBUTING|ARCHITECTURE|DESIGN|SECURITY|DEVELOPMENT|HACKING)/ { r = 50; k = "guide" }
    r == 0 && $1 ~ /^(docs?|documentation)$/ && d <= 2 && u ~ /\.MD$/ { r = 60; k = "docs" }
    r == 0 && d == 0 && u ~ /\.MD$/                          { r = 70; k = "doc" }
    r == 0 && d == 1 && u ~ /^README\.MD$/ && p !~ /^(node_modules|vendor|Pods|\.build)\// { r = 80; k = "readme" }
    r > 0 && p !~ /(^|\/)(node_modules|vendor|Pods|Carthage|\.build|DerivedData)\// { print r "\t" k "\t" p }
  ' | while IFS=$'\t' read -r r k f; do
        [ -f "$dir/$f" ] || continue
        [ -L "$dir/$f" ] && [ -f "$(dirname "$dir/$f")/$(readlink "$dir/$f")" ] && continue   # AGENTS.md -> CLAUDE.md: show once
        printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$k" "$f" "$(stat -f %m "$dir/$f")" "$(wc -l <"$dir/$f" | tr -d ' ')"
      done | sort -t$'\t' -k1,1n -k4,4nr | head -40
}
