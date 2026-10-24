#!/usr/bin/env bash
# ============================================================================
#  Steam Deck / SteamOS —— 桌面模式(Plasma / KWin Wayland)中文输入法一键安装
# ============================================================================
#
#  目标:让 **桌面会话** 里的原生 Wayland 应用(kate / konsole / Dolphin /
#  Plasma 搜索框)和 XWayland 应用都能正常打中文。
#
#  核心思路(和"装个 fcitx5 包"完全不同的三条):
#
#  1) 整套 fcitx5 装在 /home,而不是 pacman 的 /usr
#     SteamOS 是 A/B 双分区原子更新,/usr 在系统镜像分区上,
#     手动 cp 进去的或 pacman 装的东西下一次更新会被整块抹掉。
#     /home 是独立分区,永远保留 —— 所以宿主安装放在 ~/.local/share/fcitx5-host。
#     装的是 SteamOS 自带 extra 源里的官方 Arch 包(与本机 glibc/Qt 同版本,
#     ABI 天然兼容),不是 flatpak 版(flatpak 的 Qt 插件要 Qt 6.11)。
#
#  2) 原生 Wayland 应用要靠 KWin 的 --inputmethod= 桥
#     KWin 通过 `--inputmethod=<desktop 文件>` 启动一个 launcher,
#     它在 WAYLAND_SOCKET 上接管 zwp_text_input_v2/v3 协议。
#     没有它,原生 Wayland 应用**永远**打不出中文,跟 daemon 在不在跑无关。
#
#  3) daemon 必须带 --keep --replace,并且禁用 ibusfrontend
#     --keep    : 显示连接被抢走时不自杀(否则 "Connection removed" → 退出,
#                 而 Restart=no 没人拉回来 —— "修好几天一直修不好"的根源)
#     --replace: 已有实例时接管,而不是直接退出
#     --disable=ibusfrontend : fcitx5 的 ibusfrontend 会用
#                 RequestNameFlag::DoNotQueue|ReplaceExisting 抢 org.freedesktop.IBus,
#                 Valve 掌机模式的 ibus-daemon 抢不回来 → 掌机模式 OSK 没中文。
#                 ⚠️ 必须走**命令行**;配置文件里的 DisabledAddons= 走"配置"通道,不生效。
#                 判据:journal 里出现 "Override Disabled Addons: {ibusfrontend}"。
#
#  用法:
#     ./install-desktop-ime.sh              # 安装
#     ./install-desktop-ime.sh --reinstall  # 重新构建 fcitx5 宿主安装(会覆盖)
#
#  装完必须 **注销重登**(或重启):KWin 的 --inputmethod= 只在 KWin 启动时生效。
#  详见 docs/desktop-mode.md
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$HOME/.local/share/fcitx5-host"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

REINSTALL=0
[ "${1:-}" = "--reinstall" ] && REINSTALL=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 前置检查
say "0/8 前置检查"
[ "$(uname -s)" = "Linux" ] || die "只支持 Linux"
if [ ! -d "$HOST_DIR" ] || [ "$REINSTALL" = "1" ]; then
    say "   构建 fcitx5 宿主安装(从 SteamOS 官方源解包,不碰 /usr)"
    "$REPO_DIR/lib/fcitx5-build-host" || die "构建失败"
else
    ok "宿主安装已存在:$HOST_DIR"
fi
[ -x "$HOST_DIR/bin/fcitx5" ] || die "宿主安装不完整"

# ---------------------------------------------------------------- 1. 包装器
say "1/8 安装包装器到 ~/.local/bin"
mkdir -p "$BIN_DIR"
for f in fcitx5 fcitx5-remote fcitx5-diagnose fcitx5-start fcitx5-wayland-launcher \
         fcitx5-dbus-activate fcitx5-configtool fcitx5-ensure-installed; do
    install -m 0755 "$REPO_DIR/lib/$f" "$BIN_DIR/$f"
done
ok "8 个包装器就位(它们负责把库/addon/词典路径指到 ~/.local/share/fcitx5-host)"

# ---------------------------------------------------------------- 2. fcitx5 配置
say "2/8 安装 fcitx5 配置(~/.config/fcitx5)"
mkdir -p "$HOME/.config/fcitx5"
install -m 0644 "$REPO_DIR/config/fcitx5-config" "$HOME/.config/fcitx5/config"
install -m 0644 "$REPO_DIR/config/fcitx5-profile" "$HOME/.config/fcitx5/profile"
ok "config + profile 就位"
warn "改 profile 必须在 daemon **停止**时进行:daemon 退出时用内存里的分组覆写 profile"

# ---------------------------------------------------------------- 3. systemd 单元
say "3/8 安装 systemd 用户单元"
mkdir -p "$UNIT_DIR"
install -m 0644 "$REPO_DIR/systemd/fcitx5.service" "$UNIT_DIR/fcitx5.service"
ok "fcitx5.service(Restart=always + --replace --keep --disable=ibusfrontend)"

# ---------------------------------------------------------------- 4. KWin 桥接
say "4/8 安装 KWin 的 --inputmethod= 桥接"
mkdir -p "$UNIT_DIR/plasma-kwin_wayland.service.d"
install -m 0644 "$REPO_DIR/systemd/plasma-kwin_wayland.inputmethod.conf" \
              "$UNIT_DIR/plasma-kwin_wayland.service.d/inputmethod.conf"

# 启动器的 desktop 文件:KWin 的 InputMethod 设置指向它
LAUNCHER_DESKTOP="$HOME/.local/share/applications/fcitx5-wayland-launcher.desktop"
mkdir -p "$(dirname "$LAUNCHER_DESKTOP")"
cat > "$LAUNCHER_DESKTOP" <<EOF
[Desktop Entry]
Name=Fcitx 5 Wayland Launcher
GenericName=Input Method
Comment=Start the Fcitx 5 Wayland input method launcher
Exec=$BIN_DIR/fcitx5-wayland-launcher --reopen
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
NoDisplay=true
OnlyShowIn=KDE
X-KDE-StartupNotify=false
X-KDE-Wayland-VirtualKeyboard=true
X-KDE-Wayland-Interfaces=org_kde_plasma_window_management
EOF

# kwinrc:InputMethod[$e]=<desktop 文件路径>
#   ⚠️ KConfig 不会展开 ~,必须写绝对路径
KWINRC="$HOME/.config/kwinrc"
mkdir -p "$HOME/.config"
touch "$KWINRC"
# 删掉旧的 InputMethod 条目再写新的(键名在文件里是转义形式 InputMethod\x5b$e\x5d)
sed -i '/^InputMethod\\x5b\$e\\x5d=/d' "$KWINRC"
printf 'InputMethod\\x5b$e\\x5d=%s\n' "$LAUNCHER_DESKTOP" >> "$KWINRC"
ok "drop-in + desktop 文件 + kwinrc 条目就位"

# ---------------------------------------------------------------- 5. flatpak 应用
say "5/8 修 flatpak 应用的输入法(Chromium/Electron 在 X11 下走 GTK IM 模块)"
# ★ 2026-10-24:本仓库把 fcitx5 装在 ~/.local/share/fcitx5-host/,必须导出
#   GTK_IM_MODULE_FILE=~/.local/share/fcitx5-host/share/gtk-3.0/immodules.cache
#   给宿主上的 GTK3 用。但这个变量会**原样传进 flatpak 沙箱**,而该路径在沙箱里
#   不存在 → 沙箱里的 GTK3 读不到 cache → 加载不到 im-fcitx5.so → 没有输入法。
#   而当代 Chromium 在 X11 下**已经没有 XIM 了**,只剩 GTK IM 模块这一条路。
#   修法:把沙箱里的 GTK_IM_MODULE_FILE 改指 runtime 自带的 cache。
if command -v flatpak >/dev/null 2>&1; then
    "$REPO_DIR/scripts/fix-flatpak-ime.sh" --apply >/dev/null 2>&1 \
        && ok "flatpak override 已更新(QQ / Chrome / WeChat 等)" \
        || warn "flatpak override 没改成,手动跑 scripts/fix-flatpak-ime.sh --apply"
    warn "**必须重启 flatpak 应用**才生效(环境变量是启动时注入的)"
else
    warn "没装 flatpak,跳过"
fi

# ---------------------------------------------------------------- 6. D-Bus 激活
say "6/8 安装 D-Bus 激活文件"
mkdir -p "$HOME/.local/share/dbus-1/services"
cat > "$HOME/.local/share/dbus-1/services/org.fcitx.Fcitx5.service" <<EOF
[D-BUS Service]
Name=org.fcitx.Fcitx5
Exec=$BIN_DIR/fcitx5-dbus-activate
EOF
ok "org.fcitx.Fcitx5.service(优先级高于 flatpak 导出的那份,避免拉起 flatpak 版)"

# ---------------------------------------------------------------- 6. 启用
say "7/8 启用并重启"
systemctl --user daemon-reload
systemctl --user enable fcitx5.service >/dev/null 2>&1 || true
systemctl --user restart fcitx5.service

# 有界等待:最多 15 次 × 1 秒,条件满足就立刻退出(不写裸 sleep-retry 循环)
i=0
while [ "$i" -lt 15 ]; do
    systemctl --user is-active --quiet fcitx5.service && break
    i=$((i + 1)); sleep 1
done
if [ "$i" -ge 15 ]; then
    warn "15 秒内 daemon 没起来,日志:"
    journalctl --user -u fcitx5.service -n 30 --no-pager || true
    die "启动失败"
fi
ok "fcitx5.service active"

# ---------------------------------------------------------------- 7. 收尾
say "8/8 收尾"
if journalctl --user -u fcitx5.service --since "-2 min" --no-pager 2>/dev/null \
   | grep -q "Override Disabled Addons: {ibusfrontend}"; then
    ok "ibusfrontend 已被禁用(命令行通道生效)"
else
    warn "没看到 'Override Disabled Addons: {ibusfrontend}' —— 检查 fcitx5.service 的 ExecStart"
fi

echo
echo "════════════════════════════════════════════════════════════"
echo " 安装完成。**必须注销重登**(或重启):"
echo "   · KWin 的 --inputmethod= 只在 KWin 启动时接管 zwp_text_input_v3"
echo "   · 原生 Wayland 应用(kate/konsole/Dolphin)在重登前仍然打不出中文"
echo "════════════════════════════════════════════════════════════"
echo
echo "重登后自检:   $REPO_DIR/scripts/check-ime.sh"
echo "出问题看:     journalctl --user -u fcitx5.service -n 50"
