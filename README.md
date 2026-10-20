# Dock 数字快捷键

这是一个免费的原生 macOS 菜单栏程序，用全局快捷键控制常用应用：

- `Command + 1`：访达
- `Command + 2`：Cursor
- `Command + 3`：ChatGPT
- `Command + 4`：Microsoft Edge
- `Command + 5`：飞书
- `Command + 6`：网易云音乐
- `Command + 7`：App
- `Command + 8`：系统设置

应用未运行时会打开；已经运行但不在前台时会切换到前台；已经在前台时再次按下会隐藏它。

## 编译

在终端进入这个目录并执行：

```sh
./build.sh
open DockNumberShortcut.app
```

`main.m` 是程序源码，`build.sh` 使用 macOS 自带的 Clang 编译。

首次使用时，到「系统设置 → 隐私与安全性 → 辅助功能」，允许“Dock 数字快捷键”。然后从菜单栏的 `⌘` 图标退出并重新打开程序。

要修改第几个快捷键对应的应用，编辑 `main.swift` 里的 `slots`，然后重新运行 `./build.sh`。
