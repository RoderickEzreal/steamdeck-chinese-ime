#!/usr/bin/env bash
# ============================================================================
#  Steam Deck / SteamOS —— 掌机模式(游戏会话)中文输入法一键安装
# ============================================================================
#
#  目标:让 Steam 的屏幕键盘(OSK)能打出中文,物理键盘打进 OSK 也能出候选。
#
#  链路(和桌面模式的 fcitx5 **完全独立**):
#
#    游戏里 Steam+X → OSK 弹出
#      → OSK 是 IBus 客户端(在 pressure-vessel 容器里)
#      → org.freedesktop.portal.IBus → org.freedesktop.IBus
#      → Valve 的 ibus-daemon(ibus-gamescope.service)持有总线名,带 pinyin 引擎
#      → 选中引擎 → commit → SteamClient.Input.ControllerKeyboardSendText
#      → gamescope 私有 gamescope_input_method 协议 → src/ime.cpp type_text()
#
#  gamescope 没有实现 zwp_text_input_manager_v3(上游 PR #2259 至今未合),
#  所以 fcitx5 在游戏里**不可能**接管输入法 —— 游戏内中文只有 OSK+IBus 这一条路。
#
#  ★ 本脚本要修的核心 bug(2026-10-24 定位):
#
#    本机(以及部分 SteamOS 镜像)缺 ibus 包自带的 /etc/dconf/profile/ibus。
#    /usr/lib/ibus/ibus-dconf 启动时 g_setenv("DCONF_PROFILE","ibus"),
#    而 dconf 找不到具名 profile 文件时会退回 **null profile**(0 个数据源):
#        dconf_engine_open_profile_file():
#            g_warning("unable to open named profile (%s): using the null configuration.");
#        dconf_engine_is_writable_internal():
#            if (engine->n_sources == 0) return FALSE;
#    ⇒ /desktop/ibus/** 全部变成 non-writable,ibus 配置既读不出也写不进。
#
#    Steam 切换到拼音布局时代码是:
#        await Promise.all(一批 set_value 写操作);      ← 这里直接 reject
#        await set_global_engine("pinyin");              ← 永远不会执行
#    引擎停在 xkb:us::eng,打字只有拉丁字母、**没有任何中文候选**。
#    (实体键盘也不行 —— 因为全局引擎压根没换过。)
#
#    修法:把同名 profile 文件放到 **用户可写**的路径里。
#    dconf 找具名 profile 的顺序 = SYSCONFDIR(/etc/dconf/profile) 优先,再 XDG_DATA_DIRS。
#    /etc 在只读镜像分区,A/B 更新必丢;XDG_DATA_DIRS 里唯一用户可写的是
#    flatpak 导出目录,而它在 /home 上 —— A/B 更新不丢。
#
#  用法:./install-gaming-ime.sh
#  装完:切到掌机模式,Steam+X 开 OSK,左下角地球键切"简体中文(拼音)"
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. dconf profile "ibus"
# ---------------------------------------------------------------------------
say "1/5 安装 dconf 的具名 profile 'ibus'(核心修复)"

# 找 XDG_DATA_DIRS 里第一个位于 $HOME 下、且可写的目录;
# 找不到就用 flatpak 导出目录(SteamOS 上它总是在 XDG_DATA_DIRS 第一位)。
PROFILE_DIR=""
IFS=':' read -r -a _dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${_dirs[@]}"; do
    case "$d" in
        "$HOME"/*)
            mkdir -p "$d/dconf/profile" 2>/dev/null || true
            if [ -w "$d/dconf/profile" ]; then PROFILE_DIR="$d/dconf/profile"; break; fi
            ;;
    esac
done
[ -n "$PROFILE_DIR" ] || PROFILE_DIR="$HOME/.local/share/flatpak/exports/share/dconf/profile"

PROFILE_FILE="$PROFILE_DIR/ibus"
mkdir -p "$PROFILE_DIR"
printf 'user-db:user\nsystem-db:ibus\n' > "$PROFILE_FILE"
ok "$PROFILE_FILE"
ok "内容:$(tr '\n' ' ' < "$PROFILE_FILE")"

if [ -f /etc/dconf/profile/ibus ]; then
    ok "/etc/dconf/profile/ibus 也存在(优先级更高,内容一致,无害)"
else
    warn "/etc/dconf/profile/ibus 不存在(ibus 包被裁剪过)—— 这正是本 bug 的成因;"
    warn "  dconf 会打印 'unable to open file /etc/dconf/db/ibus ... degraded performance',无害。"
    warn "  想恢复上游原样需 sudo 写 /etc/dconf/profile/ibus + /etc/dconf/db/ibus.d/,"
    warn "  但 /etc 在 A/B 镜像分区上,更新后照样丢 —— 用户级这份才是持久的。"
fi

# ---------------------------------------------------------------------------
# 2. 自愈 guard
# ---------------------------------------------------------------------------
say "2/5 安装自愈 guard(profile 文件被误删时自动补回)"
install -m 0755 "$REPO_DIR/scripts/ensure-ibus-dconf-profile.sh" \
              "$HOME/.local/bin/ensure-ibus-dconf-profile.sh"
install -m 0644 "$REPO_DIR/systemd/ensure-ibus-dconf-profile.service" \
              "$UNIT_DIR/ensure-ibus-dconf-profile.service"
systemctl --user daemon-reload
systemctl --user enable --now ensure-ibus-dconf-profile.service >/dev/null
ok "ensure-ibus-dconf-profile.service 已启用(Before=ibus-gamescope.service)"

# ---------------------------------------------------------------------------
# 3. 启动竞态:IBus 守护进程必须排在 Steam 客户端前面
# ---------------------------------------------------------------------------
say "3/5 消除 Steam 客户端 / IBus 守护进程的启动竞态"
mkdir -p "$UNIT_DIR/ibus-gamescope.service.d"
install -m 0644 "$REPO_DIR/systemd/ibus-gamescope.override.conf" \
              "$UNIT_DIR/ibus-gamescope.service.d/override.conf"
systemctl --user daemon-reload
ok "Before=steam-launcher.service(ibus-gamescope 是 Type=dbus,拿到总线名才算启动完)"

# ---------------------------------------------------------------------------
# 4. 抢占总线名的两个元凶
# ---------------------------------------------------------------------------
say "4/5 排除总线名抢占"
# 4a. 用户级 ibus-daemon.service:ExecStart 用 -d 会 daemonize,
#     systemd 跟的主进程 17ms 就退 0,真正的 daemon 变孤儿;
#     且它 WantedBy=default.target,比 Valve 的 ibus-gamescope 早 2 秒启动。
if systemctl --user is-enabled --quiet ibus-daemon.service 2>/dev/null; then
    systemctl --user disable ibus-daemon.service
    ok "ibus-daemon.service 已禁用"
else
    ok "ibus-daemon.service 本来就是禁用的"
fi

# 4b. fcitx5 的 ibusfrontend:用 ReplaceExisting|DoNotQueue 抢 org.freedesktop.IBus,
#     而它只实现 CreateInputContext(GetEnginesByNames 返回空数组、
#     SetGlobalEngine 直接 UnknownMethod)→ OSK 报 "Keyboard_IME_Not_available"。
if [ -f "$UNIT_DIR/fcitx5.service" ]; then
    if grep -q -- "--disable=ibusfrontend" "$UNIT_DIR/fcitx5.service"; then
        ok "fcitx5.service 已带 --disable=ibusfrontend"
    else
        warn "fcitx5.service 里没有 --disable=ibusfrontend —— 掌机模式 OSK 会没有中文"
        warn "  修法:ExecStart 改成 ... --replace --keep --disable=ibusfrontend"
    fi
else
    warn "没有 fcitx5.service(纯游戏机正常);若桌面模式也用 fcitx5,记得加 --disable=ibusfrontend"
fi

# ---------------------------------------------------------------------------
# 5. 收尾
# ---------------------------------------------------------------------------
say "5/5 收尾"
echo
echo "════════════════════════════════════════════════════════════"
echo " 安装完成。切到掌机模式实测:"
echo "   1. Steam+X 打开屏幕键盘"
echo "   2. 左下角**地球键**切到「简体中文(拼音)」"
echo "   3. 打几个字母 —— 应该出现候选(你/那/呢/能/年...)"
echo "   4. 实体键盘打进 OSK 也应该出候选"
echo
echo " 自检: $REPO_DIR/scripts/check-ime.sh"
echo "════════════════════════════════════════════════════════════"
