# 截图美化功能设计

**日期**: 2026-04-09
**状态**: 已确认，进入实现
**目标**: 在截图编辑器中加入"一键美化"功能 — 为截图添加渐变背景、自适应边距、圆角和柔和阴影，让图片直接适合分享到社交平台。

## 需求概要

用户截图后，可以通过工具栏一键启用美化：
- 截图外层加自适应边距（相对短边的比例）
- 边距区域填充渐变背景（从 8 个预设中选）
- 截图本身带圆角和柔和阴影
- 实时预览（WYSIWYG），编辑器画布直接呈现最终效果
- 记住上次选择的预设

这是 **"一键美化，快速分享"** 定位 —— 少量精选预设，无滑杆无微调，点一下就能用。

## 核心决策（已确认）

| 主题 | 决策 |
|------|------|
| 功能定位 | 一键美化，8 个预设渐变，不做自定义面板 |
| 触发方式 | 工具栏新增"美化"按钮 → 弹出渐变色板子工具栏（与现有 ColorSizeSubToolbar 同构）|
| 画框风格 | 紧凑优雅：边距较小、圆角 12pt、柔和阴影（参考图同款）|
| 预览方式 | 所见即所得 — 画布扩大到包含渐变边框，标注偏移后渲染 |
| 预设数量 | 8 个渐变预设（粉蓝、薄荷青、桃粉、蓝紫梦、暖橘黄、青粉、深邃紫、中性灰）|
| 持久化 | 记住最后选的预设 ID，不记开关状态（每次默认关）|
| 与标注的关系 | 美化开启时点标注工具自动关美化；标注栈不被烧进像素，始终可 undo |

## 架构

### 新增文件

- **`capcap/Editor/BeautifyPreset.swift`** — 数据定义
  - `BeautifyPreset` 结构体：`id`、`displayName`（走 L10n）、`startColor`、`endColor`、`angleDegrees`
  - `static let defaults: [BeautifyPreset]` — 8 个预设
  - `static func preset(forID:) -> BeautifyPreset?` — 根据持久化 ID 查找

- **`capcap/Editor/BeautifyRenderer.swift`** — 渲染纯函数
  - `static func padding(for innerSize: CGSize) -> CGFloat` — 计算自适应边距
  - `static func outputSize(for innerSize: CGSize) -> CGSize` — `inner + 2·padding`
  - `static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage` — 产出成品
  - `static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset, context: CGContext)` — 画渐变
  - `static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext)` — 画阴影
  - 常量：`paddingRatio = 0.08`、`paddingMin = 32`、`paddingMax = 96`、`innerCornerRadius = 12`、`shadowBlur = 18`、`shadowOpacity = 0.18`

### 修改文件

- **`capcap/Editor/EditCanvasView.swift`**
  - 新字段 `private(set) var beautifyPreset: BeautifyPreset?`
  - 新方法 `setBeautify(_ preset: BeautifyPreset?)` — 切换时调整 `frame`（扩大/收回 padding），`needsDisplay = true`
  - 计算属性 `var isBeautifyEnabled: Bool`
  - 新字段 `private var innerImageSize: CGSize = .zero` — 记录"内层图的 point 尺寸"，独立于 `bounds`。由 `loadPreviewImage` / `updateViewportSize` 更新；`draw` / `compositeImage` / `setBeautify` 都用这个字段而不是 `bounds.size`，避免"美化开启时 bounds 已扩大导致 padding 算错"
  - 计算属性 `var currentPadding: CGFloat { BeautifyRenderer.padding(for: innerImageSize) }`
  - `draw(_:)` 增加美化分支：
    1. 画完整的渐变背景（`bounds` 全覆盖）
    2. 在 `innerRect` 底下画阴影
    3. 保存图形状态，裁剪到 `innerRect` 圆角路径
    4. 平移坐标系 `(padding, padding)`
    5. 执行原有的 `previewImage.draw` + `annotations.draw`（bounds 传入 `innerImageSize`）
    6. 恢复图形状态
  - `compositeImage(fallbackBaseImage:)` 增加尾部处理：先按原逻辑产出带标注的内层图，若 `beautifyPreset != nil` 再调 `BeautifyRenderer.render(innerImage: preset:)` 包一层
  - `loadPreviewImage` / `updateViewportSize` 要考虑美化开启时的 frame 计算

- **`capcap/Editor/EditWindowController.swift`**
  - `showToolbar()` 里给 `ToolbarView` 加 `onBeautify` 回调
  - `ToolbarView.setupButtons()` 增加 1 个按钮（图标 `sparkles`），放在 `scrollCapture` 之后、分隔线之前。总宽从 480 → 约 518
  - 新的 `BeautifySubToolbar` 类 —— 参考 `ColorSizeSubToolbar`：
    - 8 个直径 24 圆形色块（间距 8，两边内边距 12）
    - 当前选中的外圈加 2pt `accentGreen` 环
    - `onPresetSelected: (BeautifyPreset) -> Void` 回调
  - 新方法 `private func toggleBeautify()`：
    - 开启：从 `Defaults.lastBeautifyPresetID` 读预设（fallback 到 `defaults.first!`），`canvasView.setBeautify(...)`，显示 `BeautifySubToolbar`，按钮高亮，`updateEditorInteractionState()` 冻结选区拖拽
    - 关闭：`canvasView.setBeautify(nil)`，移除 sub-toolbar，按钮取消高亮
  - 新方法 `private func applyBeautifyPreset(_ preset: BeautifyPreset)`：`canvasView.setBeautify(preset)` + 写 `Defaults.lastBeautifyPresetID`
  - `selectTool(_:)` 里：若 `canvasView.isBeautifyEnabled == true`，先调 `toggleBeautify()` 关掉再进入标注工具
  - `startScrollCapture()` 里：同样先关美化再进入长截图
  - `updateEditorInteractionState()` 里：美化开启时关闭 `hostSelectionView.selectionInteractionEnabled`
  - `updateLayout` 里：如果美化开启且 layout 发生变化，重新计算 canvas 尺寸和 scrollView frame

- **`capcap/Utilities/Defaults.swift`**
  - 新增 `static var lastBeautifyPresetID: String?`
  - 新增 L10n 字符串 `beautify`（"美化" / "Beautify"）

- **`capcap/Capture/OverlayWindowController.swift`**（仅可能影响）
  - 不改动 —— overlay 窗口本身已经覆盖全屏，美化扩大的画布和 scrollView 只在 overlay 内部生长

### 不受影响

`ScreenCapturer`、`ScrollCapturer`、`ClipboardManager`、`PinContentView`、`PinWindowManager` — 下游统一拿到 `NSImage`，至于 `NSImage` 是原图还是美化图对它们透明。

## 数据模型

### BeautifyPreset

```swift
struct BeautifyPreset: Equatable {
    let id: String              // 稳定 ID，用于持久化
    let displayName: String     // L10n 后的显示名
    let startColor: NSColor
    let endColor: NSColor
    let angleDegrees: CGFloat   // 默认 135°（左上 → 右下）

    static let defaults: [BeautifyPreset] = [
        // id             displayName    startColor         endColor           angle
        .init(id: "peach-blue",   ..., startColor: #fde8ef, endColor: #c7d7f2, 135),
        .init(id: "mint-teal",    ..., startColor: #d4f1e5, endColor: #a7d8c6, 135),
        .init(id: "peach-pink",   ..., startColor: #fde1d3, endColor: #f9a8a8, 135),
        .init(id: "blue-purple",  ..., startColor: #c9d6ff, endColor: #e2b0ff, 135),
        .init(id: "warm-orange",  ..., startColor: #fef3c7, endColor: #fbbf85, 135),
        .init(id: "teal-pink",    ..., startColor: #a8edea, endColor: #fed6e3, 135),
        .init(id: "deep-purple",  ..., startColor: #667eea, endColor: #764ba2, 135),
        .init(id: "neutral-gray", ..., startColor: #e9ecef, endColor: #ced4da, 135),
    ]
}
```

（具体 RGB 值在实现时从上面的十六进制转成 `NSColor(red:green:blue:alpha:)`。`displayName` 走 `L10n`，L10n 表里加 8 个条目。）

### 框架布局常量

| 常量 | 值 |
|------|---|
| `paddingRatio` | `0.08`（相对内层图短边）|
| `paddingMin` | `32` pt |
| `paddingMax` | `96` pt |
| `innerCornerRadius` | `12` pt |
| `shadowBlur` | `18` |
| `shadowOpacity` | `0.18` |
| `shadowOffset` | `CGSize(width: 0, height: -6)` |

padding 计算：
```swift
static func padding(for innerSize: CGSize) -> CGFloat {
    let base = min(innerSize.width, innerSize.height) * paddingRatio
    return max(paddingMin, min(paddingMax, base))
}
```

### 持久化

```swift
// Defaults.swift
static var lastBeautifyPresetID: String? {
    get { defaults.string(forKey: "lastBeautifyPresetID") }
    set { defaults.set(newValue, forKey: "lastBeautifyPresetID") }
}
```

- 读：`BeautifyPreset.preset(forID: Defaults.lastBeautifyPresetID) ?? .defaults.first!`
- 写：切换渐变时立刻写

开关状态不持久化 —— 每次打开编辑器默认"关"。

## 核心绘制逻辑

### 两条渲染路径共享同一套几何

#### Path A — 实时预览（`EditCanvasView.draw`）

```swift
override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    if let preset = beautifyPreset {
        let innerSize = innerImageSize
        let padding = BeautifyRenderer.padding(for: innerSize)
        let innerRect = CGRect(x: padding, y: padding,
                               width: innerSize.width, height: innerSize.height)

        // 1. 渐变背景铺满 bounds
        BeautifyRenderer.drawBackground(in: bounds, preset: preset, context: context)

        // 2. 阴影（在内层图下方）
        BeautifyRenderer.drawInnerShadow(innerRect: innerRect,
                                         cornerRadius: BeautifyRenderer.innerCornerRadius,
                                         context: context)

        // 3. 裁剪到内层圆角区域 + 平移坐标系
        context.saveGState()
        let clipPath = CGPath(roundedRect: innerRect,
                              cornerWidth: BeautifyRenderer.innerCornerRadius,
                              cornerHeight: BeautifyRenderer.innerCornerRadius,
                              transform: nil)
        context.addPath(clipPath)
        context.clip()
        context.translateBy(x: padding, y: padding)

        // 4. 调用原有的"画内层"逻辑（传入 innerSize 作为 bounds）
        drawInnerContent(in: context, bounds: CGRect(origin: .zero, size: innerSize))

        context.restoreGState()
        return
    }

    // 非美化模式：完全沿用现在的 draw() 逻辑
    drawInnerContent(in: context, bounds: bounds)
}

private func drawInnerContent(in context: CGContext, bounds: CGRect) {
    // 抽取现有 draw() 的内容：
    // - previewImage.draw(in: bounds)
    // - for annotation in annotations { annotation.draw(in:, bounds:) }
    // - in-progress pen / shape / mosaic 预览
}
```

注意：`drawInnerContent` 是从当前 `draw(_:)` 抽出来的，行为不变。

#### Path B — 最终合成（`compositeImage`）

```swift
func compositeImage(fallbackBaseImage: NSImage?) -> NSImage? {
    guard let baseImage = previewImage ?? fallbackBaseImage else { return nil }

    // 1. 照旧产出带标注的"内层图"（innerImage，尺寸 = baseImage.size）
    let innerImage: NSImage
    if annotations.isEmpty {
        innerImage = baseImage
    } else {
        // 现有合成逻辑（不变）
        innerImage = ...
    }

    // 2. 若美化开启，再包一层
    if let preset = beautifyPreset {
        return BeautifyRenderer.render(innerImage: innerImage, preset: preset)
    }
    return innerImage
}
```

### BeautifyRenderer.render

```swift
static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage {
    let innerSize = innerImage.size
    let padding = padding(for: innerSize)
    let outerSize = CGSize(width: innerSize.width + 2 * padding,
                           height: innerSize.height + 2 * padding)
    let outerRect = CGRect(origin: .zero, size: outerSize)
    let innerRect = CGRect(x: padding, y: padding,
                           width: innerSize.width, height: innerSize.height)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(outerSize.width),
        pixelsHigh: Int(outerSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { return innerImage }

    // 保留 HiDPI 大小
    rep.size = outerSize

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return innerImage }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let cg = ctx.cgContext
    drawBackground(in: outerRect, preset: preset, context: cg)
    drawInnerShadow(innerRect: innerRect, cornerRadius: innerCornerRadius, context: cg)

    // 裁剪到内层圆角路径，绘制 innerImage
    cg.saveGState()
    let clip = CGPath(roundedRect: innerRect,
                      cornerWidth: innerCornerRadius,
                      cornerHeight: innerCornerRadius,
                      transform: nil)
    cg.addPath(clip)
    cg.clip()
    innerImage.draw(in: innerRect)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    let result = NSImage(size: outerSize)
    result.addRepresentation(rep)
    return result
}
```

### drawBackground（渐变）

```swift
static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset, context: CGContext) {
    guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
        return
    }
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext.current?.cgContext, ctx === context {
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    } else {
        // fallback: 手动用 CGGradient
    }
    NSGraphicsContext.restoreGraphicsState()
}
```

实际上 `NSGradient.draw(in:angle:)` 就够用，调用前确保 current context 正确。

### drawInnerShadow

```swift
static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
    context.saveGState()
    context.setShadow(
        offset: shadowOffset,
        blur: shadowBlur,
        color: NSColor.black.withAlphaComponent(shadowOpacity).cgColor
    )
    let path = CGPath(roundedRect: innerRect,
                      cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius,
                      transform: nil)
    context.addPath(path)
    context.setFillColor(NSColor.black.cgColor)  // 任意不透明色，阴影来自 shadow state
    context.fillPath()
    context.restoreGState()
}
```

注意：fill 的色会被 clip path 裁掉（随后绘制 innerImage 时覆盖上去），阴影留在外部。

## 交互流程

### 1. 进入编辑器
- `beautifyPreset = nil`，按钮未高亮
- sub-toolbar 不显示
- canvas frame = `selectionViewRect.size`（原尺寸）

### 2. 点"美化"按钮（关 → 开）
1. 读 `Defaults.lastBeautifyPresetID` → 找到对应预设（fallback 到 `defaults.first`）
2. `canvasView.setBeautify(preset)`
   - 内部：重新计算 `frame = innerImageSize + 2·padding`
   - 画布位置：尽量让美化后的图保持在 `scrollView` 可见区域的中心
3. 显示 `BeautifySubToolbar`，当前预设的色块外圈加高亮环
4. 按钮 `isSelected = true`
5. `updateEditorInteractionState()` → 冻结选区拖拽（selection handles 不响应）
6. `updateLayout` 不需要改 — 美化开关不依赖外部 layout 变化

### 3. 在 sub-toolbar 切换预设
1. `canvasView.setBeautify(newPreset)` — 尺寸不变（同一张图 padding 一样），只重绘背景
2. 写 `Defaults.lastBeautifyPresetID = newPreset.id`
3. sub-toolbar 更新高亮环位置

### 4. 关闭美化（再点"美化"按钮）
1. `canvasView.setBeautify(nil)` — frame 收回原尺寸
2. 移除 sub-toolbar
3. 按钮 `isSelected = false`
4. 恢复 `selectionInteractionEnabled`
5. 标注数据不丢失 — `annotations` 栈完整保留，可继续编辑

### 5. 美化开启时点标注工具
- `selectTool(tool)` 开头检测 `canvasView.isBeautifyEnabled`，若 true 先 `toggleBeautify()` 关闭美化，再进入工具模式
- 实现上：一个隐式的"自动关闭"，用户感觉"点了画笔，画笔亮了，美化按钮灭了"

### 6. 美化开启时点长截图
- `startScrollCapture()` 同样先检测并关美化
- 长截图完成 → `loadPreviewImage(stitched)` → 此时 previewImage 换成长图，`innerImageSize` 跟着变；用户可以再次点美化应用到长图

### 7. 确认 / 保存 / Pin
- 全部走 `currentCompositeImage()`，它内部调 `compositeImage(fallbackBaseImage:)`
- `compositeImage` 在美化开启时返回已打好框的 `NSImage`
- Pin 窗口用 `finalImage.size`（美化后的尺寸）— pin 出来就是美化过的
- 保存 PNG / 复制到剪贴板同理

### 8. Undo
- `undo()` 弹出 `annotations` 栈最后一项
- 美化开启 / 关闭都不影响 undo 行为
- 美化本身的切换不进 undo 栈

## UI 细节

### 主工具栏按钮变化

当前布局（12 个）：
```
[rect] [ellipse] [arrow] [pen] [mosaic] [#] [undo] [scroll] ‖ [save] [pin] [x] [✓]
```

新布局（13 个）：
```
[rect] [ellipse] [arrow] [pen] [mosaic] [#] [undo] [scroll] [✨] ‖ [save] [pin] [x] [✓]
```

`ToolbarView.setupButtons()` 里：
- `totalButtons` 从 12 → 13
- `totalWidth = 13 × 32 + 12 × 6 + 8 = 488`（分隔符 8pt）
- 工具栏自身宽度 `toolbarRect` 的 `width` 从 480 → 488（勉强够，稍后调整）

美化按钮：
- SF Symbol `sparkles`
- `normalColor = .white`
- `selectedColor = accentGreen`
- 放在 scrollCapture 之后，分隔线之前
- 加 `beautifyBtn` 作为类属性，方便 `setScrollCaptureActive` 风格的 `setBeautifyActive(_:)`

### BeautifySubToolbar

```swift
class BeautifySubToolbar: NSView {
    var onPresetSelected: ((BeautifyPreset) -> Void)?
    var currentPresetID: String? { didSet { needsDisplay = true } }

    private let swatchDiameter: CGFloat = 24
    private let swatchSpacing: CGFloat = 8
    private let innerPadding: CGFloat = 12

    // 宽 = 12 + 8×24 + 7×8 + 12 = 272
    // 高 = 36

    override init(frame: NSRect) { ... }
    override func draw(_ dirtyRect: NSRect) {
        // 圆角 8pt 背景 (NSColor(white: 0.12, alpha: 0.9))
    }

    private func setupSwatches() {
        // 8 个 SwatchButton，每个渲染自己的预设渐变
        // 点击时 -> onPresetSelected(preset) + currentPresetID = preset.id
    }
}

private class SwatchButton: NSButton {
    let preset: BeautifyPreset
    var isSelected: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // 画渐变圆
        // 若 isSelected，外圈加 2pt accentGreen 环
    }
}
```

### 文案

`Defaults.swift` 的 `L10n` 段新增：
```swift
static var beautify: String { lang == .zh ? "美化" : "Beautify" }
```

预设的 `displayName` 可选：直接硬编码中英文字符串对，或者在 `L10n` 里加 8 个（倾向后者，一致）。实现时决定。

## 边界情况和风险

1. **选区很小（例如 50×50）**  
   padding = max(32, min(96, 50 × 0.08)) = 32。外层尺寸 = 114×114，勉强可接受。再小（例如 20×20）：外层 = 84×84。视觉上 padding 比图还大，但因为截图本来就小，结果仍然符合"小图也要好看"的预期。

2. **选区很大（例如全屏 2560×1440）**  
   padding = max(32, min(96, 1440 × 0.08)) = 96。外层 = 2752×1632，不会失控。

3. **美化后的画布超出 selectionViewRect 范围**  
   这是正常情况。`EditorScrollView`（`NSScrollView`）的 `documentView` 会变大，scroller 会出现（或被 autohide 藏起）。  
   但问题是：scrollView.frame 本身 = `selectionViewRect`，对于一个 300×200 的选区，即使启用美化，用户也只能看到 300×200 的内容，美化区域需要滚动才能看到。  
   **解决方案**：美化开启时，同步扩展 `canvasScrollView.frame` 到 `min(outerSize, overlayBounds)`，并将其居中在选区位置。`updateLayout` 和 `toggleBeautify` 两处都要考虑。

4. **长截图 + 美化**  
   长截图产出一张非常高的图（可能 800×5000）。padding = max(32, min(96, 800×0.08)) = 64。外层 = 928×5128。这个尺寸丢进剪贴板/保存没问题。编辑器里原本就有滚动，美化后继续有滚动。

5. **美化开启时拖动选区**  
   决定：美化开启时 `selectionInteractionEnabled = false`，禁止拖动。简单且一致。

6. **retina 分辨率 / HiDPI**  
   `BeautifyRenderer.render` 用 `NSBitmapImageRep` 直接按像素创建时，需要考虑 retina。目前项目其他地方用 `NSImage.pngDataPreservingBacking()` 之类方法保持 backing scale。  
   **策略**：`render` 里按 point 尺寸创建 bitmap，然后手动乘以 backing scale factor 创建高分辨率 bitmap。或直接复用 `NSImage` + `lockFocus`/`unlockFocus` 的路径（更简单但性能稍差）。实现时先用 `lockFocusFlipped(false)` 路径，测量后再优化。

7. **暗/亮模式下渐变色**  
   渐变颜色硬编码为亮色系，不跟随系统主题。设计就是这样 —— 截图美化的背景是发给别人看的，固定颜色更稳定。

## 测试计划

capcap 没有单元测试传统，验证主要靠手动流程：

1. **基本流程**：截图 → 不标注 → 点美化 → 默认渐变应用 → 确认 → 剪贴板粘贴查看效果
2. **切换预设**：截图 → 点美化 → 依次点 8 个预设确认实时刷新
3. **先标注后美化**：截图 → 画几个标注 → 点美化 → 标注应该"嵌"在内层图里 → 确认 → 粘贴验证
4. **美化中点标注**：美化开启 → 点画笔 → 美化应自动关，画笔激活 → 画完再点美化 → 标注仍在
5. **Undo**：先美化（不画）→ 关美化 → 画标注 → undo → 标注消失；或先画标注 → 美化 → undo → 内层图的标注减少
6. **长截图 + 美化**：滚动截图产出长图 → 点美化 → 长图带框显示 → 确认
7. **持久化**：选中预设 3 → 关闭 capcap → 重启 → 截图 → 点美化 → 默认是预设 3
8. **选区边缘情况**：截非常小的区域（< 100px），美化后不崩；截全屏，美化后不崩
9. **Pin 窗口**：美化 + pin → pin 窗口大小匹配美化后尺寸
10. **保存为文件**：美化 + save → PNG 文件大小和内容正确
11. **编译检查**：`bash scripts/compile-check.sh`
12. **运行验证**：`bash scripts/rebuild-and-open.sh`

## 不做的事（YAGNI）

- 不做自定义渐变颜色选择器
- 不做 padding / corner / shadow 的滑杆
- 不做多种边框风格（阴影、描边、窗口装饰条等 — 只有一种"紧凑优雅"）
- 不做渐变方向选择（固定 135°）
- 不做设置页面里的美化配置项
- 不做美化状态的 undo
- 不改变截图流程、剪贴板逻辑、pin 机制
- 不做深色/亮色两套预设

以上都是后续可扩展点，当前版本专注于"能用、好看、一键"。
