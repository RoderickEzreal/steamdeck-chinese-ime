# flatpak 应用(QQ / Chrome / Electron 系)打不出中文

> 2026-10-24 定位并修复,用户实测通过。
> 适用范围:**任何 flatpak 里跑着的 Chromium / Electron 应用**在 X11 下打不出中文。
> 典型受害者:`com.qq.QQ`、`com.tencent.WeChat`、`com.wps.Office`、`com.baidu.NetDisk`、
> `com.google.Chrome`、`com.visualstudio.code`。

---

## 症状

- flatpak 应用里按 `Ctrl+Space` **毫无反应**,键入字母也**不弹候选框**
- 但桌面上的原生应用(kate / konsole / Firefox)**一切正常**
- 宿主上 fcitx5 daemon 活着、`fcitx5-remote` 返回 `2`(中文已激活)、pinyin 在分组里
- `fcitx5-diagnose` 里**压根找不到这个应用**的输入上下文

最后一条是关键判据 —— 见下面「诊断金标准」。

---

## 链路:Chromium 在 X11 下**没有 XIM**,只剩 GTK IM 模块

老经验说"Chromium 走 XIM",**在当代 Chromium 上已经不成立了**。
2026-10-24 用 QQ 3.2.34(Electron 40 / Chromium 140)实测:

```bash
QQ=/var/lib/flatpak/app/com.qq.QQ/x86_64/stable/<commit>/files/extra/QQ/qq

# XIM 侧的符号和字符串:全是 0
readelf --dyn-syms -W "$QQ" | awk '{print $NF}' | grep -cE 'XOpenIM|XCreateIC'   # 0
strings -a "$QQ" | grep -cE 'XMODIFIERS'                                        # 0

# 但 GTK IM 模块的 dlsym 字符串一应俱全
strings -a "$QQ" | grep -E '^gtk_im_context_' | sort -u
#   gtk_im_context_filter_key
#   gtk_im_context_filter_keypress
#   gtk_im_context_focus_in / _focus_out
#   gtk_im_context_get_preedit_string
#   gtk_im_context_reset
#   gtk_im_context_set_client_widget / _set_client_window
#   gtk_im_context_set_cursor_location
#   gtk_im_context_simple_new

# Wayland 原生协议也在
strings -a "$QQ" | grep -cE 'zwp_text_input_manager_v[13]'                      # 2
```

所以 Chromium 的输入法只有两条路:

| 平台 | 走哪条 | 能不能在本方案下工作 |
|---|---|---|
| **Wayland** | `zwp_text_input_v3` 原生协议 → KWin → fcitx5 | ✅ 桌面模式的经典链路 |
| **X11** | **GTK3 的 IM 模块**(`im-fcitx5.so`)→ D-Bus → fcitx5 | ⚠️ 本文档要解决的这条 |

> XIM(`XOpenIM` / `XMODIFIERS`)在 Chromium 里**已被移除**。
> 所以"给 flatpak 应用设 `XMODIFIERS=@im=fcitx` 就能用"这条老偏方**完全无效** ——
> 变量设了也没人读。

---

## 真根因:宿主导出的 `GTK_IM_MODULE_FILE` 在沙箱里指向不存在的路径

本仓库把 fcitx5 装在 `~/.local/share/fcitx5-host/`(免 sudo、A/B 免疫),
所以必须让 GTK3 去读**自己那份** `immodules.cache`:

```sh
# ~/.config/environment.d/fcitx5.conf
# ~/.config/plasma-workspace/env/fcitx5.sh
GTK_IM_MODULE_FILE=/home/deck/.local/share/fcitx5-host/share/gtk-3.0/immodules.cache
```

这个环境变量**会原样传进 flatpak 沙箱**(flatpak 只隔离文件,不隔离环境变量)。
可是这个路径在沙箱里**不存在**:

```console
$ flatpak run --command=sh com.qq.QQ -c 'ls /home/deck/.local/share/fcitx5-host/'
ls: 无法访问 '/home/deck/.local/share/fcitx5-host/': 没有那个文件或目录
```

⇒ 沙箱里的 GTK3 **读不到 cache → 加载不到 `im-fcitx5.so` → 完全没有输入法**。

而宿主上一切正常(`/home/deck/.local/share/fcitx5-host/` 就在那儿),
所以这个故障**只发生在 flatpak 沙箱里**,极易被误判成"flatpak 隔离的锅"。

---

## 修法

### 通用(所有 flatpak)

各 runtime **自带**一份 `immodules.cache`,里面已经包含 `im-fcitx5.so` 的登记,
runtime 里也自带 `im-fcitx5.so` 和 `libFcitx5GClient.so.2`。
把沙箱里的 `GTK_IM_MODULE_FILE` 改指到它:

```bash
flatpak override --user \
  --env=GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache
```

### QQ 专属

QQ 的 flatpak 有个自己的 wrapper,会检查沙箱里 `/tmp/.X11-unix` 是否为空:
**X11 socket 空 + 有 `WAYLAND_DISPLAY`** 时,它会改用 `xvfb-run` 起一个虚拟显示 `:99`,
而 fcitx5 跑在 `:0` 上,于是窗口和输入法对不上。

所以 QQ 要**保留 X11 socket、拿掉 Wayland socket**,让 wrapper 走正常分支:

```bash
flatpak override --user --socket=x11 --nosocket=wayland \
  --env=GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache \
  com.qq.QQ
```

同时 QQ 的 wrapper 会读 `$XDG_CONFIG_HOME/qq-flags.conf`(QQ 是少数公开这个的应用),
两份都写上,防止 flatpak 不重映射 `XDG_CONFIG_HOME` 时漏掉:

```bash
printf -- '--ozone-platform=x11\n' > ~/.var/app/com.qq.QQ/config/qq-flags.conf
printf -- '--ozone-platform=x11\n' > ~/.config/qq-flags.conf
```

> ⚠️ **改完必须重启应用**才生效(环境变量是启动时注入的)。

一键脚本:`./scripts/fix-flatpak-ime.sh`

---

## 诊断金标准:`fcitx5-diagnose` 的 `frontend:` 字段

它直接告诉你每个输入上下文走的哪条链:

| `frontend:` | 含义 | 对应协议 |
|---|---|---|
| `xim` | X11 XIM | libX11 `XOpenIM`(**Chromium 已不用**) |
| `dbus` | **GTK IM 模块** | `im-fcitx5.so` → `org.freedesktop.portal.Fcitx` → fcitx5 |
| `wayland` | 原生 Wayland | `zwp_text_input_v3` → KWin → fcitx5 |

```console
$ ~/.local/share/fcitx5-host/bin/fcitx5-diagnose | grep -i qq
IC [12d9a68d...] program:qq frontend:dbus cap:6000000032 focus:1
```

**修好之前**,这个应用在列表里**压根不出现**(那条链没建起来);
**修好之后**出现 `frontend:dbus`。

### 在沙箱里做端到端验证(不用手点)

各 flatpak runtime 一般都带 `zenity`(GTK3 应用),可以直接当探针:

```bash
flatpak run --command=sh com.qq.QQ -c \
  'GDK_BACKEND=x11 GTK_IM_MODULE=fcitx \
   GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache \
   zenity --entry --text=hi' &
sleep 6
~/.local/share/fcitx5-host/bin/fcitx5-diagnose | grep -i zenity
# → IC [...] program:Zenity frontend:dbus     ✅
```

> `GDK_BACKEND=x11` 是必须的:不加的话 GTK3 会走 Wayland 后端,
> 拿到的是 `frontend:wayland` 的 IC,**证明不了 X11 + GTK IM 模块这条路**。

---

## 排除掉的假设(别再重复查)

| 曾经的假设 | 实测结论 |
|---|---|
| XIM 传输被沙箱挡住 | ❌ 不是。沙箱里 `XOpenIM` **成功**(纯 ctypes 调 libX11 即可验证)→ IM server 找得到、连得上 |
| flatpak 的 netns 隔离挡住了 IM | ❌ 不是。QQ flatpak `shared=ipc;network;`,netns 与宿主完全相同 |
| `org.fcitx.Fcitx5` 在沙箱里不可达 | ❌ 不是根因。沙箱里确实不通,但**不需要**它 —— runtime 的 `libFcitx5GClient` 走 `org.freedesktop.portal.Fcitx` 门户,那条路本来就通 |
| 需要额外 `--talk-name=org.fcitx.Fcitx5` | ❌ 不需要,加了也是多余的 |
| 宿主 fcitx5 daemon / `XIM_SERVERS` 注册异常 | ❌ 一直正常 |

诊断用的 XIM 探针脚本(纯 ctypes,不依赖第三方包):
`scripts/xim-test.py` —— 沙箱内也能跑(用 `flatpak run --command=python3 ... -` 从 stdin 喂进去)。

---

## 一句话总结

> **Chromium 的 X11 输入法靠 GTK3 的 IM 模块;而本仓库为了免 sudo 装 fcitx5,
> 不得不把 `GTK_IM_MODULE_FILE` 指向 `~/.local/share/fcitx5-host/` ——
> 这个路径在 flatpak 沙箱里不存在,于是沙箱里的 GTK 系应用集体没有输入法。
> 修法:用 flatpak override 把沙箱里的 `GTK_IM_MODULE_FILE` 改指 runtime 自带的 cache。**

---

## 相关

- [desktop-mode.md](desktop-mode.md) —— 桌面模式(fcitx5 + KWin Wayland 桥)详解
- [gaming-mode.md](gaming-mode.md) —— 掌机模式(Steam OSK + IBus)详解
- [troubleshooting.md](troubleshooting.md) —— 症状 → 原因 → 修法 对照表
- `scripts/fix-flatpak-ime.sh` —— 本文修法的一键脚本
