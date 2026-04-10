# capcap

[English](README.md)

一款轻量、原生的 macOS 菜单栏截图工具。双击 `⌘ Command` 即可快速截取屏幕任意区域，截图可直接复制到剪贴板，或先进入标注编辑器再复制。

## 功能特性

- **即截即用**：拖拽选区后，截图直接复制到剪贴板
- **内置编辑器**：支持画笔标注和马赛克遮挡敏感信息
- **双击 `⌘` 触发**：不需要复杂快捷键，双击 Command 即可
- **多显示器支持**：可在多块屏幕之间无缝截图
- **Retina 清晰度**：在 HiDPI 屏幕上以完整 2x 分辨率截图
- **菜单栏应用**：常驻菜单栏，不占用 Dock

## 截图模式

| 模式 | 流程 |
|------|------|
| **Direct** | 选择区域后直接复制到剪贴板 |
| **Edit First** | 选择区域后进入标注界面，编辑完成后复制到剪贴板 |

可在设置中切换模式。

## 快速开始

### 环境要求

- macOS 14.0+
- 辅助功能权限（用于监听热键）
- 屏幕录制权限（ScreenCaptureKit 需要）

### 使用 Homebrew 安装

本仓库已提供 Homebrew cask，位于 `Casks/capcap.rb`。

由于仓库名是 `capcap`，而不是 `homebrew-capcap`，需要显式指定仓库 URL 进行 tap：

```bash
brew tap realskyrin/capcap https://github.com/realskyrin/capcap
brew install --cask capcap
```

发布和更新流程见 [docs/homebrew.md](docs/homebrew.md)。

### 构建

```bash
# 构建并打包为 .app
./scripts/bundle.sh
```

生成的应用位于 `build/capcap.app`。

### 运行

打开 `build/capcap.app` 后，菜单栏会出现相机图标。

### macOS 校验拦截

如果 macOS 弹出类似 `Apple 无法验证 “capcap” 是否包含恶意软件` 的提示，可以对你信任的应用包移除 quarantine 标记后再重新打开：

```bash
xattr -dr com.apple.quarantine /Applications/capcap.app
```

如果你运行的是本地构建版本，而不是 `/Applications` 里的副本，把路径替换成实际位置即可，例如：

```bash
xattr -dr com.apple.quarantine ./build/capcap.app
```

只应对你信任的构建执行这个命令，例如本仓库下载的版本或你本地自行构建的版本。

## 使用方法

1. 双击 `⌘ Command`，或从菜单栏点击 “Take Screenshot”
2. 拖拽选择截图区域
3. 完成，截图会自动进入剪贴板，可直接粘贴到其他应用

在 **Edit First** 模式下，选区完成后会出现工具栏，支持：

- **Pen**：自由画笔标注（默认红色）
- **Mosaic**：对区域打马赛克，隐藏敏感信息
- **Confirm**：确认并复制到剪贴板
- **Cancel**：取消并丢弃本次截图

## 技术栈

基于 Swift + AppKit + ScreenCaptureKit，使用 Swift Package Manager 打包，无第三方依赖。

## License

MIT
