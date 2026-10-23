# 掌机模式(游戏会话)中文输入法

> 目标:游戏里按 `Steam+X` 弹出的屏幕键盘(OSK)能打出中文,
> 物理键盘打进 OSK 也能出候选。
>
> ⚠️ 这条链路和桌面模式的 fcitx5 **完全独立**。
> 桌面好好的不代表掌机模式能用,反过来也一样。

---

## 一、链路全貌

```
游戏里按 Steam+X → Steam OSK 弹出
  → OSK 是 IBus 客户端(在 pressure-vessel 容器里)
  → D-Bus: org.freedesktop.portal.IBus → org.freedesktop.IBus
  → Valve 的 ibus-daemon(ibus-gamescope.service)持有总线名,带 pinyin 引擎
  → 选中引擎 → IBus commit → SteamClient.Input.ControllerKeyboardSendText
  → gamescope 私有 gamescope_input_method 协议 → src/ime.cpp type_text()
```

关键事实:

- **`gamescope` 没有实现 `zwp_text_input_manager_v3`**(上游 PR #2259 至今未合),
  所以 fcitx5 在游戏里**不可能**接管输入法。游戏内中文只有 OSK + IBus 这一条路。
- gamescope-session 会导出 `GTK_IM_MODULE=Steam` / `QT_IM_MODULE=steam`
  (`/usr/lib/steamos/gamescope-session` 第 143-144 行),
  Steam 的 GTK/Qt 插件收到按键只是去开 `steam://open/keyboard`。
- Valve 的 `ibus-gamescope.service`:
  `ibus-daemon -r --panel=disable --emoji-extension=disable`,
  `Type=dbus` + `BusName=org.freedesktop.IBus`(拿到总线名才算启动完),
  `EnvironmentFile=%t/gamescope-environment`。
- 由 `/usr/lib/systemd/user/gamescope-session.target` 的 `Wants=ibus-gamescope.service` 拉起。
- OSK 的中文布局 id(`steamui/chunk~2dcc5aaf7.js` 里的表):
  `2=拼音(简) 3=拼音(繁) 31=注音 32=table:cangjie5 34=table:quick5`
  (ja/ko 表里 id 另算)。
- 账号级配置在 `~/.local/share/Steam/userdata/<id>/config/localconfig.vdf` 的
  `keyboard_layout`(形如 `{"currentLayout":2,"selectedLayouts":[0,2]}`),
  全局在 `~/.local/share/Steam/config/config.vdf`。
  `currentLayout=2` 就是"简体中文(拼音)"当前选中。

---

## 二、Steam 客户端怎么判断"这个布局能不能用中文"

Steam UI 的 IBus 管理类:

```js
HasIBusBinding(){ return "undefined" != typeof IBus }
IsIBusDaemonMissing(){ return true === this.m_bIBusDaemonMissing }
IsEngineMissing(e){ return false === this.m_mapAvailableEngines[e] }
```

引擎表**只在 connected 回调里刷新一次**:

```js
ConnectHandler(){
  this.m_bIBusDaemonMissing = false;
  Promise.all(Object.values(w).map(e =>
    this.m_Bus.get_engines_by_names([e.engineName]).then(t => ({[e.engineName]: t.length !== 0}))))
    .then(e => { this.m_mapAvailableEngines = {...e}; ... });
}
```

→ **只要启动那一刻 `get_engines_by_names(['pinyin'])` 返回空,
整个会话的 OSK 都是 `Keyboard_IME_Not_available`,而且不会自愈**
(除非总线名易主触发 connected)。

### 切换布局的动作(根因就在这)

```js
async function Q(v){
  ...
  await Promise.all(M);                             // ① 先写一批引擎配置
  await E.GetBus().set_global_engine(k.engineName); // ② 再切全局引擎
  ...
}
```

**① 里任何一个写失败 → `Promise.all` reject → ② 永远不执行。**

---

## 三、★ 根因:本机缺 `/etc/dconf/profile/ibus`

### 证据链

```console
$ pacman -Qkk ibus
警告:ibus: /etc/dconf/profile/ibus (没有那个文件或目录)
```

ibus 包**本该带的这个文件在本机不存在**(SteamOS 打包/裁剪问题)。
同包的 `/etc/dconf/db/ibus.d/00-upstream-settings` 也缺。

`/usr/lib/ibus/ibus-dconf` 启动时调:

```c
g_setenv ("DCONF_PROFILE", "ibus", FALSE);
```

所以它**永远用具名 profile "ibus"**。dconf 0.40.0 源码(`dconf-engine.c`):

```c
/* 找不到具名 profile 文件时 */
g_warning ("unable to open named profile (%s): using the null configuration.", profile);
sources = dconf_engine_null_profile (n_sources);   /* ← 0 个数据源 */

static gboolean
dconf_engine_is_writable_internal (DConfEngine *engine)
{
  if (engine->n_sources == 0)     /* ← 恒为 FALSE */
    return FALSE;
  ...
}
```

内置的 `user-db:user` 默认 profile **只在没指定 profile 名时才用** ——
具名 profile 找不到就是 null,不会退到 user-db。

⇒ **null profile 下 `/desktop/ibus/**` 每一个键都是 non-writable**:

- 写入报 `The operation attempted to modify one or more non-writable keys`
  (`DCONF_ERROR_NOT_WRITABLE`, code 2)
- 读取返回 `NULL`

→ `Promise.all(M)` 直接 reject → `set_global_engine('pinyin')` 不执行
→ 引擎停在 `xkb:us::eng`
→ **打字只有拉丁字母、没有任何中文候选**(软键盘和实体键盘都一样)

连带影响:ibus 连自己的 general 设置都读不到
(`dconf-preserve-name-prefixes`、`embed-preedit-text`、`use-global-engine` 等)。

### 修法

把上游同名文件放到**用户可写**的路径:

```
~/.local/share/flatpak/exports/share/dconf/profile/ibus
```

```
user-db:user
system-db:ibus
```

位置理由:

1. dconf 找具名 profile 的顺序 = **SYSCONFDIR(`/etc/dconf/profile`)优先,再 XDG_DATA_DIRS**
2. `/etc` 在只读镜像分区 → A/B 更新必丢
3. XDG_DATA_DIRS 里唯一用户可写的是 flatpak 导出目录,它在 `/home` → A/B 更新不丢
4. 掌机会话的环境文件 `/run/user/1000/gamescope-environment` 里
   `XDG_DATA_DIRS=/home/deck/.local/share/flatpak/exports/share:...`
   —— **第一项就是它**

再配一个自愈单元(`systemd/ensure-ibus-dconf-profile.service`):

```ini
[Unit]
Before=ibus-gamescope.service
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ensure-ibus-dconf-profile.sh
RemainAfterExit=yes

[Install]
WantedBy=gamescope-session.target
```

> 💡 **不需要 sudo**。用 sudo 把文件放回 `/etc/dconf/profile/ibus` 也能修好,
> 但 `/etc` 在 A/B 镜像分区上,更新后照样丢 —— 用户级那份才是持久的。
> 缺失的 `/etc/dconf/db/ibus` 只会让 dconf 打印一句
> `unable to open file '/etc/dconf/db/ibus' ... expect degraded performance`,**无害**:
> schema 默认值已经覆盖了上游设置(`dconf-preserve-name-prefixes` 的默认就是
> `['/desktop/ibus/engine/pinyin','.../bopomofo','.../hangul']`,`embed-preedit-text=true`)。

---

## 四、另外三个坑

### 1. 启动竞态:IBus 守护进程必须排在 Steam 客户端前面

`ibus-gamescope.service` 和 `steam-launcher.service` 原本是**并行启动**的。
实测 journal:两者 `23:05:34` 同时 "Starting",Steam 客户端 `23:05:37` 才真正起来,
中间只有 **3 秒**窗口。

Steam 客户端启动时立刻调用 `IBus.bus_new()` + `get_engines_by_names()`,
一旦这时候总线名还没被真正的 ibus-daemon 拿到,客户端就把
"所有 CJK 引擎都不存在"**记死**(引擎表只在 connected 时刷新一次)。

**解法**:

```ini
# ~/.config/systemd/user/ibus-gamescope.service.d/override.conf
[Unit]
Before=steam-launcher.service
```

不会形成循环:两个单元都是 `After=graphical-session.target` + `PartOf=graphical-session.target`,
`Before=` 只是加了一条单向边。

### 2. 用户级 `ibus-daemon.service` 必须禁用

`~/.config/systemd/user/ibus-daemon.service` 的
`ExecStart=ibus-daemon -d -r -n --panel=disable` 有三个问题:

- `-d` 会 daemonize,systemd 跟的主进程 17ms 就退 0,真正的 daemon 变孤儿
- `-n` 是 `--desktop=name`(不是 "single instance"),它会把下一个参数 `--panel=disable` 吃掉
- 它 `WantedBy=default.target`,开机比 Valve 的 `ibus-gamescope.service` **早 2 秒**,
  会跟 Valve 的抢总线名

```sh
systemctl --user disable ibus-daemon.service
```

### 3. fcitx5 的 ibusfrontend 会抢总线名

见 [desktop-mode.md](desktop-mode.md) 第三节。掌机会话里
`graphical-session.target` 会被 `gamescope-session.target` `Requires` 起来,
fcitx5 也在其中跑 —— 不禁掉它,真 ibus-daemon 就抢不回 `org.freedesktop.IBus`。

```ini
ExecStart=%h/.local/bin/fcitx5 --replace --keep --disable=ibusfrontend
```

---

## 五、怎么在游戏里用中文

1. `Steam + X` 打开屏幕键盘(游戏里按 `Steam+X` 或菜单里"屏幕键盘")
2. 键盘左下角的**地球键**切换布局,选 **简体中文(拼音)**
3. 当前布局由账号级 `keyboard_layout.currentLayout` 决定(`=2` 就是拼音)

> 实体键盘打进 OSK 也应该出候选 —— 因为 OSK 自己的 input context 用的就是全局引擎。

---

## 六、验证(最准的方法)

`scripts/verify-steam-osk.mjs` 在 Steam 客户端内部(CEF DevTools)完整复刻 `Q(v)`:

```bash
# Steam 客户端要带 --remote-debugging-port=8080 启动
node scripts/verify-steam-osk.mjs
```

输出:

```
引擎表 (get_engines_by_names):
   ✓ pinyin           1 个
   ✓ bopomofo         1 个
   ✓ table:cangjie5   1 个
   ✓ table:quick5     1 个

引擎配置写入:全部 OK
Promise.all 是否 reject : ✓ 否
set_global_engine       : OK
输入 "n" → preedit  : "你"
候选                    : ["你","那","呢","能","年"]
```

**"Promise.all 是否 reject" 是决定性的一行** —— 它为"是"就说明 dconf profile 又出问题了。

---

## 七、诊断时踩到的工具坑

1. **`IBus.bus_new()` 返回 Promise**,必须 `await`;否则拿到的是 Promise 本体,
   报 `bus.get_engines_by_names is not a function`。
2. **`ibus-daemon` 不实现 `Introspectable`** → `gdbus call --dest org.freedesktop.IBus
   --object-path /org/freedesktop/IBus ...` 会报"对象在路径处不存在",
   `busctl call` 同样。别据此判断"没有 IBus"。
3. **`ibus list-engine` 在 systemd 拉起的 daemon 上永远失败** ——
   它靠 `~/.config/ibus/bus/` 下的地址文件找 daemon,而 systemd 起的 daemon 不写那个文件
   → `Can't connect to IBus`。用 `pgrep -f ibus-engine-pinyin` 或直接用上面的 DevTools 探针。
4. **`busctl --user status <name> | awk '/^PID=/{print $2; exit}'` 会丢输出**
   (awk 提前退出 → busctl 收到 SIGPIPE → 缓冲区没冲出去)。
   要 `status_out=$(busctl ...); sed -n 's/^PID=//p' <<<"$status_out"`。
5. **`busctl --user list-names` 不是合法子命令**(用 `busctl --user list`)。
6. **`gdbus call ... ca.desrt.dconf.Write` 方法不存在** —— 正确的接口是
   `ca.desrt.dconf.Writer.Change(ay)`,对象路径 `/ca/desrt/dconf/Writer/user`。
7. **别用 `gdb -p` / `strace -p` 附加到别人的进程** —— ptrace 被拒;
   只能 `strace -f` 自己 spawn 出来的子进程。
8. **dconf 写探针如果不在 GLib main loop 里跑,`dconf_client_write_sync` 会挂住** ——
   文件监视器不触发,不是 dconf 的 bug;`dconf write` CLI 走同一条系统调用路径却是正常的。
   探针要 `python3 -u`(否则 stdout 缓冲吞掉输出)。
9. **`ibus-dconf` 会变成孤儿**(父 daemon 死了它还活着),而且**它启动时打开的 profile 是固定的** ——
   改完 profile 文件必须让它重启(重启守护进程即可)才生效。
   调试时记得 `pgrep -a ibus-dconf` 确认没有残留的旧实例在抢着写同一个 db。

---

## 八、相关文件

| 文件 | 作用 |
|---|---|
| `install/install-gaming-ime.sh` | 一键安装(核心:写 dconf profile + 装 guard + 排除总线名抢占) |
| `scripts/ensure-ibus-dconf-profile.sh` | 幂等重建 profile 文件 |
| `systemd/ensure-ibus-dconf-profile.service` | 自愈 guard(`Before=ibus-gamescope.service`) |
| `systemd/ibus-gamescope.override.conf` | `Before=steam-launcher.service`(消除启动竞态) |
| `scripts/check-ime.sh` | 掌机 + 桌面双模式自检 |
| `scripts/verify-steam-osk.mjs` | Steam OSK 端到端验证 |
