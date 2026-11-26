#!/usr/bin/env bash
# honk-audit.sh — 审查「honk + doona 更新」有没有留下问题。
#
# 用法（在构建主机上，root）：
#   bash /home/openwrt/immortalwrt/tools/honk-audit.sh            # 全量审查
#   bash /home/openwrt/immortalwrt/tools/honk-audit.sh --quick    # 跳过要下载的检查
#
# 退出码：0 = 一切正常；1 = 有 FAIL；2 = 只有 WARN。
# 每次更新后都必须跑一次（更新流程的最后一步），并把结果写进 HONK.md。
set -uo pipefail

TREE="${AUDIT_TREE:-/home/openwrt/immortalwrt}"
UP_REPO="${AUDIT_UPSTREAM:-https://github.com/kenzok8/openwrt-honk.git}"
WORK="${AUDIT_WORK:-/tmp/honk-audit}"
QUICK=0
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --refresh-whitelist) REFRESH=1 ;;
  esac
done
[ "$REFRESH" = "1" ] && export AUDIT_REFRESH_WHITELIST=1

FAIL=0
WARN=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

mkdir -p "$WORK"
cd "$TREE" || { echo "no tree at $TREE"; exit 1; }

head_ "1) the tree"
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files -o --exclude-standard)" ]; then
  ok "the tree is clean"
else
  warn "the tree has uncommitted changes"
  git status -s | head -8 | sed 's/^/        /'
fi
printf '        the branch: %s\n' "$(git rev-parse --abbrev-ref HEAD)"
printf '        the HEAD:   %s %s\n' "$(git rev-parse --short=12 HEAD)" "$(git log -1 --format=%s)"
if [ "$(stat -c %U "$TREE")" = "openwrt" ]; then ok "the tree owner is openwrt"; else bad "the tree owner is $(stat -c %U "$TREE"), expected openwrt"; fi

head_ "2) the upstream release"
rm -rf "$WORK/up" "$WORK/base" "$WORK/new"
if [ "$QUICK" = "1" ] && [ -d "$WORK/up/.git" ]; then
  :
else
  timeout 900 git clone --quiet --filter=blob:none --no-checkout "$UP_REPO" "$WORK/up" >/dev/null 2>&1 \
    || { bad "cannot clone the upstream"; exit 1; }
fi
cd "$WORK/up"
git fetch --quiet --tags --force origin 2>/dev/null
LATEST=$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]' | head -1)
[ -n "$LATEST" ] || { bad "no upstream tag"; exit 1; }
printf '        the latest upstream tag: %s\n' "$LATEST"
printf '        the upstream head:       %s\n' "$(git rev-parse --short=12 origin/main 2>/dev/null)"

OUR_VER=$(sed -n 's/^PKG_VERSION:=//p' "$TREE/package/honk/Makefile" | head -1)
OUR_TAG=$(sed -n 's/^HONK_SOURCE_TAG?=//p' "$TREE/package/honk/Makefile" | head -1)
OUR_CORE=$(sed -n 's/^CORE_COMMIT:=//p' "$TREE/package/honk/Makefile" | head -1)
OUR_LUCI=$(sed -n 's/^PKG_VERSION:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)
printf '        our honk:        %s-r%s\n' "$OUR_VER" "$(sed -n 's/^PKG_RELEASE:=//p' "$TREE/package/honk/Makefile" | head -1)"
printf '        our luci-app:    %s-r%s\n' "$OUR_LUCI" "$(sed -n 's/^PKG_RELEASE:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)"
printf '        our core pin:    %s\n' "$OUR_CORE"
printf '        our source tag:  %s\n' "$OUR_TAG"
UP_VER=$(git show "$LATEST":honk/Makefile | sed -n 's/^PKG_VERSION:=//p' | head -1)
UP_CORE=$(git show "$LATEST":honk/Makefile | sed -n 's/^CORE_COMMIT:=//p' | head -1)
if [ "$OUR_VER" = "$UP_VER" ] && [ "$OUR_CORE" = "$UP_CORE" ]; then
  ok "we are on the upstream $LATEST pins"
else
  warn "the upstream moved: $LATEST has honk $UP_VER / core ${UP_CORE:0:10} (ours: $OUR_VER / ${OUR_CORE:0:10})"
fi

head_ "3) the pin consistency (ours vs the upstream's ci/pins.env)"
if git show "$LATEST":ci/pins.env > "$WORK/pins.env" 2>/dev/null; then
  . "$WORK/pins.env" 2>/dev/null
  if [ "${CORE_COMMIT:-}" = "$OUR_CORE" ]; then ok "the core pin matches"; else bad "the core pin differs from the upstream's"; fi
  UP_DOONA=$(git show "$LATEST":luci-app-honk/Makefile | sed -n 's/^PKG_SOURCE:=//p' | head -1)
  OUR_DOONA=$(sed -n 's/^PKG_SOURCE:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)
  if [ "$UP_DOONA" = "$OUR_DOONA" ]; then ok "the doona archive matches"; else bad "the doona archive differs: ours $OUR_DOONA vs upstream $UP_DOONA"; fi
  UP_TAG=$(git show "$LATEST":honk/Makefile | sed -n 's/^HONK_SOURCE_TAG?=//p' | head -1)
  if [ "$UP_TAG" = "$OUR_TAG" ]; then ok "the source tag matches"; else bad "the source tag differs: ours $OUR_TAG vs upstream $UP_TAG"; fi
else
  warn "the upstream has no ci/pins.env at $LATEST"
fi
A=$(sed -n 's/^HONK_SOURCE_TAG?=//p' "$TREE/package/honk/Makefile" | head -1)
B=$(sed -n 's/^HONK_SOURCE_TAG?=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)
if [ "$A" = "$B" ]; then ok "both packages point at the same source tag"; else bad "the two packages point at different source tags"; fi
for arch in X86_64 AARCH64 ARMV7; do
  h=$(sed -n "s/^HONK_HASH_${arch}?=//p" "$TREE/package/honk/Makefile" | head -1)
  if printf '%s' "$h" | grep -qE '^[0-9a-f]{64}$'; then ok "HONK_HASH_${arch} is a sha256"; else bad "HONK_HASH_${arch} is missing or malformed"; fi
done
h=$(sed -n 's/^PKG_HASH:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)
printf '%s' "$h" | grep -qE '^[0-9a-f]{64}$' && ok "the doona PKG_HASH is a sha256" || bad "the doona PKG_HASH is missing or malformed"
if grep -n 'SKIP' "$TREE/package/honk/Makefile" "$TREE/package/luci-app-honk/Makefile" >/dev/null 2>&1; then
  bad "a package Makefile falls back to a skipped hash"
else ok "no skipped hashes"; fi

head_ "4) our local layer (must survive every upstream merge)"
LOCAL_LIST="$TREE/tools/honk-audit-local-files.txt"
for f in \
  package/honk/files/geodata.sh \
  package/honk/files/control.sh \
  package/honk/files/90-honk-boot \
  package/honk/files/config.dae \
  package/honk/files/system.dae \
  package/honk/files/honk.config \
  package/honk/files/honk.init \
  package/honk/files/maintenance.sh \
  package/luci-app-honk/po/zh_Hans/honk.po \
  package/luci-app-honk/po/zh-cn/honk.po \
  package/luci-app-honk/htdocs/luci-static/resources/view/honk/rpc.js \
  package/luci-app-honk/root/usr/libexec/rpcd/honk \
  package/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json ; do
  [ -f "$TREE/$f" ] && ok "$f" || bad "$f is missing"
done
grep -q '^PKG_LICENSE:=GPL-3.0-only' "$TREE/package/honk/Makefile" && ok "the GPL licensing is kept" || bad "the package license changed"
grep -q 'geodata.sh' "$TREE/package/honk/Makefile" && ok "geodata.sh is installed by the package" || bad "geodata.sh is not installed"
grep -q 'store' "$TREE/package/honk/files/90-honk-boot" && ok "the db store mode default is kept" || warn "no store default in 90-honk-boot"

head_ "5) the delta against the upstream (the whitelist)"
git -C "$WORK/up" worktree remove --force "$WORK/base" >/dev/null 2>&1
git -C "$WORK/up" worktree remove --force "$WORK/new" >/dev/null 2>&1
git -C "$WORK/up" worktree add --quiet "$WORK/new" "$LATEST" >/dev/null 2>&1
python3 - "$TREE" "$WORK/new" "$LOCAL_LIST" <<'PY'
import io, os, sys
tree, up, listf = sys.argv[1], sys.argv[2], sys.argv[3]
def files(root, sub):
    out = {}
    base = os.path.join(root, sub)
    for dp, _d, fs in os.walk(base):
        for f in fs:
            p = os.path.join(dp, f)
            out[os.path.relpath(p, base)] = io.open(p, "rb").read()
    return out
delta = []
for pkg in ("honk", "luci-app-honk"):
    ours = files(tree, os.path.join("package", pkg))
    theirs = files(up, pkg)
    for rel in sorted(set(ours) | set(theirs)):
        if ours.get(rel) != theirs.get(rel):
            delta.append("%s/%s" % (pkg, rel))
if os.environ.get("AUDIT_REFRESH_WHITELIST") == "1":
    head = ("# honk-audit-local-files.txt\n"
            "# 我们这棵树相对上游的本地改动清单（每次更新后由 tools/honk-audit.sh 核对）。\n"
            "# 上游改了这里的某个文件 -> 审查脚本会报 WARN/FAIL，提醒人手工合并。\n")
    io.open(listf, "w", encoding="utf-8").write(head + "\n".join(delta) + "\n")
    print("        the whitelist was refreshed: %d files" % len(delta))
    for d in delta:
        print("          %s" % d)
    sys.exit(0)
expected = []
if os.path.exists(listf):
    expected = [l.strip() for l in io.open(listf, encoding="utf-8") if l.strip() and not l.startswith("#")]
added = sorted(set(delta) - set(expected))
gone = sorted(set(expected) - set(delta))
print("        the delta vs %s: %d files" % (os.path.basename(up), len(delta)))
for d in added:
    print("        + %s" % d)
for d in gone:
    print("        - %s" % d)
if added or gone:
    print("        THE WHITELIST IS OUT OF DATE -> review the merge by hand")
    sys.exit(3)
print("        the whitelist matches the tree")
PY
RC=$?
if [ "$RC" = "3" ]; then WARN=$((WARN+1)); elif [ "$RC" != "0" ]; then FAIL=$((FAIL+1)); fi

head_ "6) the upstream static checks on the merged tree"
if [ "$QUICK" = "1" ]; then
  warn "skipped (--quick)"
else
  rm -rf "$WORK/merged"
  cp -a "$WORK/new" "$WORK/merged" 2>/dev/null
  rm -rf "$WORK/merged/honk" "$WORK/merged/luci-app-honk"
  cp -a "$TREE/package/honk" "$WORK/merged/honk"
  cp -a "$TREE/package/luci-app-honk" "$WORK/merged/luci-app-honk"
  ( cd "$WORK/merged" && timeout 900 bash scripts/check.sh ) > "$WORK/check.log" 2>&1
  if [ $? -eq 0 ]; then ok "the upstream check.sh passed"; else bad "the upstream check.sh failed"; tail -12 "$WORK/check.log" | sed 's/^/        /'; fi
  ( cd "$WORK/merged" && timeout 1800 bash scripts/verify-source-assets.sh ) > "$WORK/assets.log" 2>&1
  if [ $? -eq 0 ]; then ok "the source assets verified (independent download + sha256)"; else bad "the source asset verification failed"; tail -12 "$WORK/assets.log" | sed 's/^/        /'; fi
fi

head_ "7) the core: the interfaces our layer depends on"
CORE_ARCHIVE="$TREE/dl/honk-core-$OUR_CORE-aarch64.tar.gz"
if [ ! -f "$CORE_ARCHIVE" ]; then
  warn "the core archive is not in dl/ yet (the download step has not run)"
else
  rm -rf "$WORK/core" && mkdir -p "$WORK/core"
  tar -xzf "$CORE_ARCHIVE" -C "$WORK/core" 2>/dev/null
  CBIN=$(find "$WORK/core" -name honk-core | head -1)
  if [ -z "$CBIN" ]; then bad "cannot extract the core"; else
    # strings 一次落盘再 grep：管道里直接 grep -q 会因 SIGPIPE + pipefail 误判。
    strings -a "$CBIN" > "$WORK/core.strings" 2>/dev/null
    for pat in "--store" "runs without the Clash API" "configuration db" \
                "configuration database is unavailable" "stored geodata settings are unusable" \
                "asset_conflict" "group_unavailable" "geodata_settings" "listener_secret" \
                "sqlite_sequence" "revision" "json_each" "HONK_VMLINUX_BTF" \
                "kernel argv capture unavailable"; do
      if grep -qF -- "$pat" "$WORK/core.strings"; then ok "the core still has: $pat"; else bad "the core LOST: $pat"; fi
    done
    printf '        the core version: %s\n' "$(strings -a "$CBIN" 2>/dev/null | grep -oE '0\.1\.0-(beta|rc)\.[0-9]+' | sort -u | head -1)"
  fi
fi

head_ "8) the config keys: ours vs the upstream's vs the core"
UP_CFG="$WORK/new/honk/files/config.dae"
if [ -n "${CBIN:-}" ] && [ -f "$UP_CFG" ]; then
  python3 - "$CBIN" "$TREE" "$UP_CFG" <<'PY'
import io, os, re, subprocess, sys
core, tree, upcfg = sys.argv[1], sys.argv[2], sys.argv[3]
strings = subprocess.run(["strings", "-a", core], capture_output=True, text=True, errors="replace").stdout
def keys_of(path):
    src = io.open(path, encoding="utf-8").read()
    return set(m.group(1) for m in re.finditer(r"^\s*([a-z][a-z0-9_]{2,40})\s*[:{]", src, re.M))
ours = set()
for f in ("package/honk/files/config.dae", "package/honk/files/system.dae"):
    ours |= keys_of(os.path.join(tree, f))
upstream = keys_of(upcfg)
only_ours = sorted(ours - upstream)
missing = [k for k in only_ours if not re.search(r"\b%s\b" % re.escape(k), strings)]
print("        our keys: %d, the upstream's: %d, ours only: %d"
      % (len(ours), len(upstream), len(only_ours)))
print("        our own keys: %s" % (", ".join(only_ours) if only_ours else "(none)"))
if missing:
    print("        !! the core does not mention: %s" % ", ".join(missing))
    print("        (a key the core does not know can make it refuse the whole config)")
else:
    print("        the core knows every key of ours")
PY
else
  warn "skipped (no core binary or no upstream config)"
fi

head_ "9) the doona panel (the code diff against the previous upstream release)"
NEW_DOONA=$(sed -n 's/^PKG_SOURCE:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)
if [ -f "$TREE/dl/$NEW_DOONA" ]; then
  rm -rf "$WORK/doona" && mkdir -p "$WORK/doona"
  tar -xzf "$TREE/dl/$NEW_DOONA" -C "$WORK/doona" 2>/dev/null
  printf '        the panel version: %s\n' "$(grep -m1 '^Version:' "$WORK/doona/doona/SOURCE" 2>/dev/null | sed 's/Version: //')"
  printf '        the panel commit:  %s\n' "$(grep -m1 '^Commit:' "$WORK/doona/doona/SOURCE" 2>/dev/null | sed 's/Commit: //')"
  PREV_TAG=$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]' | sed -n '2p')
  PREV_DOONA=$(git show "$PREV_TAG":luci-app-honk/Makefile 2>/dev/null | sed -n 's/^PKG_SOURCE:=//p' | head -1)
  PREV_SRC=$(git show "$PREV_TAG":honk/Makefile 2>/dev/null | sed -n 's/^HONK_SOURCE_TAG?=//p' | head -1)
  printf '        the previous release: %s (%s)\n' "$PREV_TAG" "$PREV_DOONA"
  if [ -n "$PREV_DOONA" ] && [ "$PREV_DOONA" != "$NEW_DOONA" ]; then
    if [ ! -f "$TREE/dl/$PREV_DOONA" ]; then
      timeout 600 curl -fsSL --max-time 600 "https://github.com/kenzok8/openwrt-honk/releases/download/$PREV_SRC/$PREV_DOONA" -o "$WORK/$PREV_DOONA" 2>/dev/null \
        && echo "        (the previous archive was fetched)"
    fi
    if [ -f "$WORK/$PREV_DOONA" ] || [ -f "$TREE/dl/$PREV_DOONA" ]; then
      SRC="$WORK/$PREV_DOONA"; [ -f "$TREE/dl/$PREV_DOONA" ] && SRC="$TREE/dl/$PREV_DOONA"
      rm -rf "$WORK/doona-old" && mkdir -p "$WORK/doona-old"
      tar -xzf "$SRC" -C "$WORK/doona-old" 2>/dev/null
      CH=$(diff -rq "$WORK/doona-old/doona/assets" "$WORK/doona/doona/assets" 2>/dev/null | wc -l)
      if [ "$CH" = "0" ]; then ok "the panel code is unchanged (a republish only)"; else warn "$CH panel assets changed -> read the upstream notes"; fi
    else
      warn "could not get the previous panel archive for the diff"
    fi
  else
    ok "the panel archive is the same as the previous release"
  fi
else
  warn "the doona archive is not in dl/ yet"
fi

head_ "10) the built artifacts"
IMGDIR="$TREE/bin/targets/rockchip/armv8"
if [ -d "$IMGDIR" ]; then
  ( cd "$IMGDIR" && sha256sum -c sha256sums >/dev/null 2>&1 ) && ok "the image sha256sums are good" || bad "the image sha256sums do not match"
  for img in "$IMGDIR"/*-sysupgrade.img.gz; do [ -f "$img" ] && printf '        %10d  %s\n' "$(stat -c %s "$img")" "$(basename "$img")"; done
  MAN="$IMGDIR"/*.manifest
  for pkg in "honk" "luci-app-honk"; do
    v=$(grep -E "^$pkg " $MAN 2>/dev/null | awk '{print $3}')
    if [ "$pkg" = "honk" ]; then want="$OUR_VER-r$(sed -n 's/^PKG_RELEASE:=//p' "$TREE/package/honk/Makefile" | head -1)"; else want="$OUR_LUCI-r$(sed -n 's/^PKG_RELEASE:=//p' "$TREE/package/luci-app-honk/Makefile" | head -1)"; fi
    if [ "$v" = "$want" ]; then ok "the manifest: $pkg $v"; else bad "the manifest: $pkg $v (expected $want)"; fi
  done
  KD="$TREE/build_dir/target-aarch64_generic_musl/linux-rockchip_armv8"
  if [ -f "$KD/vmlinux.elf" ]; then
    readelf -S "$KD/vmlinux.elf" 2>/dev/null | grep -q '\.BTF' && ok "the kernel still has the BTF section" || bad "the kernel lost its BTF section"
  fi
  for f in /usr/share/honk/geodata.sh /usr/share/honk/control.sh; do
    if find "$TREE/build_dir/target-aarch64_generic_musl" -path "*$f" 2>/dev/null | head -1 | grep -q .; then ok "the image carries $f"; else bad "the image is missing $f"; fi
  done
else
  warn "no built images yet (bin/targets/rockchip/armv8)"
fi

head_ "the verdict"
printf '  the failures: %d   the warnings: %d\n' "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31mVERDICT: FAIL\033[0m -- do not flash, fix the failures above\n'
  exit 1
elif [ "$WARN" -gt 0 ]; then
  printf '  \033[33mVERDICT: PASS with warnings\033[0m -- look at the warnings before flashing\n'
  exit 2
else
  printf '  \033[32mVERDICT: PASS\033[0m -- the update is clean\n'
  exit 0
fi
