# 症状 → 原因 → 修法 对照表

先跑 `./scripts/check-ime.sh` 定位,再对照下表。

---

## 掌机模式 / OSK

| 症状 | 原因 | 修法 |
|---|---|---|
| OSK 弹出后按字母**没有中文候选**,实体键盘也不行 | **缺 `/etc/dconf/profile/ibus`** → dconf 退回 null profile → 所有 ibus 配置写入 non-writable → Steam 切布局时 `Promise.all` 中断 → `set_global_engine` 不执行 | `./install/install-gaming-ime.sh`;手写 `~/.local/share/flatpak/exports/share/dconf/profile/ibus`,内容 `user-db:user\nsystem-db:ibus` |
| OSK 显示 `Keyboard_IME_Not_available` | 启动那一刻 `get_engines_by_names(['pinyin'])` 返回空(引擎表只在 connected 时刷新一次,之后不自愈) | 查谁占着 `org.freedesktop.IBus`:`busctl --user list \| grep IBus`。应该是 `ibus-daemon`,不是 fcitx5 |
| `ibus-gamescope.service` 起不来 / 拿不到总线名 | 用户级 `ibus-daemon.service` 抢先占了名字 | `systemctl --user disable ibus-daemon.service` |
| 同上 | fcitx5 的 ibusfrontend 抢了名字(`ReplaceExisting\|DoNotQueue`) | `ExecStart` 加 `--disable=ibusfrontend`(**只能走命令行**,配置文件里的 `DisabledAddons=` 不生效)。判据:journal 出现 `Override Disabled Addons: {ibusfrontend}` |
| 切布局偶尔整个会话报废 | `ibus-gamescope` 和 `steam-launcher` 并行启动,只有 3 秒窗口 | drop-in 加 `Before=steam-launcher.service` |
| 大部分时候正常,偶尔整个会话没中文 | 同上,竞态 | 同上 |
| `ibus list-engine` 报 `Can't connect to IBus` | **不是故障** —— `ibus` CLI 靠 `~/.config/ibus/bus/` 地址文件找 daemon,systemd 起的 daemon 不写 | 用 `pgrep -f ibus-engine-pinyin` 或 `scripts/verify-steam-osk.mjs` |
| dconf 报 `unable to open file '/etc/dconf/db/ibus'` | 系统 db 缺失 | **无害**,可忽略。schema 默认值已覆盖上游设置 |
| 改完 profile 文件但没生效 | `ibus-dconf` 启动时就打开了 profile,之后不会重读 | 重启 ibus 守护进程;`pgrep -a ibus-dconf` 确认没有孤儿实例 |

---

## 桌面模式 / fcitx5

| 症状 | 原因 | 修法 |
|---|---|---|
| 原生 Wayland 应用(kate/konsole/Dolphin)打不出中文,但 `fcitx5-remote -n` 是 pinyin | KWin 的 `--inputmethod=` 没生效(指向的 launcher 或 desktop 文件不存在) | 装 `systemd/plasma-kwin_wayland.inputmethod.conf` + launcher desktop 文件;**注销重登** |
| 装完必须重登才生效 | `--inputmethod=` 只在 KWin 启动时接管 `zwp_text_input_v3` | 注销重登 / 重启 |
| daemon 跑着,几天后输入法突然没了 | daemon 因显示连接被抢走而自杀(`Connection removed`),`Restart=no` 没人拉回来 | `ExecStart` 加 `--keep` + `Restart=always` + `--replace` |
| `pinyin` 从分组里消失,日志有 `Group Item pinyin in group Default is not valid. Removed.` | 中文 addon 默认 `OnDemand=True`,而分组校验发生在 addon 加载**之前** | 给这些 addon 生成 `OnDemand=False` 的用户态覆盖(见 `fcitx5-build-host` 第 5b 步) |
| 分组里没有 pinyin,日志说 `EnabledAddons` 不起作用 | `EnabledAddons=` 写在了 `[Behavior]` 段里 | 移到 `~/.config/fcitx5/config` **文件顶部** |
| addon 静默不加载,日志 `addon dependency not satisfied` | 手写的覆盖文件版本号和实际装的版本对不上 | 覆盖文件必须从**已安装的** `.conf` 派生 |
| 托盘菜单点"配置"毫无反应,日志 `execvp: 没有那个文件或目录` | daemon 用 `execvp()` 按名字找 `fcitx5-configtool`,不在 PATH 里 | 装 `lib/fcitx5-configtool` 包装器 + daemon 的 `Environment=PATH=` 含 `~/.local/bin` |
| 改 `~/.config/fcitx5/profile` 不生效 / 被改回去 | daemon 退出时用内存里的分组覆写 profile | 停 daemon → 写 → 起 |
| 系统更新后输入法整个没了 | 装进了 `/usr`(A/B 镜像分区) | 重装到 `~/.local/share/fcitx5-host` |
| flatpak 应用打不出中文 / Qt 插件加载失败 | flatpak 版 fcitx5 要 Qt 6.11,本机只有 6.9 | 只用 host 版;`XDG_DATA_DIRS` 里别混 flatpak 导出目录 |
| `fcitx5-remote -n` 返回 `keyboard-us` | 它报的是"当前持有焦点的输入上下文"用的 IM,终端里没有焦点窗口 | 看 `FullInputMethodGroupInfo Default` 的第二项 |
| systemd 日志刷 `Job fcitx5.service/start deleted to break ordering cycle` | drop-in 里的 `After=fcitx5.service` 和 `fcitx5.service` 自己的 `After=graphical-session.target` 形成环 | drop-in 里改用 `Wants=`(竞态交给 launcher 包装器轮询解决) |
| 桌面崩了 / 桌面起不来 | 有人单独 restart 了 `plasma-kwin_wayland` | **千万别单独 restart 它**。kwin 的启动参数改了也只能靠注销重登 |

---

## 通用

| 症状 | 原因 | 修法 |
|---|---|---|
| 修好的东西几天后又没了 | 装到了系统镜像分区(`/usr`、`/opt`、`/bin`) | 全部搬到 `/home`(`~/.local/bin`、`~/.local/share/...`) |
| 装完输入法莫名消失 | 同上 | 同上 |
| 想确认某个改动到底生效没 | 看 journal 里的判据行 | `--disable` 看 `Override Disabled Addons: {ibusfrontend}`;<br>addon 看 `Loaded addon ...`;<br>引擎看 `AvailableInputMethods` |

---

## 诊断工具速查

```sh
# 总线名归谁
busctl --user list | grep org.freedesktop.IBus

# 拿占用者 PID(注意:别用 awk ... exit,会 SIGPIPE 掉 busctl)
status_out=$(busctl --user status org.freedesktop.IBus 2>&1)
sed -n 's/^PID=//p' <<<"$status_out"

# fcitx5 分组当前 IM
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
  --method org.fcitx.Fcitx.Controller1.FullInputMethodGroupInfo Default

# fcitx5 可用输入法
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
  --method org.fcitx.Fcitx.Controller1.AvailableInputMethods

# dconf profile 是否生效(★ 掌机模式的关键判据)
DCONF_PROFILE=ibus dconf write /desktop/ibus/engine/pinyin/__probe__ true \
  && echo "可写 → profile 正常" || echo "不可写 → profile 缺失"

# ibus 引擎有没有被加载
pgrep -a -f 'ibus-engine-(pinyin|bopomofo|table)'

# Steam OSK 端到端
node scripts/verify-steam-osk.mjs
```
