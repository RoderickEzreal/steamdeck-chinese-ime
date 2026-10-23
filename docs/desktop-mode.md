# 桌面模式(Plasma / KWin Wayland)中文输入法

> 目标:桌面会话里,**原生 Wayland 应用**(kate / konsole / Dolphin / Plasma 搜索框)
> 和 XWayland 应用都能打中文。
> 掌机模式是另一套完全独立的链路,见 [gaming-mode.md](gaming-mode.md)。

---

## 一、五个真正的根因

### 1. 装进 `/usr` → A/B 更新后全丢

SteamOS 是 A/B 双分区原子更新,`/usr`、`/opt`、`/bin` 都在**系统镜像分区**上。
`pacman -i` 装的、手动 `cp` 进去的,下一次更新会被整块抹掉。
表现就是"修好几天一直修不好"。

**解法**:整套 fcitx5 装在 `~/.local/share/fcitx5-host/`(`/home` 独立分区,永远保留),
并且**装 SteamOS 自带 extra 源里的官方 Arch 包**,与本机 glibc / Qt 同版本,ABI 天然兼容。

### 2. 装 flatpak 版 → Qt 插件版本对不上

flatpak 版 fcitx5 的 Qt 插件要 Qt 6.11,本机只有 6.9 → 插件加载失败。
混合两个来源的 addon 定义还会触发 `addon dependency not satisfied`。

**解法**:只装 host(Arch 包)版,`XDG_DATA_DIRS` 里**不要**加 flatpak 导出目录。

### 3. KWin 没桥接 → 原生 Wayland 应用永远打不出中文

这是最隐蔽的一个。KWin 通过 `--inputmethod=<desktop 文件>` 启动一个 launcher,
由它在 `WAYLAND_SOCKET` 上接管 `zwp_text_input_v2/v3` 协议。
**没有它,原生 Wayland 应用打不出中文,跟 daemon 状态完全无关** ——
daemon 跑得好好的、`fcitx5-remote -n` 也返回 pinyin,但 kate 里就是打不出中文。

之前一直修不好的原因:KWin 配置里指向的 desktop 文件和 launcher 二进制**压根不存在**
(那一版是手动 `cp` 进 `/usr/lib` 的,A/B 更新后必然消失)。

**解法**(整条链路都在 `/home`,不用 sudo):

```
~/.local/bin/fcitx5-wayland-launcher            → ~/.local/share/fcitx5-host/libexec/fcitx5-wayland-launcher
~/.config/systemd/user/plasma-kwin_wayland.service.d/inputmethod.conf
    ExecStart=/usr/bin/kwin_wayland_wrapper --xwayland --inputmethod=%h/.local/bin/fcitx5-wayland-launcher
~/.config/kwinrc
    InputMethod[$e]=~/.local/share/applications/fcitx5-wayland-launcher.desktop
```

⚠️ `kwinrc` 里的路径 **KConfig 不会展开 `~`**,必须写绝对路径(安装脚本会代填)。

### 4. daemon 没 `--keep` → 一断连就自杀,没人拉回来

旧配置里 daemon 因为显示连接被抢走,打出
`Connection removed` → `Save before exiting` → **直接自杀**,
而旧的 xdg-autostart 单元 `Restart=no` 没人拉它回来。

**解法**:交给 systemd 用户单元托管:

```ini
ExecStart=%h/.local/bin/fcitx5 --replace --keep --disable=ibusfrontend
Restart=always
RestartSec=5
```

- `--replace`:已有实例时接管,而不是直接退出
- `--keep`:主显示连接断开时不退出
- `Restart=always`:任何原因退出都自动拉起

### 5. 中文 addon 是 OnDemand → 分组校验时 pinyin 被踢掉

fcitx5 的中文 addon(pinyin / cloudpinyin / table / chttrans / fullwidth / punctuation)
默认 `OnDemand=True` —— 只在"被输入法分组引用"时才加载。
但**分组校验发生在 addon 加载之前**,顺序一错开就会看到:

```
"Group Item pinyin in group Default is not valid. Removed."
```

pinyin 被踢出分组,之后谁也加不回来。

**解法**:给它们生成 `OnDemand=False` 的用户态覆盖:

```sh
for a in pinyin cloudpinyin chtrans table fullwidth punctuation pinyinhelper; do
    sed 's/^OnDemand=.*/OnDemand=False/' "$HOST/share/fcitx5/addon/$a.conf" \
        > "$HOME/.local/share/fcitx5/addon/$a.conf"
done
```

⚠️ 覆盖文件是从**已安装的** `.conf` 派生的,版本号和依赖声明天然一致。
踩过的坑:手写覆盖文件写着 `core:5.1.22`,实际装的是 5.1.14 → 依赖校验不过 → addon 静默拒绝加载。

---

## 二、另一个通道:`EnabledAddons` 必须写在文件顶部

`~/.config/fcitx5/config` 里,`EnabledAddons=` / `DisabledAddons=` **只在文件顶部读取**。
之前它们被写在 `[Behavior]` 段里,导致"强制加载中文 addon"完全没生效,
6 个 `OnDemand=True` 的中文 addon 一个都没加载。

```ini
EnabledAddons=pinyin,cloudpinyin,chttrans,table,fullwidth,punctuation,pinyinhelper
```

(注意上面拼写应为 `chttrans`,与包名 `fcitx5-chinese-addons` 提供的 addon 名一致。)

---

## 三、`--disable=ibusfrontend` 只能走命令行

fcitx5 的 `ibusfrontend` addon 加载时用
`RequestNameFlag::DoNotQueue | ReplaceExisting` 申请 `org.freedesktop.IBus`:
**真 ibus-daemon 抢不回来**,而它自己只实现 `CreateInputContext`
(`GetEnginesByNames` 返回空数组、`SetGlobalEngine` 直接 UnknownMethod)。

Steam 的屏幕键盘(OSK)是 IBus 客户端,靠 `GetEnginesByNames` / `SetGlobalEngine` 工作。
fcitx5 占着这个名字 → OSK 拿到空的引擎列表 → 掌机模式彻底没有中文。

**坑**:配置文件里的 `DisabledAddons=ibusfrontend` **不生效**。
`~/.config/fcitx5/config` 顶部的 `EnabledAddons=` / `DisabledAddons=` 走"配置"通道,
真正生效的覆盖通道是**命令行** `--disable` / `--enable`
(`fcitx5 --help` 里有 `--disable <addon names>`,`"all"` 可以禁掉全部)。

**判据**:journal 里出现这一行才算生效 ——

```
Override Disabled Addons: {ibusfrontend}
```

---

## 四、九个陷阱

1. **别并发跑第二个 daemon**。手动 `fcitx5 -d --enable=all` 会抢 Wayland/DBus 连接,
   老 daemon 发现连接被抢 + 没有 `--keep` → 自杀,而 `Restart=no` 没人拉回来。
   → **每手动跑一次就毁掉一个本来能用的输入法**。daemon 交给 systemd,脚本只做"检查+重启+校验"。

2. **千万别单独 `systemctl --user restart plasma-kwin_wayland`**。SteamOS 桌面模式下
   kwin 是嵌套在 gamescope 里的合成器,单独 restart 会带走 `wayland-0` socket → **整个桌面崩掉**。
   kwin 的启动参数改了也只能靠"注销重登"生效。

3. **改 profile 必须 stop → 写 → start**。daemon 退出(SIGTERM)时会用内存里的分组
   覆写 `~/.config/fcitx5/profile`,运行中改文件会被抹掉。

4. **不用固定版本号做检测**。整套装在 `~/.local/share/fcitx5-host/`,检测文件存在即可;
   A/B 更新不会动 `/home`。

5. **`fcitx5-remote -n` 在终端里跑往往返回 `keyboard-us`**,不代表坏了 ——
   它报的是"当前持有焦点的输入上下文"用的 IM。终端没有焦点窗口。
   真状态看 `FullInputMethodGroupInfo Default` 里的第二项。

6. **`CurrentInputMethod` 同理**。要看的是**分组**当前 IM:

   ```sh
   gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
     --method org.fcitx.Fcitx.Controller1.FullInputMethodGroupInfo Default
   ```

7. **配置界面点不开**:daemon 的托盘菜单用 `execvp("fcitx5-configtool")` 按**名字**找,
   而我们的 fcitx5 在 `~/.local/` 下,不在 PATH 里 → `execvp: 没有那个文件或目录`。
   解法:`~/.local/bin/fcitx5-configtool` 包装器 + daemon 的 `Environment=PATH=` 里有 `~/.local/bin`。

8. **别把 flatpak 的 fcitx5 和 host 版混用**。`XDG_DATA_DIRS` 里如果同时有
   flatpak 导出目录(fcitx5 5.1.23)和 host 版(5.1.14),addon 定义版本对不上,
   会触发 `addon dependency not satisfied`。

9. **systemd 排序环**。别在 `plasma-kwin_wayland.service.d/` 里写
   `After=fcitx5.service` —— 和 `fcitx5.service` 自己的 `After=graphical-session.target`
   形成环:

   ```
   fcitx5.service → graphical-session.target → plasma-workspace.target
                  → plasma-core.target → plasma-kwin_wayland.service → fcitx5.service
   ```

   systemd 只能硬砍(`Job fcitx5.service/start deleted to break ordering cycle`)。
   `Wants=` 足够保证同一个事务里被拉起来;"daemon 还没就位就 spawn 启动器"这个竞态,
   由 `fcitx5-wayland-launcher` 包装器自己轮询总线名归属(最多等 10 秒)解决。

---

## 五、自检

```sh
./scripts/check-ime.sh
```

关键判据:

- `Default 分组当前 IM 是 pinyin`
- `AvailableInputMethods 里有 pinyin`
- `KWin 的 --inputmethod= 桥在跑`(`pgrep -f fcitx5-wayland-launcher`)
- `ibusfrontend 已被禁用(命令行通道生效)`
- `fcitx5 宿主安装在 /home(A/B 免疫)`

一键修复:

```sh
./lib/fcitx5-reinstall.sh
```

它会依次:检查/自动重建宿主安装 → 检查 KWin 桥接 → 停 daemon 修 profile →
重载重启 → 校验 → 报出结论。**它不会**重启 kwin,不会并发跑第二个 daemon。

---

## 六、相关文件

| 文件 | 作用 |
|---|---|
| `lib/fcitx5-build-host` | 从 SteamOS 官方源构建宿主安装(不碰 `/usr`) |
| `lib/fcitx5-ensure-installed` | 自检 + 必要时自动重建(退出码 0/1/2) |
| `lib/fcitx5` | daemon 包装器(设 `LD_LIBRARY_PATH` / `FCITX_ADDON_DIRS` / `LIBIME_MODEL_DIRS`) |
| `lib/fcitx5-wayland-launcher` | KWin `--inputmethod=` 的目标;自带"等 daemon 就位"逻辑 |
| `lib/fcitx5-start` | 启动 daemon + 同步 Plasma 会话环境进 systemd user manager |
| `lib/fcitx5-dbus-activate` | D-Bus 激活 `org.fcitx.Fcitx5`(优先级高于 flatpak 导出的那份) |
| `lib/fcitx5-configtool` | 让托盘菜单的 `execvp` 找得到配置程序 |
| `systemd/fcitx5.service` | daemon 单元(`Restart=always` + `--replace --keep --disable=ibusfrontend`) |
| `systemd/plasma-kwin_wayland.inputmethod.conf` | KWin 的 `--inputmethod=` 桥接 |
| `config/fcitx5-config` | `EnabledAddons` / 热键 / `Behavior` |
| `config/fcitx5-profile` | 分组:Default → `keyboard-us` + `pinyin` |
