#!/usr/bin/env bash
# ============================================================================
#  SteamOS 中文输入法双模式自检
#
#    ./check-ime.sh              # 只看状态
#    ./check-ime.sh --probe      # 再跑一次 Steam 客户端内的真实调用(最准)
#
#  判据分两组:
#    A. 掌机模式(OSK + IBus)—— 决定游戏里有没有中文
#    B. 桌面模式(fcitx5)     —— 决定桌面能不能打中文
#  两组必须都过。
# ============================================================================
set -uo pipefail

ok=0; bad=0
say() { printf '  %-34s %s\n' "$1" "$2"; }
chk() {
    if [ "$2" = "ok" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok+1));
    else printf '  \033[31m✗\033[0m %s\n' "$1"; bad=$((bad+1)); fi
}

# ===========================================================================
echo "═══ A. 掌机模式(Steam OSK + IBus)═══"
# ===========================================================================
echo
echo "── A1. dconf 的具名 profile 'ibus' ──"
# ★ 最关键的一条。ibus-dconf 设 DCONF_PROFILE=ibus,dconf 找不到这个 profile
#   文件就会退回 null profile(0 数据源)⇒ /desktop/ibus/** 全部 non-writable
#   ⇒ Steam 切拼音时 Promise.all 中断 ⇒ set_global_engine 不执行 ⇒ 没有中文候选。
PROFILE_FOUND=""
for d in $(printf '%s' "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" | tr ':' ' '); do
    [ -f "$d/dconf/profile/ibus" ] && { PROFILE_FOUND="$d/dconf/profile/ibus"; break; }
done
[ -f /etc/dconf/profile/ibus ] && [ -z "$PROFILE_FOUND" ] && PROFILE_FOUND="/etc/dconf/profile/ibus"
if [ -n "$PROFILE_FOUND" ]; then
    chk "找到 dconf profile 'ibus'" ok
    say "路径" "$PROFILE_FOUND"
    if grep -qx 'user-db:user' "$PROFILE_FOUND"; then
        chk "profile 含 user-db:user(可写的数据源)" ok
    else
        chk "profile 含 user-db:user(可写的数据源)" bad
    fi
else
    chk "找到 dconf profile 'ibus'" bad
    say "" "→ dconf 会退回 null profile,所有 ibus 配置写入都会失败"
    say "" "→ 修法:./install/install-gaming-ime.sh"
fi

echo
echo "── A2. 谁占着 org.freedesktop.IBus ──"
# 不能用 `awk ... exit`(会 SIGPIPE 掉 busctl,输出会丢),读完整段再取 PID
status_out=$(busctl --user status org.freedesktop.IBus 2>&1)
owner_pid=$(printf '%s\n' "$status_out" | sed -n 's/^PID=\([0-9][0-9]*\).*/\1/p')
if [ -z "$owner_pid" ]; then
    say "总线名" "当前无人占用(桌面模式正常;掌机模式由 ibus-gamescope.service 接管)"
else
    owner_cmd=$(tr '\0' ' ' < "/proc/$owner_pid/cmdline" 2>/dev/null)
    say "PID" "$owner_pid"
    say "命令" "$owner_cmd"
    case "$owner_cmd" in
        *ibus-daemon*) chk "占用者是真正的 ibus-daemon" ok ;;
        *fcitx5*)      chk "占用者是真正的 ibus-daemon" bad
                      say "" "fcitx5 的 ibusfrontend 抢了这个名字 → OSK 会没有中文"
                      say "" "→ 加 --disable=ibusfrontend(命令行通道!)" ;;
        *)             say "" "占用者不是 ibus-daemon,自己看" ;;
    esac
fi

echo
echo "── A3. IBus 守护进程与中文引擎 ──"
for u in ibus-gamescope.service ibus-daemon.service; do
    say "$u" "$(systemctl --user is-active "$u" 2>/dev/null || true)"
done
if systemctl --user is-active --quiet ibus-gamescope.service; then
    chk "Valve 的 ibus-gamescope 在跑" ok
else
    say "ibus-gamescope" "没在跑(桌面模式正常;掌机模式会自动起)"
fi
if systemctl --user is-enabled --quiet ibus-daemon.service 2>/dev/null; then
    chk "用户级 ibus-daemon.service 保持禁用" bad
    say "" "→ 它会跟 Valve 的抢总线名;systemctl --user disable ibus-daemon.service"
else
    chk "用户级 ibus-daemon.service 保持禁用" ok
fi

# ⚠️ 不要用 `ibus list-engine`:它靠 ~/.config/ibus/bus/ 下的地址文件找 daemon,
#    systemd 拉起的 daemon 不写那个文件 → 永远 "Can't connect to IBus"。
#    权威的引擎检查是 scripts/verify-steam-osk.mjs(走 Steam 自己的绑定)。
#    这里只做静态检查:引擎二进制在不在 + 有没有被加载。
if ls /usr/lib/ibus/ibus-engine-pinyin >/dev/null 2>&1; then
    chk "ibus 的中文引擎(pinyin)已安装" ok
else
    chk "ibus 的中文引擎(pinyin)已安装" bad
    say "" "→ 装 ibus-pinyin 包"
fi
loaded=$(pgrep -f 'ibus-engine-(pinyin|bopomofo|table)' 2>/dev/null | wc -l)
say "已加载的引擎进程" "$loaded 个(客户端激活过才会 spawn)"

# 引擎配置能不能写(★ 真正的判据:null profile 下全部 non-writable)
if command -v dconf >/dev/null 2>&1; then
    probe_key="/desktop/ibus/engine/pinyin/__probe__"
    if DCONF_PROFILE=ibus dconf write "$probe_key" true >/dev/null 2>&1; then
        chk "ibus 配置可写(dconf profile 正常)" ok
        dconf reset -f "$probe_key" >/dev/null 2>&1 || true
    else
        chk "ibus 配置可写(dconf profile 正常)" bad
        say "" "→ dconf 退回 null profile 了,所有 ibus 配置写入都会失败"
        say "" "→ 跑 ./install/install-gaming-ime.sh"
    fi
fi

echo
echo "── A4. 启动竞态与 guard ──"
if systemctl --user show ibus-gamescope.service -p Before 2>/dev/null | grep -q steam-launcher; then
    chk "ibus-gamescope 排在 steam-launcher 之前" ok
else
    chk "ibus-gamescope 排在 steam-launcher 之前" bad
    say "" "→ 否则 Steam 起来时引擎还没就绪,OSK 整个会话都是 Keyboard_IME_Not_available"
fi
if systemctl --user is-enabled --quiet ensure-ibus-dconf-profile.service 2>/dev/null; then
    chk "dconf profile 自愈 guard 已启用" ok
else
    chk "dconf profile 自愈 guard 已启用" bad
    say "" "→ systemctl --user enable --now ensure-ibus-dconf-profile.service"
fi

# ===========================================================================
echo
echo "═══ B. 桌面模式(fcitx5 + KWin Wayland 桥)═══"
# ===========================================================================
if systemctl --user is-active --quiet fcitx5.service; then
    echo
    echo "── B1. fcitx5 daemon ──"
    grp=$(gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
            --method org.fcitx.Fcitx.Controller1.FullInputMethodGroupInfo Default 2>/dev/null)
    case "$grp" in
        *pinyin*) chk "Default 分组当前 IM 是 pinyin" ok ;;
        *)        chk "Default 分组当前 IM 是 pinyin" bad; say "分组信息" "${grp:0:110}" ;;
    esac
    if gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
         --method org.fcitx.Fcitx.Controller1.AvailableInputMethods 2>/dev/null | grep -q pinyin; then
        chk "AvailableInputMethods 里有 pinyin" ok
    else
        chk "AvailableInputMethods 里有 pinyin" bad
    fi
    if pgrep -f 'fcitx5-wayland-launcher' >/dev/null 2>&1; then
        chk "KWin 的 --inputmethod= 桥在跑" ok
    else
        chk "KWin 的 --inputmethod= 桥在跑" bad
        say "" "→ 原生 Wayland 应用(kate/konsole/Dolphin)打不出中文"
        say "" "→ drop-in 只在 KWin **下次启动**时生效 → 需要注销重登"
    fi
    # 看**最近一次启动**的 Override 行(不要用 --since,时间窗口容易踩空)
    last_override=$(journalctl --user -u fcitx5.service --no-pager -n 2000 2>/dev/null \
                    | grep "Override Disabled Addons" | tail -1)
    say "最近一次启动" "${last_override#*Override Disabled Addons: }"
    case "$last_override" in
        *ibusfrontend*) chk "ibusfrontend 已被禁用(命令行通道生效)" ok ;;
        *) chk "ibusfrontend 已被禁用(命令行通道生效)" bad
           say "" "→ ExecStart 要带 --disable=ibusfrontend(配置文件里的 DisabledAddons= 不生效)" ;;
    esac
    if [ -x "$HOME/.local/share/fcitx5-host/bin/fcitx5" ]; then
        chk "fcitx5 宿主安装在 /home(A/B 免疫)" ok
    else
        chk "fcitx5 宿主安装在 /home(A/B 免疫)" bad
        say "" "→ fcitx5-ensure-installed(会自动从 SteamOS 源重建)"
    fi
else
    echo
    echo "── B. 桌面模式:fcitx5.service 没在跑(纯游戏会话正常)──"
fi

# ===========================================================================
echo "═══ C. flatpak 应用(Chromium/Electron 在 X11 下走 GTK IM 模块)═══"
# ===========================================================================
#  ★ 2026-10-24:Chromium 已经没有 XIM 了(XMODIFIERS/XOpenIM 计数为 0),
#    X11 下只走 GTK3 的 IM 模块。而本仓库为了免 sudo 装 fcitx5,导出了
#    GTK_IM_MODULE_FILE=~/.local/share/fcitx5-host/...  ← 这个路径在沙箱里不存在
#    → 沙箱里的 GTK3 读不到 cache → flatpak 应用一点输入法都没有。
#    判据:fcitx5-diagnose 里 flatpak 应用应出现 frontend:dbus(或 wayland)。
echo
if ! command -v flatpak >/dev/null 2>&1; then
    say "flatpak" "没装,跳过"
else
    RUNTIME_CACHE="/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache"

    # 宿主的 GTK_IM_MODULE_FILE 必须指向宿主自己那份(改了会弄坏宿主 GTK 应用)
    HOST_CACHE="$(grep -rhoE 'GTK_IM_MODULE_FILE=.*' \
        "$HOME/.config/environment.d" "$HOME/.config/plasma-workspace/env" 2>/dev/null \
        | head -1 | cut -d= -f2-)"
    if [ -n "$HOST_CACHE" ] && [ -e "$HOST_CACHE" ]; then
        chk "宿主 GTK_IM_MODULE_FILE 指向存在的文件" ok
        say "路径" "$HOST_CACHE"
    else
        chk "宿主 GTK_IM_MODULE_FILE 指向存在的文件" bad
        say "路径" "${HOST_CACHE:-<没设>}"
    fi

    # 沙箱里的必须指向 runtime 自带的那份
    G=$(flatpak override --user --show 2>/dev/null | grep '^GTK_IM_MODULE_FILE=' | cut -d= -f2-)
    if [ "$G" = "$RUNTIME_CACHE" ]; then
        chk "沙箱 GTK_IM_MODULE_FILE 指向 runtime cache" ok
    else
        chk "沙箱 GTK_IM_MODULE_FILE 指向 runtime cache" bad
        say "当前" "${G:-<没设>}"
        say "" "→ flatpak 应用(QQ/Chrome/WeChat)会没有输入法"
        say "" "→ 修法:./scripts/fix-flatpak-ime.sh --apply"
    fi

    # 已安装的 flatpak 应用里,哪些在 fcitx5 里有输入上下文
    DIAG="$HOME/.local/share/fcitx5-host/bin/fcitx5-diagnose"
    [ -x "$DIAG" ] || DIAG="$(command -v fcitx5-diagnose 2>/dev/null)"
    if [ -n "$DIAG" ] && [ -x "$DIAG" ]; then
        n_flatpak_fb=$("$DIAG" 2>/dev/null | grep -oE 'frontend:(dbus|wayland|xim)' | wc -l)
        if [ "$n_flatpak_fb" -gt 0 ]; then
            chk "fcitx5 里有输入上下文" ok
            "$DIAG" 2>/dev/null | grep -E '^\s+IC ' | \
                sed -E 's/.*program:([^ ]*) frontend:([a-z]+).*/\1 → \2/' | sort -u | \
                while read -r app fe; do say "$app" "$fe"; done
        else
            chk "fcitx5 里有输入上下文" bad
        fi
    fi
fi

# ===========================================================================
if [ "${1:-}" = "--probe" ]; then
    echo
    echo "═══ D. Steam 客户端内部真实调用(最准)═══"
    if command -v node >/dev/null 2>&1; then
        node "$(dirname "$0")/verify-steam-osk.mjs" 2>&1 | sed 's/^/  /'
    else
        say "node" "不存在,跳过"
    fi
    echo
    echo "  (需要 Steam 客户端带 --remote-debugging-port=8080 启动)"
fi

echo
echo "════════════════════════════════════"
printf "结果: \033[32m%d 项通过\033[0m, " "$ok"
if [ "$bad" -gt 0 ]; then printf "\033[31m%d 项失败\033[0m\n" "$bad"; else echo "0 项失败"; fi
echo "════════════════════════════════════"
[ "$bad" -eq 0 ] || echo "→ 失败项的上面都写了对应修法,详见 docs/troubleshooting.md"
exit $(( bad > 0 ? 1 : 0 ))
