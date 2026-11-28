# capcap Agent Tools

`capcap-agent-tools` 是给支持 Skill 的代码代理使用的视觉工具 Skill。它教代理通过 capcap 的无界面命令 `capcap agent` 截图、枚举窗口、编辑图片、添加标注，并把结果保存成 PNG 和 JSON 元数据

这个 Skill 适合这些场景

- 用户已经上传了一张图，希望代理加红框、箭头、文字、模糊、马赛克、放大镜或编号标记
- 用户希望代理自动截取当前屏幕、前台窗口、鼠标所在屏幕或指定窗口
- 用户报告 UI 视觉问题，希望代理生成带标注的截图证据
- 用户需要代理在不打开 capcap 编辑器的情况下产出最终图片

## 如何安装 Skill

把整个目录保留为下面的结构

```text
capcap-agent-tools/
  SKILL.md
  README.md
```

在 capcap 仓库中，这个 Skill 已经位于

```text
.agents/skills/capcap-agent-tools
```

如果要在其他项目或全局环境使用它，把 `capcap-agent-tools` 目录复制到你的代理支持的 Skill 目录中，例如

```text
~/.codex/skills/capcap-agent-tools
```

不同代理的 Skill 搜索目录可能不同。复制后重新打开会话，或按代理文档刷新 Skill 索引

## 如何触发 Skill

在对话中直接点名这个 Skill，或描述一个明显需要截图、标注、图片编辑、视觉证据的任务

```text
@capcap-agent-tools/ 给这张图加一个红色箭头指向按钮
```

```text
用 capcap-agent-tools 截取前台窗口，并标出顶部工具栏的问题
```

如果用户已经上传或粘贴了图片，代理应当使用这张原图作为输入。不要重新截图聊天窗口、浏览器页面或桌面上的图片副本，除非用户明确要求重新截图

## 设备配置

### 1. 安装带有 Agent Tools 的 capcap

确认设备上安装的 capcap 版本支持 `agent` 子命令。已安装应用通常位于

```bash
/Applications/capcap.app
```

先设置一个 `CAPCAP` 环境变量，后续命令都使用它

```bash
CAPCAP="/Applications/capcap.app/Contents/MacOS/capcap"
```

如果 capcap 安装在其他位置，可以用 bundle identifier 查找

```bash
CAPCAP="$(mdfind 'kMDItemCFBundleIdentifier == "cn.skyrin.capcap"' | head -n 1)/Contents/MacOS/capcap"
```

在开发仓库里测试本地构建时，先编译再使用 debug binary

```bash
bash scripts/compile-check.sh
CAPCAP=".build/debug/capcap"
```

不要默认假设 `capcap` 已经在 `PATH` 中。裸命令只有在用户自己创建了 alias、wrapper 或 symlink 后才可用

```bash
alias capcap='/Applications/capcap.app/Contents/MacOS/capcap'
```

### 2. 在 capcap 设置中开启 Agent 命令行

`capcap agent` 默认关闭，因为它可以借用 capcap 的屏幕录制权限截屏和读取窗口标题。打开 capcap 设置 -> 权限，开启 `Agent 命令行`。未开启时，`help` 和各子命令的 `--help` 仍可使用，其他调用都会以退出码 77 失败，错误码为 `agent_disabled`

### 3. 授予 macOS 权限

截图功能需要 macOS 屏幕录制权限

打开 `System Settings` -> `Privacy & Security` -> `Screen Recording`，给实际运行 `capcap agent` 的应用或宿主授权

- 使用 `/Applications/capcap.app/Contents/MacOS/capcap` 时，给 capcap 授权
- 从 Terminal、Codex 或其他代理宿主运行 debug binary 时，按系统提示给对应宿主授权
- 授权后重新运行命令，必要时重启代理会话或终端

只对已有图片执行 `agent annotate` 通常不需要屏幕录制权限，因为它不会捕获屏幕

### 4. 准备可写输出目录

建议代理把中间文件写入临时目录

```bash
tmpdir="$(mktemp -d)"
```

输出文件通常包含

- 原始截图，例如 `shot.png`
- 标注后的结果，例如 `result.png`
- 元数据，例如 `shot.json` 或 `result.json`
- 标注规格，例如 `marks.json`

## 快速验证

检查二进制是否可运行

```bash
"$CAPCAP" agent --help
```

列出窗口

```bash
"$CAPCAP" agent windows --limit 5 --pretty
```

截取鼠标所在屏幕

```bash
tmpdir="$(mktemp -d)"
"$CAPCAP" agent capture \
  --target mouse-screen \
  --out "$tmpdir/shot.png" \
  --meta "$tmpdir/shot.json" \
  --pretty
```

给已有图片加标注

```bash
"$CAPCAP" agent annotate \
  --input "$tmpdir/shot.png" \
  --spec "$tmpdir/marks.json" \
  --out "$tmpdir/result.png" \
  --meta "$tmpdir/result.json" \
  --pretty
```

## 常用工作流

### 编辑用户提供的图片

1. 把用户提供的图片保存为输入文件
2. 读取图片尺寸并检查要标注的位置
3. 写入 `marks.json`
4. 运行 `agent annotate`
5. 把生成的 PNG 返回给用户

核心命令

```bash
"$CAPCAP" agent annotate \
  --input input.png \
  --spec marks.json \
  --out result.png \
  --meta result.json \
  --pretty
```

### 截图后再标注

1. 用 `agent capture` 截图
2. 检查截图内容
3. 写入 `marks.json`
4. 用 `agent annotate` 渲染最终图片

核心命令

```bash
"$CAPCAP" agent capture --target frontmost-window --out shot.png --meta shot.json --pretty
"$CAPCAP" agent annotate --input shot.png --spec marks.json --out result.png --meta result.json --pretty
```

### 一步截图并渲染

当代理已经知道截图目标和标注位置时，可以使用 `agent run`

```bash
"$CAPCAP" agent run \
  --target rect \
  --rect 0,0,800,600 \
  --spec marks.json \
  --out result.png \
  --shot-out shot.png \
  --meta result.json \
  --pretty
```

### 捕获指定窗口

先列出窗口

```bash
"$CAPCAP" agent windows --owner Safari --limit 10 --pretty
```

再使用返回的 `windowID`

```bash
"$CAPCAP" agent capture \
  --target window-id \
  --window-id 12345 \
  --out shot.png \
  --meta shot.json \
  --pretty
```

## 标注规格

`marks.json` 使用图片像素坐标，原点在左上角

```json
{
  "version": 1,
  "coordinateSpace": "pixels",
  "origin": "top-left",
  "annotations": [
    {
      "type": "rect",
      "rect": [80, 80, 280, 120],
      "color": "#FF3B30",
      "lineWidth": 5
    },
    {
      "type": "arrow",
      "from": [520, 240],
      "to": [350, 140],
      "color": "#FF3B30",
      "lineWidth": 6
    },
    {
      "type": "text",
      "at": [92, 52],
      "text": "Agent note",
      "fontSize": 28,
      "color": "#FF3B30",
      "stroke": true
    }
  ]
}
```

常用标注类型

- `rect`、`ellipse`
- `arrow`、`line`
- `text`、`number`
- `mosaic`、`blur`
- `magnifier`
- `pen`、`marker`

## 运行所需条件

- macOS 14 或更新版本
- 已安装支持 `capcap agent` 的 capcap，或在开发仓库中成功构建 `.build/debug/capcap`
- 支持读取本目录 `SKILL.md` 的代理环境
- 可访问的 shell 环境
- 对输出目录有写入权限
- 截图任务需要屏幕录制权限
- 编辑已有图片时，代理必须能访问原始图片文件

开发仓库本地运行还需要

- Xcode 或 Xcode Command Line Tools
- Swift Package Manager
- 可执行 `bash scripts/compile-check.sh`

## 常见问题

`capcap: command not found`

设置 `CAPCAP="/Applications/capcap.app/Contents/MacOS/capcap"`，或创建 alias、wrapper、symlink

`agent` 子命令不存在

当前 capcap 版本太旧，需要安装包含 Agent Tools 的版本，或在当前仓库重新构建 debug binary

截图失败或输出为空

检查屏幕录制权限是否授予了实际运行命令的应用或宿主，然后重试

窗口选择不稳定

先运行 `agent windows --pretty`，再用稳定的 `windowID` 捕获

标注位置上下颠倒

标注规格使用图片像素坐标，原点在左上角，不是 AppKit 的左下角坐标

系统菜单、弹窗或高层窗口干扰结果

默认先不用 `--all`。只有确实需要捕获菜单栏、控制中心或系统浮层时，再加 `--all` 或 `--include-system`

## 新版自描述与校验流程

先运行 `"$CAPCAP" agent schema --pretty` 获取安装版本的字段、样式和预设，再用 `agent displays --pretty` 获取显示器与权限状态。建议固定使用窗口 ID 截图，检查 PNG 后，通过 `agent validate --input shot.png --spec marks.json` 校验，再执行 `agent annotate`

新版支持聚光灯、原图尺寸校验、裁剪和原生美化。未知字段、冲突的截图参数与互相覆盖的文件路径会明确报错；失败时 stderr 返回 JSON，方便代理读取原因并重试。编辑器工具栏也提供 `capcap.toolbar.*` 辅助功能标识

可复现的真实案例见 [README 示例图工作流](examples/readme-demo/README.md)
