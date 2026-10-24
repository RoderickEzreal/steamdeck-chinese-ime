#!/usr/bin/env python3
"""探测当前环境能不能连上 XIM 输入法服务器(不依赖任何第三方包,纯 ctypes)。

用途:证明「XIM 传输被 flatpak 沙箱挡住」这个假设是**错的** ——
沙箱里 XOpenIM 也能成功。排查 flatpak 应用输入法问题时先跑它,可以快速排除一整类假设。

用法:
    python3 scripts/xim-test.py

在 flatpak 沙箱里跑(脚本不在沙箱可见路径时,用 stdin 喂进去):
    flatpak run --command=python3 com.qq.QQ - < scripts/xim-test.py

退出码:0 = XIM 链路可用;1 = XOpenIM 失败;2 = 连不上 X server
"""
import ctypes
import ctypes.util
import locale
import os
import sys

X11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")

X11.XOpenDisplay.restype = ctypes.c_void_p
X11.XOpenDisplay.argtypes = [ctypes.c_char_p]
X11.XOpenIM.restype = ctypes.c_void_p
X11.XOpenIM.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                        ctypes.c_void_p]
X11.XSetLocaleModifiers.restype = ctypes.c_int
X11.XSetLocaleModifiers.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
X11.XCreateIC.restype = ctypes.c_void_p
X11.XCreateIC.argtypes = [ctypes.c_void_p]          # 可变参数:名字/值成对,末尾 None 收尾
X11.XDisplayString.restype = ctypes.c_char_p
X11.XDisplayString.argtypes = [ctypes.c_void_p]
X11.XFree.restype = ctypes.c_int
X11.XFree.argtypes = [ctypes.c_void_p]

print("== 环境 ==")
for k in ("DISPLAY", "WAYLAND_DISPLAY", "XMODIFIERS", "XAUTHORITY",
          "XDG_RUNTIME_DIR", "GTK_IM_MODULE", "QT_IM_MODULE",
          "GTK_IM_MODULE_FILE", "LANG", "LC_ALL"):
    print(f"  {k} = {os.environ.get(k)!r}")
print(f"  locale = {locale.setlocale(locale.LC_ALL, None)}")

dpy = X11.XOpenDisplay(None)
if not dpy:
    print("\nXOpenDisplay 失败 —— 连不上 X server")
    sys.exit(2)
print(f"\nXOpenDisplay OK: {X11.XDisplayString(dpy).decode()}")

try:
    locale.setlocale(locale.LC_ALL, "")
except Exception as e:                                   # pragma: no cover
    print(f"  (setlocale 警告: {e})")

# 告诉 X server 我们要用哪个 IM server(fcitx5 注册的名字就是 "fcitx")
X11.XSetLocaleModifiers(dpy, b"@im=fcitx", None)

im = X11.XOpenIM(dpy, None, None, None)
if not im:
    print("\n*** XOpenIM 失败 ***")
    print("  X server 上没有可用的 XIM server,或者 transport 地址不可达。")
    print("  宿主上先查:XIM_SERVERS on root window 有没有 fcitx。")
    sys.exit(1)
print("XOpenIM OK —— XIM 链路可用")

# 建一个输入上下文。有的 IM server 要求 clientWindow,有的不接受 Display 指针,
# 两种都试一遍;这个结果只作参考,**结论看 XOpenIM**。
ic = X11.XCreateIC(im, b"inputStyle", b"XIMPreeditNothing", None)
if not ic:
    ic = X11.XCreateIC(im, b"inputStyle", b"XIMPreeditNothing",
                        b"clientWindow", dpy, None)
if ic:
    print("XCreateIC OK —— 完整可用")
    X11.XFree(ic)
else:
    print("XCreateIC 失败 —— IM 打开了但建不了输入上下文(与链路是否可用无关)")
X11.XFree(im)
