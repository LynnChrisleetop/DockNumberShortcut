# Dock 数字快捷键

这是一个免费的原生 macOS 菜单栏程序，用全局快捷键控制 Dock 中的应用。

程序会自动读取当前 Dock 的应用顺序：

- `Command + 1`：访达
- `Command + 2` 及之后：按 Dock 中的应用顺序对应
- 最多支持到 `Command + 9`

应用未运行时会打开；已经运行但不在前台时会切换到前台；已经在前台时再次按下会隐藏它。
程序每 2 秒检查一次 Dock 顺序。你拖动 Dock 中的应用后，快捷键会自动更新。

## 编译

在终端进入这个目录并执行：

```sh
./build.sh
open DockNumberShortcut.app
```

`main.m` 是程序源码，`build.sh` 使用 macOS 自带的 Clang 编译。

首次使用时，到「系统设置 → 隐私与安全性 → 辅助功能」，允许“Dock 数字快捷键”。然后从菜单栏的 `⌘` 图标退出并重新打开程序。

要修改第几个快捷键对应的应用，编辑 `main.swift` 里的 `slots`，然后重新运行 `./build.sh`。
