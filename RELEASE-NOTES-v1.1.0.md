# v1.1.0 — flatpak 应用的中文输入(Chromium/Electron 的 GTK IM 模块)

发布日期:2026-10-24

v1.0.0 解决了桌面模式(fcitx5 + KWin Wayland 桥)和掌机模式(Steam OSK + IBus)。
但用了一段时间会发现第三类故障:**宿主上的应用一切正常,flatpak 沙箱里的应用
(QQ / Chrome / WeChat / WPS)一点中文都打不出来**。

这一版把这条链路彻底打通。

---

## ★ 根因

> **当代 Chromium 在 X11 下已经没有 XIM 了,只剩 GTK3 的 IM 模块。**
> 而本仓库为了免 sudo 把 fcitx5 装在 `~/.local/share/fcitx5-host/`,
> 必须导出 `GTK_IM_MODULE_FILE` 指向自己那份 `immodules.cache` ——
> **这个路径在 flatpak 沙箱里不存在**。

展开说:

1. **Chromium 的 XIM 已被移除。** 用 QQ 3.2.34(Electron 40 / Chromium 140)实测:

   ```console
   $ readelf --dyn-syms -W qq | grep -cE 'XOpenIM|XCreateIC'   # 0
   $ strings -a qq | grep -cE 'XMODIFIERS'                   # 0
   $ strings -a qq | grep -cE 'zwp_text_input_manager_v[13]'  # 2
   ```

   取而代之的是 `gtk_im_context_filter_keypress` / `_set_client_window` /
   `_get_preedit_string` 这些 dlsym 字符串 —— 运行期 dlopen GTK3 的 IM 模块。

   ⇒ **"给 flatpak 应用设 `XMODIFIERS=@im=fcitx` 就能用"这条老偏方彻底无效。**

2. **沙箱里 GTK IM 模块加载不了。** 本仓库导出的
   `GTK_IM_MODULE_FILE=$HOME/.local/share/fcitx5-host/share/gtk-3.0/immodules.cache`
   会**原样传进 flatpak 沙箱**(flatpak 隔离文件,不隔离环境变量),
   而该路径在沙箱里不存在:

   ```console
   $ flatpak run --command=sh com.qq.QQ -c 'ls /home/deck/.local/share/fcitx5-host/'
   ls: 无法访问 '/home/deck/.local/share/fcitx5-host/': 没有那个文件或目录
   ```

   ⇒ 沙箱里的 GTK3 读不到 cache → 加载不到 `im-fcitx5.so` → **完全没有输入法**。
   宿主上一切正常,所以这个故障**只出现在沙箱里**,极易误判成"flatpak 隔离的锅"。

3. 完整链路:

   ```
   Chromium(X11)
     → GTK3 的 IM 模块(im-fcitx5.so,runtime 自带)
     → libFcitx5GClient
     → org.freedesktop.portal.Fcitx 门户(flatpak 默认就允许 org.freedesktop.portal.*)
     → fcitx5 daemon
   ```

   **不需要** `--talk-name=org.fcitx.Fcitx5`,也**不需要** XIM。

---

## 修法

把沙箱里的 `GTK_IM_MODULE_FILE` 改指到**各 runtime 自带**的 cache
(`/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache`,里面已含 `im-fcitx5.so` 登记):

```bash
./scripts/fix-flatpak-ime.sh --apply
```

等价的原始命令:

```bash
# 全局:所有 flatpak
flatpak override --user \
  --env=GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache

# QQ 专属:额外拿掉 wayland socket
flatpak override --user --socket=x11 --nosocket=wayland \
  --env=GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache \
  com.qq.QQ
```

QQ 还要写 `qq-flags.conf`(`--ozone-platform=x11`),防止它的 wrapper 改用
`xvfb-run` 起虚拟显示 `:99` 而和 fcitx5(在 `:0`)错位。

> ⚠️ **改完必须重启 flatpak 应用**,环境变量是启动时注入的。

---

## 诊断金标准

`fcitx5-diagnose` 的 `frontend:` 字段直接告诉你每个输入上下文走的哪条链:

| `frontend:` | 含义 | 对应协议 |
|---|---|---|
| `xim` | X11 XIM | libX11 `XOpenIM`(Chromium **已不走**) |
| `dbus` | **GTK IM 模块** | `im-fcitx5.so` → `org.freedesktop.portal.Fcitx` |
| `wayland` | 原生 Wayland | `zwp_text_input_v3` → KWin → fcitx5 |

**应用压根不出现 = 那条链没建起来。** 修好之后 QQ 会出现:

```
IC [12d9a68d...] program:qq frontend:dbus cap:6000000032 focus:1
```

沙箱内端到端验证(不用手点,runtime 自带 `zenity`):

```bash
flatpak run --command=sh com.qq.QQ -c \
  'GDK_BACKEND=x11 GTK_IM_MODULE=fcitx \
   GTK_IM_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache \
   zenity --entry --text=hi' &
sleep 6
~/.local/share/fcitx5-host/bin/fcitx5-diagnose | grep -i zenity
# → IC [...] program:Zenity frontend:dbus     ✅
```

---

## 本次改动

| 文件 | 说明 |
|---|---|
| `docs/flatpak-apps.md` | **新增** —— 完整根因分析、证据、修法、排除掉的假设 |
| `scripts/fix-flatpak-ime.sh` | **新增** —— 一键修复/诊断(默认只读,`--apply` 才动手) |
| `scripts/check-ime.sh` | 新增 **C 段**:flatpak 应用检查(宿主 env / 沙箱 env / 输入上下文) |
| `install/install-desktop-ime.sh` | 新增 **5/8 步**:安装时自动修好 flatpak 应用 |
| `docs/troubleshooting.md` | 新增 5 行症状对照 + 诊断命令 |
| `README.md` | 新增「第三个坑」章节、目录结构、FAQ、中英文摘要 |

`check-ime.sh` 自检从 13 项增加到 **15 项,全部通过**。

---

## 排除掉的假设(省下后来人的时间)

| 曾经的假设 | 实测结论 |
|---|---|
| XIM 传输被沙箱挡住 | ❌ 沙箱里 `XOpenIM` **成功** |
| flatpak 的 netns 隔离挡住了 IM | ❌ QQ flatpak `shared=ipc;network;`,netns 与宿主相同 |
| `org.fcitx.Fcitx5` 在沙箱里不通 | ❌ 确实不通,但**不需要** —— 门户那条路本来就通 |
| 需要额外 `--talk-name=org.fcitx.Fcitx5` | ❌ 多余 |
| 宿主 daemon / `XIM_SERVERS` 注册异常 | ❌ 一直正常 |

---

## 升级方式

```bash
git pull
./install/install-desktop-ime.sh     # 会自动跑 flatpak 修复
./scripts/check-ime.sh
```

只想修 flatpak 的话:

```bash
./scripts/fix-flatpak-ime.sh --apply
```

然后**重启** QQ / Chrome / WeChat。
