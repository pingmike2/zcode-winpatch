#!/usr/bin/env bash
# patch.sh — 给 magpie 的 zcode 插件做客户端环境对齐（Windows 基线）
#
# 背景：zcode.z.ai 的 Start Plan 通道校验 OS 指纹，Linux 下的
#   X-Platform: linux-x64 / X-Os-Category: linux
# 会被判为异常请求，回 405 code 3012（账号级风控冷却，换 IP 无效）。
# 本脚本把插件里的平台值改写成 Windows 11 的真值。
#
# 用法：
#   ./patch.sh            # 自动定位插件目录并打补丁
#   ./patch.sh --path DIR # 指定插件目录
#   ./patch.sh --dry-run  # 只检查，不写
#   ./patch.sh --verify   # 只验证当前是否已打补丁
#
# 幂等：重复执行不会重复改；插件升级后重跑即可恢复。
set -euo pipefail

PLUGIN_DIR=""
DRY_RUN=0
VERIFY_ONLY=0

# Windows 11 的指纹值
WIN_PLATFORM="win32"
WIN_ARCH="x64"
WIN_RELEASE="10.0.22631"
WIN_LOCALE="zh-CN"
WIN_TZ="Asia/Shanghai"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

# 打补丁和重启服务都需要 root；--verify 不需要
NEED_ROOT=1
for a in "$@"; do
  case "$a" in --verify) NEED_ROOT=0 ;; esac
done
if [ "$NEED_ROOT" = "1" ] && [ "$(id -u)" -ne 0 ]; then
  die "需要 root 权限（重启 magpie-web 服务、写入插件目录）。请用 sudo 运行"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --path)
      [ $# -ge 2 ] || die "--path 需要一个目录参数"
      [ -n "${2:-}" ] || die "--path 的值不能为空"
      PLUGIN_DIR="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --verify)   VERIFY_ONLY=1; shift ;;
    -h|--help)  usage ;;
    *)          die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

# ---------- 定位插件 ----------
if [ -z "$PLUGIN_DIR" ]; then
  CANDIDATES=(
    "$HOME/.config/magpie/plugins/node_modules/@magpie-community/opencode-zcode-auth"
    "$HOME/.local/share/magpie/plugins/node_modules/@magpie-community/opencode-zcode-auth"
    "$HOME/.magpie/plugins/node_modules/@magpie-community/opencode-zcode-auth"
  )
  for c in "${CANDIDATES[@]}"; do
    if [ -f "$c/index.mjs" ]; then PLUGIN_DIR="$c"; break; fi
  done
fi

[ -n "$PLUGIN_DIR" ] || die "找不到 zcode 插件。先装：magpie plugin add zcode，或用 --path 指定目录"

# 目录必须是真实存在的目录；解析成绝对路径，消除 ../ 一类输入
[ -d "$PLUGIN_DIR" ] || die "目录不存在: $PLUGIN_DIR"
PLUGIN_DIR=$(cd "$PLUGIN_DIR" && pwd -P)

# 边界校验：--path 必须落在 magpie 的插件目录里，防止误改任意文件
if [ "$VERIFY_ONLY" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  case "$PLUGIN_DIR" in
    "$HOME/.config/magpie/plugins/"*|"$HOME/.local/share/magpie/plugins/"*|"$HOME/.magpie/plugins/"*)
      : ;;
    *)
      [ "${ALLOW_ANY_PATH:-0}" = "1" ] || die "拒绝操作：$PLUGIN_DIR 不在 magpie 插件目录内（确实要改请设 ALLOW_ANY_PATH=1）"
      ;;
  esac
fi

MAIN="$PLUGIN_DIR/index.mjs"
[ -f "$MAIN" ] || die "找不到 $MAIN"
[ -L "$MAIN" ] && die "index.mjs 是软链接，拒绝操作: $MAIN"

echo "[*] 插件目录: $PLUGIN_DIR"

# ---------- 验证模式 ----------
if [ "$VERIFY_ONLY" = "1" ]; then
  if grep -q 'WSBASE' "$MAIN"; then
    echo "[OK] 已打补丁"
    grep -n 'WSBASE' "$MAIN" | head -5
    exit 0
  else
    echo "[NO] 未打补丁（仍是原始 Linux 指纹）"
    exit 1
  fi
fi

# ---------- 备份（-p 保留权限；用 noclobber 原子创建，闭合 TOCTOU） ----------
BACKUP="$MAIN.orig"
# noclobber 让重定向在目标已存在时直接失败，避免 check-then-copy 的竞态
if ( set -o noclobber; cat "$MAIN" > "$BACKUP" ) 2>/dev/null; then
  chmod --reference="$MAIN" "$BACKUP" 2>/dev/null || true
  echo "[*] 备份原始文件 -> index.mjs.orig"
elif [ -L "$BACKUP" ]; then
  die "$BACKUP 是软链接，拒绝使用"
else
  echo "[*] 已有备份 index.mjs.orig，跳过"
fi

# ---------- 失败回滚 ----------
ROLLED_BACK=0
rollback() {
  [ "$ROLLED_BACK" = "1" ] && return 0
  ROLLED_BACK=1
  if [ -f "$BACKUP" ]; then
    cp -p "$BACKUP" "$MAIN"
    echo "[!] 已回滚到备份" >&2
  fi
}
trap 'rollback' EXIT

# ---------- 打补丁（python，先写临时文件再原子替换） ----------
PATCH_PY=$(cat <<'PYEOF'
import os, sys, re, tempfile

path   = sys.argv[1]
dry    = sys.argv[2] == "1"
plat, arch, rel  = sys.argv[3], sys.argv[4], sys.argv[5]
locale, tz       = sys.argv[6], sys.argv[7]

with open(path, encoding="utf-8") as f:
    src = f.read()

changes = []

# 1) 注入 WSBASE 常量 + 改写 platform()
if "WSBASE" not in src:
    old = 'const platform = () => `${process.platform}-${process.arch}`'
    new = ('const WSBASE = { platform: "%s", arch: "%s", release: "%s" }\n'
           'const platform = () => `${WSBASE.platform}-${WSBASE.arch}`') % (plat, arch, rel)
    if old in src:
        src = src.replace(old, new, 1)
        changes.append("platform() -> %s-%s" % (plat, arch))

# 2) osVersion()
old = 'const osVersion = () => `${process.platform} ${release()} ${arch()}`'
new = 'const osVersion = () => `${WSBASE.platform} ${WSBASE.release} ${WSBASE.arch}`'
if old in src:
    src = src.replace(old, new, 1)
    changes.append("osVersion() -> windows")

# 3) osCategory()
old = 'const osCategory = () => (process.platform === "darwin" ? "macos" : process.platform === "win32" ? "windows" : "linux")'
new = 'const osCategory = () => "windows"'
if old in src:
    src = src.replace(old, new, 1)
    changes.append("osCategory() -> windows")

# 4) X-Os-Version header
old = 'out.set("X-Os-Version", release())'
new = 'out.set("X-Os-Version", WSBASE.release)'
if old in src:
    src = src.replace(old, new, 1)
    changes.append('X-Os-Version -> win release')

# 5) intl() 时区/语言
m = re.search(
    r'function intl\(\) \{\s*try \{\s*return Intl\.DateTimeFormat\(\)\.resolvedOptions\(\)\s*\} catch \{\s*return \{\}\s*\}\s*\}',
    src)
if m:
    src = src[:m.start()] + (
        'function intl() {\n'
        '  return { locale: "%s", timeZone: "%s" }\n'
        '}' % (locale, tz)
    ) + src[m.end():]
    changes.append("intl() -> %s / %s" % (locale, tz))

if not changes:
    print("[=] 无需改动（补丁已存在或插件结构已变）")
    sys.exit(0)

print("[*] 改动:")
for c in changes:
    print("    -", c)

if dry:
    print("[dry-run] 未写入")
    sys.exit(0)

# 原子写入：同目录临时文件 + os.replace
d = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=d, prefix=".index.mjs.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(src)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)

print("[OK] 写入完成（原子替换）")
PYEOF
)

python3 -c "$PATCH_PY" "$MAIN" "$DRY_RUN" \
  "$WIN_PLATFORM" "$WIN_ARCH" "$WIN_RELEASE" "$WIN_LOCALE" "$WIN_TZ"

# ---------- 语法检查（失败即回滚） ----------
if command -v node >/dev/null 2>&1; then
  if node --check "$MAIN" 2>/dev/null; then
    echo "[OK] 语法检查通过"
  else
    echo "[ERR] 语法检查失败" >&2
    rollback
    exit 1
  fi
else
  echo "[!] 未找到 node，跳过语法检查"
fi

# ---------- 重启服务（失败即回滚） ----------
if [ "$DRY_RUN" = "0" ]; then
  if systemctl is-active --quiet magpie-web 2>/dev/null; then
    if ! systemctl restart magpie-web; then
      echo "[ERR] magpie-web 重启失败" >&2
      rollback
      exit 1
    fi
    sleep 6
    if systemctl is-active --quiet magpie-web; then
      echo "[OK] magpie-web 已重启"
    else
      echo "[ERR] magpie-web 重启后未存活" >&2
      rollback
      systemctl restart magpie-web 2>/dev/null || true
      exit 1
    fi
  else
    echo "[*] magpie-web 未运行，跳过重启"
  fi
fi

ROLLED_BACK=1  # 成功，禁用回滚

echo
echo "完成。验证: ./patch.sh --verify"
trap - EXIT
