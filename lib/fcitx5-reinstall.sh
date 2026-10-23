#!/bin/bash
# fcitx5 一键修复/自检脚本(用户态,不需要 sudo)
#
# ── 设计原则(踩过的坑都在这) ────────────────────────────────────────────
# 1. **绝不并发跑第二个 daemon**。旧版 verify() 会
#    `setsid timeout 8 /usr/bin/fcitx5 -d --enable=all` 去抢 Wayland/DBus 连接,
#    老 daemon 发现连接被抢 + 没有 --keep → "Connection removed" → 自杀,
#    而 autostart 单元 Restart=no 没人拉回来。
#    → 结果:每手动跑一次这个脚本,就毁掉一个本来能用的输入法。
#    现在 daemon 由 systemd 用户单元托管(Restart=always + --replace --keep),
#    这个脚本只做「检查 + 重启 + 校验」。
#
# 2. **绝不重启 plasma-kwin_wayland**。SteamOS 桌面模式下 kwin 是嵌套在
#    gamescope 里的合成器,单独 restart 它会带走 wayland-0 socket → 整个桌面崩掉。
#    kwin 的启动参数改了也只能靠「注销重登」生效。
#
# 3. **改 profile 必须 stop → 写 → start**。daemon 退出(SIGTERM)时会用内存里
#    的分组覆写 ~/.config/fcitx5/profile,运行中改文件会被抹掉。
#
# 4. **不用固定版本号做检测**。整套装在 ~/.local/share/fcitx5-host/,
#    检测文件存在即可;A/B 更新不会动 /home。
#
# 完整背景见记忆 steamos-fcitx5-wayland-input-method。

set -euo pipefail

HOST="$HOME/.local/share/fcitx5-host"
LAUNCHER="$HOME/.local/bin/fcitx5-wayland-launcher"
DROPIN="$HOME/.config/systemd/user/plasma-kwin_wayland.service.d/inputmethod.conf"
KWINRC="$HOME/.config/kwinrc"
PROFILE="$HOME/.config/fcitx5/profile"
WANT_DESKTOP="$HOME/.local/share/applications/fcitx5-wayland-launcher.desktop"

echo "==> [1/6] 检查用户态安装(~/.local/share/fcitx5-host)"
# ensure-installed 的退出码有含义:
#   0 = 完整   2 = 已自动修复(从 SteamOS 源重建成功)   1 = 修不了
# 用 || 捕获,别让 set -e 把"自动修复过"当成失败。
ensure_rc=0
"$HOME/.local/bin/fcitx5-ensure-installed" || ensure_rc=$?
case "$ensure_rc" in
    0) echo "  ✓ 安装完整" ;;
    2) echo "  ✓ 检测到缺失,已自动重建" ;;
    *) echo "  ✗ 自动重建失败,先解决这个再往下走"; exit 1 ;;
esac

echo
echo "==> [2/6] 检查 KWin 的 Wayland 输入法桥接"
# 这一步是原生 Wayland 应用(kate/konsole/Dolphin/Plasma 搜索框)能不能打中文的
# 关键。之前的 drop-in 指向 /usr/lib/fcitx5-wayland-launcher —— 那个文件根本不存在,
# 于是 zwp_text_input_v2/v3 协议没人接管,原生应用从来就没打对过中文。
if [ ! -f "$DROPIN" ]; then
    echo "  ✗ 缺少 systemd drop-in:$DROPIN"
    exit 1
fi
if ! grep -q -- "--inputmethod=$LAUNCHER" "$DROPIN"; then
    echo "  ✗ drop-in 里的 --inputmethod 不是 $LAUNCHER"
    exit 1
fi
if [ ! -x "$LAUNCHER" ]; then
    echo "  ✗ 启动器不存在或不可执行:$LAUNCHER"
    exit 1
fi
echo "  ✓ drop-in → $LAUNCHER(存在且可执行)"
if ! grep -q "inputmethod=$LAUNCHER" "$DROPIN"; then
    echo "  ! 注意:drop-in 只在 KWin **下次启动** 时生效,当前会话需要注销重登"
fi
# kwinrc 是另一条路径(KDE 的 virtual keyboard 机制),两者都指向存在的文件即可
if [ ! -f "$WANT_DESKTOP" ]; then
    echo "  ✗ 缺少 $WANT_DESKTOP"
    exit 1
fi
echo "  ✓ kwinrc desktop 文件存在:$WANT_DESKTOP"

echo
echo "==> [3/6] 修 profile(必须在 daemon 停止时写)"
# daemon 在跑的时候写 profile 会被它退出时的内存状态覆写掉。
# 所以:停 → 写 → 起。
profile_has_pinyin() {
    grep -qE '^Name=pinyin$' "$PROFILE" 2>/dev/null
}
if profile_has_pinyin; then
    echo "  ✓ profile 里已有 pinyin"
else
    echo "  ! profile 里没有 pinyin,重写"
    systemctl --user stop fcitx5.service || true
    mkdir -p "$(dirname "$PROFILE")"
    cat > "$PROFILE" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=pinyin

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=pinyin
# Layout
Layout=

[GroupOrder]
0=Default
EOF
    systemctl --user start fcitx5.service
fi

echo
echo "==> [4/6] 重载并重启守护进程"
systemctl --user daemon-reload
systemctl --user restart fcitx5.service

# 有界等待:最多 10 次 × 1 秒,条件满足就立刻退出。
# (不写裸的 sleep-retry 循环 —— 必须有明确的退出条件和上限。)
wait_active=0
while [ "$wait_active" -lt 10 ]; do
    if systemctl --user is-active --quiet fcitx5.service; then
        break
    fi
    wait_active=$((wait_active + 1))
    sleep 1
done
if [ "$wait_active" -ge 10 ]; then
    echo "  ✗ 等了 10 秒 daemon 还没 active,放弃(不再重试)"
    journalctl --user -u fcitx5.service -n 30 --no-pager || true
    exit 1
fi
echo "  ✓ daemon 已 active"

echo
echo "==> [5/6] 校验"
STATE=$(systemctl --user is-active fcitx5.service 2>/dev/null || echo inactive)
echo "  systemd 单元: $STATE"

OWNER=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.fcitx.Fcitx5 2>&1 || true)
echo "  总线名 org.fcitx.Fcitx5 归属: $OWNER"

CUR=$(gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
      --method org.fcitx.Fcitx.Controller1.CurrentInputMethod 2>&1 || true)
echo "  当前输入法(CurrentInputMethod): $CUR"
echo "  组内当前 IM(fcitx5-remote -n): $("$HOME/.local/bin/fcitx5-remote" -n 2>&1 || echo '(未运行)')"
echo "  激活状态: $("$HOME/.local/bin/fcitx5-remote" 2>&1 || echo '(未运行)')  (2=中文 1=英文 0=未激活)"
# ⚠️ 陷阱:CurrentInputMethod 报的是「当前有焦点的输入上下文」用的 IM。
# 如果跑脚本时没有窗口持有焦点(比如从纯终端执行),它会返回 keyboard-us,
# 这**不代表 pinyin 没生效**。真正看状态用 fcitx5-remote -n 和下面的分组信息。
GROUP=$(gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.FullInputMethodGroupInfo Default 2>&1 || true)
echo "  Default 分组: ${GROUP:0:120}"

LAUNCHER_PIDS=$(pgrep -f 'fcitx5-host/libexec/fcitx5-wayland-launcher' | tr '\n' ' ' || true)
if [ -n "$LAUNCHER_PIDS" ]; then
    echo "  ✓ Wayland 输入法启动器在跑 (pid: $LAUNCHER_PIDS)"
else
    echo "  ! Wayland 启动器没在跑 —— 需要注销重登,让 KWin 用新的 --inputmethod= 启动"
fi

echo
echo "==> [6/6] pinyin 是否可用"
if gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
        --method org.fcitx.Fcitx.Controller1.AvailableInputMethods 2>/dev/null | grep -q "'pinyin'"; then
    echo "  ✓ pinyin 在 AvailableInputMethods 里"
else
    echo "  ✗ 查不到 pinyin —— 看 journalctl --user -u fcitx5.service -n 50"
fi

# 组内当前 IM 是不是 pinyin(这才是"能不能直接打中文"的真状态)
if [ "$("$HOME/.local/bin/fcitx5-remote" -n 2>/dev/null || true)" = "pinyin" ]; then
    echo "  ✓ 组内当前 IM = pinyin,新聚焦的窗口会直接进拼音"
else
    echo "  ! 组内当前 IM 不是 pinyin —— 需要在有焦点的窗口里按一次 Ctrl+Space,"
    echo "    或者跑:gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \\"
    echo "      --method org.fcitx.Fcitx.Controller1.SetCurrentIM pinyin"
fi

echo
echo "  注:daemon 刚重启,持有焦点的旧窗口的输入上下文已经失效,"
echo "      在那个窗口里再点一下输入框(或切走再切回)就会重新接管。"

if [ "$STATE" != "active" ]; then
    echo
    echo "守护进程没起来,最近的日志:"
    journalctl --user -u fcitx5.service -n 30 --no-pager || true
    exit 1
fi

echo
echo "✅ 完成。想看完整诊断报告可以运行: fcitx5-diagnose"
