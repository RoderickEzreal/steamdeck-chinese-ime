#!/usr/bin/env bash
# ============================================================================
#  flatpak 应用的 fcitx5 中文输入修复
#
#    ./fix-flatpak-ime.sh            # 只看状态(不改任何东西)
#    ./fix-flatpak-ime.sh --apply    # 应用修复
#    ./fix-flatpak-ime.sh --apply com.qq.QQ com.tencent.WeChat
#
#  ── 背景(2026-10-24 定位)────────────────────────────────────────────
#  当代 Chromium / Electron 在 **X11 下已经没有 XIM 了**
#  (二进制里 XMODIFIERS / XOpenIM / XCreateIC 计数全是 0),
#  只剩 **GTK3 的 IM 模块** 这条路:
#
#      GTK3 → im-fcitx5.so → libFcitx5GClient → org.freedesktop.portal.Fcitx → fcitx5
#
#  而本仓库把 fcitx5 装在 ~/.local/share/fcitx5-host/(免 sudo、A/B 免疫),
#  必须让 GTK3 读自己那份 immodules.cache,于是导出了:
#
#      GTK_IM_MODULE_FILE=/home/deck/.local/share/fcitx5-host/share/gtk-3.0/immodules.cache
#
#  这个变量会**原样传进 flatpak 沙箱**,但该路径在沙箱里不存在
#  → 沙箱里的 GTK3 读不到 cache → 加载不到 im-fcitx5.so → 完全没有输入法。
#  (宿主上一切正常,所以极易误判成"flatpak 隔离的锅")
#
#  修法:把沙箱里的 GTK_IM_MODULE_FILE 改指到 **各 runtime 自带**的 cache。
# ============================================================================
set -uo pipefail

APPLY=0
APPS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) APPS+=("$1"); shift ;;
    esac
done

say()  { printf '  %-46s %s\n' "$1" "${2:-}"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
head2(){ printf '\n\033[1;34m── %s ──\033[0m\n' "$*"; }

# runtime 自带的 cache(各 runtime 路径一致;org.freedesktop.Sdk / org.kde.Platform 都有)
# 沙箱里看到的路径(= runtime 的 files/ 目录 + 去掉 /usr 前缀)
RUNTIME_CACHE="/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache"
RUNTIME_CACHE_REL="lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache"

# 需要"只走 X11"的应用:它们的 wrapper 在"X11 socket 空 + 有 WAYLAND_DISPLAY"时
# 会改用 xvfb-run 起虚拟显示 :99,窗口和 fcitx5(在 :0)就对不上了。
X11_ONLY_APPS=(com.qq.QQ)

command -v flatpak >/dev/null 2>&1 || die "没装 flatpak"

# ---------------------------------------------------------------------------
head2 "1. 宿主环境变量"
# ---------------------------------------------------------------------------
HOST_CACHE="$(grep -rhoE 'GTK_IM_MODULE_FILE=.*' \
    "$HOME/.config/environment.d" "$HOME/.config/plasma-workspace/env" 2>/dev/null \
    | head -1 | cut -d= -f2-)"
say "宿主 GTK_IM_MODULE_FILE" "${HOST_CACHE:-<没设>}"
if [ -n "$HOST_CACHE" ] && [ ! -e "$HOST_CACHE" ]; then
    bad "指向的路径在宿主上都不存在 —— fcitx5 装歪了"
else
    ok "宿主路径存在"
fi
warn "这个变量会原样传进 flatpak 沙箱 → 沙箱里 GTK3 读不到它 = 没有输入法"

# ---------------------------------------------------------------------------
head2 "2. 各 runtime 自带的 cache"
# ---------------------------------------------------------------------------
n_ok=0
for r in /var/lib/flatpak/runtime/*/x86_64/*/*/files; do
    [ -d "$r" ] || continue
    p="$r/$RUNTIME_CACHE_REL"
    [ -f "$p" ] || continue
    n_ok=$((n_ok+1))
    rname=$(echo "$r" | sed -E 's|.*/runtime/([^/]+)/.*|\1|')
    if grep -q fcitx "$p"; then
        say "$rname" "✓ 含 fcitx 记录"
    else
        say "$rname" "! 没有 fcitx 记录"
    fi
done
[ "$n_ok" -gt 0 ] && ok "$n_ok 个 runtime 带 $RUNTIME_CACHE" \
                 || bad "没有任何 runtime 带这个 cache"

# ---------------------------------------------------------------------------
head2 "3. 当前 override"
# ---------------------------------------------------------------------------
cur_global="$(flatpak override --user --show 2>/dev/null)"
say "全局 GTK_IM_MODULE_FILE" \
    "$(printf '%s' "$cur_global" | grep '^GTK_IM_MODULE_FILE=' | cut -d= -f2- || echo '<没设>')"

for a in "${X11_ONLY_APPS[@]}"; do
    cur="$(flatpak override --user --show "$a" 2>/dev/null)"
    say "$a GTK_IM_MODULE_FILE" \
        "$(printf '%s' "$cur" | grep '^GTK_IM_MODULE_FILE=' | cut -d= -f2- || echo '<没设>')"
    say "$a sockets" \
        "$(printf '%s' "$cur" | grep '^sockets=' | cut -d= -f2- || echo '<没设>')"
done

# ---------------------------------------------------------------------------
head2 "4. 应用修复"
# ---------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
    echo "  (只读模式。加 --apply 才会真的改 override)"
else
    # 全局:所有 flatpak 都改指 runtime 自带的 cache
    flatpak override --user --env=GTK_IM_MODULE_FILE="$RUNTIME_CACHE" \
        && ok "全局 override 已更新"

    # 需要 x11-only 的应用:额外拿掉 wayland socket
    for a in "${X11_ONLY_APPS[@]}"; do
        flatpak override --user --socket=x11 --nosocket=wayland \
            --env=GTK_IM_MODULE_FILE="$RUNTIME_CACHE" "$a" \
            && ok "$a override 已更新(只走 X11)"
        # QQ 的 wrapper 会读这两处 qq-flags.conf
        if [ "$a" = "com.qq.QQ" ]; then
            mkdir -p "$HOME/.var/app/$a/config"
            printf -- '--ozone-platform=x11\n' > "$HOME/.var/app/$a/config/qq-flags.conf"
            printf -- '--ozone-platform=x11\n' > "$HOME/.config/qq-flags.conf"
            ok "qq-flags.conf 已写好(X11 ozone,防 xvfb-run)"
        fi
    done
    echo
    warn "环境变量是启动时注入的 → **必须重启这些应用**才生效"
fi

# ---------------------------------------------------------------------------
head2 "5. 验证:fcitx5 里的输入上下文"
# ---------------------------------------------------------------------------
DIAG="$HOME/.local/share/fcitx5-host/bin/fcitx5-diagnose"
if [ ! -x "$DIAG" ]; then DIAG="$(command -v fcitx5-diagnose 2>/dev/null)"; fi
if [ -z "$DIAG" ] || [ ! -x "$DIAG" ]; then
    warn "找不到 fcitx5-diagnose,跳过"
else
    "$DIAG" 2>/dev/null | grep -E '^\s+IC ' | \
        sed -E 's/.*program:([^ ]*) frontend:([a-z]+).*/\1 → \2/' | sort | uniq -c | \
        while read -r cnt app fe; do say "$app" "$fe  ($cnt 个上下文)"; done
    echo
    say "判据" "flatpak 应用应出现 frontend:dbus(X11+GTK IM 模块)"
    say "" "frontend:wayland = 走原生 Wayland 协议"
    say "" "frontend:xim    = X11 XIM(Chromium 已不走这条)"
    say "" "压根没出现       = 那条链没建起来"
fi

echo
echo "  深入说明:docs/flatpak-apps.md"
