# v1.0.0 — 首个正式版

> 日期:2026-10-24
> 适用范围:SteamOS 3.x(Steam Deck),桌面模式(Plasma/KWin Wayland)+ 掌机模式(游戏会话)

---

## 这个版本解决什么

Steam Deck 的中文输入在**两个互不相干的模式**里各有一套栈,两边都有一批"看起来像玄学"的故障:

- **桌面模式**:fcitx5 装进 `/usr` → A/B 更新后归零;flatpak 版 Qt 插件版本对不上;
  KWin 没桥接 → 原生 Wayland 应用永远打不出中文;daemon 缺 `--keep` → 断连就自杀没人拉回来。
- **掌机模式**:★ **缺 `/etc/dconf/profile/ibus`**,导致 dconf 退回 null profile,
  所有 ibus 配置写入被判 non-writable,Steam 切换到拼音布局时 `Promise.all` 中断,
  `set_global_engine("pinyin")` 永不执行 —— 软键盘和实体键盘都只有拉丁字母、没有中文候选。

v1.0.0 把两边的**修法、诊断脚本和现场踩坑记录**一起发布出来。

---

## 新增

### 掌机模式(核心)

- `install/install-gaming-ime.sh` —— 一键安装
  - 写入 `~/.local/share/flatpak/exports/share/dconf/profile/ibus`
    (内容 `user-db:user` + `system-db:ibus`,与上游 `ibus` 包一致)
  - 安装并启用 `ensure-ibus-dconf-profile.service` 自愈 guard
  - 安装 `ibus-gamescope.service.d/override.conf`(`Before=steam-launcher.service`)
  - 禁用会抢总线名的用户级 `ibus-daemon.service`
  - 检查 `fcitx5.service` 是否带 `--disable=ibusfrontend`
- `scripts/ensure-ibus-dconf-profile.sh` —— 幂等重建 profile 文件
- `systemd/ensure-ibus-dconf-profile.service` —— `Before=ibus-gamescope.service`,
  `WantedBy=gamescope-session.target`
- `systemd/ibus-gamescope.override.conf` —— 消除 Steam 客户端 / IBus 守护进程的启动竞态

### 桌面模式

- `install/install-desktop-ime.sh` —— 一键安装
  - 从 SteamOS 官方 extra 源解包 fcitx5 到 `~/.local/share/fcitx5-host`(不碰 `/usr`、不用 sudo)
  - 安装 8 个包装器到 `~/.local/bin`
  - 安装 `~/.config/fcitx5/config` + `profile`
  - 安装 `fcitx5.service`(`Restart=always` + `--replace --keep --disable=ibusfrontend`)
  - 安装 KWin 的 `--inputmethod=` 桥接(drop-in + desktop 文件 + kwinrc 条目)
  - 安装 D-Bus 激活文件(优先级高于 flatpak 导出的那份)
- `lib/` —— fcitx5 的全部包装器与宿主构建脚本

### 诊断

- `scripts/check-ime.sh` —— 双模式自检(13 项判据),`--probe` 会再跑一次 Steam 客户端内的真实调用
- `scripts/verify-steam-osk.mjs` —— 在 Steam 客户端(CFF DevTools)里完整复刻
  Steam 切布局的那段逻辑,并真的敲一个键,验证 preedit 和候选列表

### 文档

- `README.md` —— 总览 + 快速开始 + 根因详解 + 弯路记录(中英双语摘要)
- `docs/desktop-mode.md` —— 桌面模式 5 个根因 + 9 个陷阱
- `docs/gaming-mode.md` —— 掌机模式链路、根因、诊断工具坑
- `docs/troubleshooting.md` —— 症状 → 原因 → 修法 对照表

---

## 关键结论(值得单独拎出来)

1. **SteamOS 上不要往 `/usr`、`/opt`、`/bin` 里装东西** —— 那是 A/B 镜像分区,
   更新时整块抹掉。所有自建的二进制和配置放 `/home`。

2. **原生 Wayland 应用的中文靠 KWin 的 `--inputmethod=` 桥**,
   跟 daemon 状态无关。bridge 指向的 launcher 不存在时,现象是
   "daemon 好好的但就是打不出中文"。

3. **fcitx5 的 `ibusfrontend` 必须用命令行 `--disable` 禁用**。
   配置文件里的 `DisabledAddons=` 走"配置"通道,不生效;
   判据是 journal 里的 `Override Disabled Addons: {ibusfrontend}`。

4. **★ dconf 的具名 profile 找不到时会退回 null profile(0 数据源)**,
   此时该 profile 下**所有键都是 non-writable**。
   内置的 `user-db:user` 默认 profile **只在没指定 profile 名时才用**。
   `ibus-dconf` 永远设 `DCONF_PROFILE=ibus`,所以缺
   `/etc/dconf/profile/ibus` 的机器上,ibus 的配置读写全线失效。

5. **Steam 切布局是 `await Promise.all(writes)` 然后才 `set_global_engine`**。
   前一步失败 → 后一步永不执行 → 引擎停在 `xkb:us::eng`。
   这解释了"软键盘没候选、实体键盘也没候选"。

6. **`gamescope` 没实现 `zwp_text_input_manager_v3`**,
   所以 fcitx5 在游戏里不可能接管输入法 —— 游戏内中文只有 OSK + IBus 一条路。

7. **诊断顺序很重要**:先量准"失败发生在哪一步",再找原因。
   本例里决定性的一步是复刻 `Promise.all` 并观察它到底 reject 没有 ——
   在那之前关于"引擎 / 总线名 / addon"的所有猜测都是徒劳。

---

## 验证结果(本机实测)

```
$ ./scripts/check-ime.sh
13 项通过, 0 项失败

$ node scripts/verify-steam-osk.mjs
引擎表: pinyin / bopomofo / table:cangjie5 / table:quick5 均可用
引擎配置写入: 全部 OK
Promise.all 是否 reject : 否
set_global_engine       : OK
输入 "n" → preedit "你",候选 ["你","那","呢","能","年"]
```

---

## 兼容性

- SteamOS 3.8(本机验证)
- 桌面模式需要 Plasma / KWin Wayland;KDE 6 的 `--inputmethod=` 机制
- 掌机模式依赖 Valve 的 `ibus-gamescope.service`
  (若上游改名,drop-in 里的 `Before=` 会指向不存在的单元 —— systemd 只忽略并给一行警告)
- 不需要 sudo;不改系统镜像分区

---

## License

MIT
