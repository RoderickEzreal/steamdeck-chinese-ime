# Steam Deck 中文输入法修复工具箱

> 桌面模式(Plasma / KWin Wayland)和掌机模式(游戏会话 / Steam OSK)的中文输入,
> 两条完全独立的链路,各有各的坑。这个仓库把两边的修法、诊断脚本和踩坑记录整理在一起。

[![tag](https://img.shields.io/badge/tag-v1.0.0-blue)](./)
[![license](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

---

## TL;DR

| | 桌面模式 | 掌机模式(游戏会话) |
|---|---|---|
| 输入法栈 | **fcitx5**(装在 `~/.local/share/fcitx5-host`) | **Steam OSK + IBus**(Valve 的 `ibus-gamescope.service`) |
| 关键机制 | KWin 的 `--inputmethod=` 接管 `zwp_text_input_v3` | Steam 客户端的 `IBus` 绑定 + `set_global_engine` |
| 本仓库修的坑 | ① 装进 `/usr` → A/B 更新全丢<br>② 装进 flatpak → Qt 插件版本对不上<br>③ KWin 没桥接 → 原生 Wayland 应用永远打不出中文<br>④ daemon 没 `--keep` → 一断连就自杀,没人拉回来 | ★ **缺 `/etc/dconf/profile/ibus` → dconf 退回 null profile → 所有 ibus 配置写入被判 non-writable → Steam 切拼音时 `Promise.all` 中断 → `set_global_engine` 永不执行 → 没有中文候选** |
| 一键安装 | `install/install-desktop-ime.sh` | `install/install-gaming-ime.sh` |

**两边的修法互不干扰,可以同时装。**

---

## 快速开始

```bash
git clone https://github.com/RoderickEzreal/steamdeck-chinese-ime.git
cd steamdeck-chinese-ime

# 桌面模式(Plasma / KWin Wayland)
./install/install-desktop-ime.sh

# 掌机模式(游戏会话 / Steam OSK)
./install/install-gaming-ime.sh

# 自检
./scripts/check-ime.sh
./scripts/check-ime.sh --probe    # 再跑一次 Steam 客户端内的真实调用
```

> 桌面模式装完**必须注销重登**:KWin 的 `--inputmethod=` 只在 KWin 启动时接管协议。

---

## 为什么桌面模式不能靠 pacman / flatpak

SteamOS 是 A/B 双分区原子更新:

- `/usr`、`/opt`、`/bin` 在**系统镜像分区**上。手动 `cp` 进去的、或 `pacman -i` 装的,
  下一次系统更新会被**整块抹掉**。这就是"修好几天又坏了"的经典循环。
- `/home` 是**独立用户分区**,永远保留。

所以整套 fcitx5 装在 `~/.local/share/fcitx5-host/`,而且装的是
**SteamOS 自带 extra 源里的官方 Arch 包**(与本机 glibc / Qt 同版本,ABI 天然兼容),
不是 flatpak 版(flatpak 的 Qt 插件要 Qt 6.11,本机只有 6.9)。

`lib/fcitx5-build-host` 做的就是这件事:`pacman -Sp` 拿包 URL → 缓存到
`~/.cache/pkgcache` → 解包 → 铺到 `~/.local/share/fcitx5-host`,全程不碰 `/usr`、不用 sudo。

---

## ★ 掌机模式的根因(2026-10-24 定位,最有价值的一段)

### 症状

- Steam 屏幕键盘(OSK)弹出后,按字母**没有中文候选**
- 实体键盘打进 OSK **也没有中文候选**
- 但桌面模式一切正常

### 链路

```
游戏里 Steam+X → OSK 弹出
  → OSK 是 IBus 客户端(在 pressure-vessel 容器里)
  → org.freedesktop.portal.IBus → org.freedesktop.IBus
  → Valve 的 ibus-daemon(ibus-gamescope.service)持有总线名,带 pinyin 引擎
  → 选中引擎 → commit → SteamClient.Input.ControllerKeyboardSendText
  → gamescope 私有 gamescope_input_method 协议 → src/ime.cpp type_text()
```

`gamescope` 没有实现 `zwp_text_input_manager_v3`(上游 PR #2259 至今未合),
所以 **fcitx5 在游戏里不可能接管输入法**。游戏内中文只有 OSK + IBus 这一条路。

### Steam 客户端切布局时做了什么

Steam UI(CEF 的 `sp.js`)里,切换到"简体中文(拼音)"的动作是:

```js
await Promise.all(M);                            // 先写一批引擎配置
await E.GetBus().set_global_engine(k.engineName); // 再切全局引擎
```

**`Promise.all` 里任何一个写失败,整个函数中止,`set_global_engine` 永远不执行。**
引擎停在 `xkb:us::eng` → 打字只有拉丁字母、**没有任何中文候选**。
(实体键盘也不行 —— 因为全局引擎压根没换过。)

### 为什么写会失败

本机(以及部分 SteamOS 镜像)**缺 ibus 包自带的 `/etc/dconf/profile/ibus`**:

```console
$ pacman -Qkk ibus
警告:ibus: /etc/dconf/profile/ibus (没有那个文件或目录)
```

而 `/usr/lib/ibus/ibus-dconf` 启动时调 `g_setenv("DCONF_PROFILE", "ibus", FALSE)`,
所以它**永远用具名 profile "ibus"**。dconf 0.40.0 的源码:

```c
// dconf-engine.c —— 找不到具名 profile 文件时:
g_warning("unable to open named profile (%s): using the null configuration.");
sources = dconf_engine_null_profile (n_sources);   // ← 0 个数据源

// dconf-engine.c
static gboolean
dconf_engine_is_writable_internal (DConfEngine *engine)
{
  if (engine->n_sources == 0)                       // ← 恒为 FALSE
    return FALSE;
  ...
}
```

⇒ null profile 下 **`/desktop/ibus/**` 每一个键都是 non-writable**,
写入报 `The operation attempted to modify one or more non-writable keys`
(`DCONF_ERROR_NOT_WRITABLE`, code 2),读取返回 `NULL`。
ibus 连自己的 general 设置(`dconf-preserve-name-prefixes`、`embed-preedit-text`、
`use-global-engine`)都读不出来。

### 修法

把同名 profile 文件放到**用户可写**的路径:

```
~/.local/share/flatpak/exports/share/dconf/profile/ibus
```

内容与上游 `ibus` 包里的完全一致:

```
user-db:user
system-db:ibus
```

为什么是这个位置:dconf 找具名 profile 的顺序是
**SYSCONFDIR(`/etc/dconf/profile`)优先,再 XDG_DATA_DIRS**。

- `/etc` 在只读镜像分区 → A/B 更新必丢
- XDG_DATA_DIRS 里唯一用户可写的,是 flatpak 导出目录,而它在 `/home` → A/B 更新不丢
- 掌机会话的 `/run/user/1000/gamescope-environment` 里
  `XDG_DATA_DIRS=/home/deck/.local/share/flatpak/exports/share:...`
  —— **第一项就是它**,所以掌机模式同样找得到

再配一个自愈单元,保证文件被误删时自动补回:

```
~/.config/systemd/user/ensure-ibus-dconf-profile.service
  [Unit] Before=ibus-gamescope.service
  [Install] WantedBy=gamescope-session.target
```

### 验证

`scripts/verify-steam-osk.mjs` 在 Steam 客户端内部(CEF DevTools)完整复刻上面那两步,
并真的敲一个键看候选:

```
引擎表 (get_engines_by_names):
   ✓ pinyin           1 个
   ✓ bopomofo         1 个
   ✓ table:cangjie5   1 个
   ✓ table:quick5     1 个

引擎配置写入 (Steam 切布局时做的第一批事):
   pinyin/InitChinese = OK
   ... (全部 OK)

Promise.all 是否 reject : ✓ 否
set_global_engine       : OK
输入 "n" → preedit  : "你"
候选                    : ["你","那","呢","能","年"]
```

---

## 走过的弯路(留个反面教材)

| 曾经的假设 | 为什么错 |
|---|---|
| "fcitx5 的 ibusfrontend 抢了 `org.freedesktop.IBus`,所以 OSK 没中文" | **实测禁用它之后症状依旧**。它确实会抢名字(`ReplaceExisting\|DoNotQueue`),而且只实现 `CreateInputContext`(`GetEnginesByNames` 返回空数组)—— 这条**保留**为预防措施,但不是根因 |
| "ibus-pinyin 缺 gschema,所以键是 non-writable" | 自己手写 `org.freedesktop.ibus.engine.pinyin.gschema.xml` 时 **glib-compile-schemas 拒绝 CamelCase 键名**(键名必须 snake_case),这批 schema 编译不过,纯属废品。真正的键名保持原样(`InitChinese`、`LookupTablePageSize`…),由 ibus 自己的 `dconf-preserve-name-prefixes` 规则保证不被改名 |
| "`ibus list-engine` 看不到引擎,说明引擎没装" | `ibus` CLI 靠 `~/.config/ibus/bus/` 下的地址文件找 daemon,systemd 拉起的 daemon 不写那个文件 → 永远 `Can't connect to IBus` |

**教训**:先量准"失败发生在哪一步",再去找原因。
本例里决定性的一步是复刻 `Q(v)` 并观察 `Promise.all` 到底 reject 没有 ——
在那之前所有关于"引擎/总线名/addon"的猜测都是徒劳。

---

## 目录结构

```
steamdeck-chinese-ime/
├── README.md                     # 本文件
├── LICENSE                       # MIT
├── install/
│   ├── install-desktop-ime.sh    # 桌面模式一键安装
│   └── install-gaming-ime.sh     # 掌机模式一键安装(核心: dconf profile)
├── scripts/
│   ├── check-ime.sh              # 双模式自检
│   ├── verify-steam-osk.mjs      # Steam OSK 端到端验证(CEF DevTools)
│   └── ensure-ibus-dconf-profile.sh   # profile 文件自愈脚本
├── systemd/
│   ├── fcitx5.service                        # 桌面模式 daemon(--replace --keep --disable=ibusfrontend)
│   ├── ensure-ibus-dconf-profile.service     # 掌机模式 guard
│   ├── ibus-gamescope.override.conf          # Before=steam-launcher.service
│   └── plasma-kwin_wayland.inputmethod.conf  # KWin 的 --inputmethod= 桥
├── config/
│   ├── fcitx5-config              # fcitx5 配置(EnabledAddons / 热键 / Behavior)
│   ├── fcitx5-profile             # 分组:Default → keyboard-us + pinyin
│   └── kwinrc-snippet.txt         # kwinrc 的 InputMethod[$e] 条目
├── lib/                          # fcitx5 包装器与宿主构建脚本(装到 ~/.local/bin)
└── docs/
    ├── desktop-mode.md            # 桌面模式详解 + 坑
    ├── gaming-mode.md             # 掌机模式详解 + 坑
    └── troubleshooting.md         # 症状 → 原因 → 修法 对照表
```

---

## 常见问题

**Q:装完桌面模式,原生 Wayland 应用(kate / konsole / Dolphin)还是打不出中文?**
A:KWin 的 `--inputmethod=` 只在 KWin **启动时**接管协议。必须注销重登。
详见 [docs/desktop-mode.md](docs/desktop-mode.md)。

**Q:掌机模式 OSK 显示 `Keyboard_IME_Not_available`?**
A:Steam 客户端的引擎表**只在 connected 回调里刷新一次**,启动那一刻拿不到引擎就整个会话报废。
用 `./scripts/check-ime.sh` 查是谁占着 `org.freedesktop.IBus`。

**Q:打完中文候选提交不了 / 游戏里收不到?**
A:`gamescope` 的输入注入走私有协议 `gamescope_input_method`,
和 OSK 的 commit 是两段路。详见 [docs/gaming-mode.md](docs/gaming-mode.md)。

**Q:A/B 系统更新后会不会又坏了?**
A:本仓库所有东西都在 `/home` 下,A/B 更新只换系统镜像,碰不到。
唯一例外:`/etc/dconf/profile/ibus` 如果哪天被官方镜像修好了,它会**优先于**用户级那份被使用,
但两份内容一致,无影响。

---

## English summary

This repository collects fixes for Chinese input on SteamOS (Steam Deck) in **both** modes,
which use two completely independent stacks:

- **Desktop mode** (Plasma / KWin Wayland): fcitx5 installed into `~/.local/share/fcitx5-host`
  (because `/usr` lives on the A/B image partition and is wiped on every system update),
  bridged into native Wayland applications through KWin's `--inputmethod=` hook, which
  owns the `zwp_text_input_v3` protocol. The daemon must run with `--replace --keep`
  (so it does not suicide on a display hiccup) and `--disable=ibusfrontend`
  (so it does not steal `org.freedesktop.IBus` from Valve's gaming-mode daemon —
  note that `DisabledAddons=` in the config file does **not** work, only the CLI flag does).

- **Gaming mode** (Steam OSK + IBus): the decisive bug was a missing
  `/etc/dconf/profile/ibus`. `ibus-dconf` always sets `DCONF_PROFILE=ibus`; when dconf
  cannot open that named profile it falls back to the **null profile** (0 data sources),
  making every `/desktop/ibus/**` key non-writable. Steam's layout switch does
  `await Promise.all(writes)` *before* `set_global_engine("pinyin")`, so the rejected
  write aborts the whole sequence and the engine never changes — leaving Latin letters
  with no Chinese candidates, on the on-screen keyboard and the physical keyboard alike.
  The fix is to place the same profile file under a user-writable `XDG_DATA_DIRS` entry
  (inside `/home`, so it survives A/B updates), plus a systemd guard that recreates it.

`install/` contains one-shot installers, `scripts/check-ime.sh` diagnoses both modes,
and `scripts/verify-steam-osk.mjs` verifies the OSK path end-to-end from inside the
running Steam client via CEF DevTools.

---

## License

MIT —— 见 [LICENSE](LICENSE)。

脚本里的注释保留了大量"为什么这么写"的现场记录,是为了让后来的人(和未来的自己)
不用再把同样的坑重踩一遍。欢迎直接改、直接提 issue。
