#!/usr/bin/env bash
# 保证 dconf 的具名 profile "ibus" 存在。
#
# 为什么需要(完整根因见记忆文件 steamos-gaming-mode-chinese-ime.md):
#   ibus 的 /etc/dconf/profile/ibus 在本机缺失(SteamOS 打包问题,
#   `pacman -Qkk ibus` 会报 "/etc/dconf/profile/ibus (没有那个文件或目录)")。
#   /usr/lib/ibus/ibus-dconf 启动时 g_setenv("DCONF_PROFILE", "ibus"),
#   而 dconf 找不到具名 profile 文件时会退回 **null profile**(0 个数据源),
#   于是 dconf_engine_is_writable_internal() 恒为 FALSE ——
#   /desktop/ibus/** 全部变成 non-writable,ibus 配置既读不出来也写不进去。
#   掌机模式里 Steam 屏幕键盘切到拼音布局时,第一步就是写这批配置,
#   写失败 → Promise.all 中断 → set_global_engine("pinyin") 永不执行 →
#   引擎停在 xkb:us::eng → 打字只有拉丁字母、没有中文候选。
#
# 为什么放在 ~/.local/share/flatpak/exports/share:
#   dconf 找具名 profile 的顺序是 SYSCONFDIR(/etc/dconf/profile) 优先,
#   然后才是 XDG_DATA_DIRS。/etc 在只读镜像分区上,A/B 更新后必丢;
#   XDG_DATA_DIRS 里唯一用户可写的就是这个 flatpak 导出目录,而它本身
#   在 /home 上,A/B 更新不丢。掌机会话的 gamescope-environment 里
#   XDG_DATA_DIRS 的第一项正是它,所以掌机模式同样能找到。
#
# 幂等:文件已存在且内容正确就直接退出。
set -euo pipefail

target="$HOME/.local/share/flatpak/exports/share/dconf/profile/ibus"

if [ -f "$target" ] && grep -qx 'user-db:user' "$target" && grep -qx 'system-db:ibus' "$target"; then
    exit 0
fi

mkdir -p "$(dirname "$target")"
printf 'user-db:user\nsystem-db:ibus\n' > "$target"
echo "ensure-ibus-dconf-profile: 已重建 $target"
