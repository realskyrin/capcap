# ScrollSnap 来源说明

- 上游项目：[Brkgng/ScrollSnap](https://github.com/Brkgng/ScrollSnap)
- 固定版本：`74a613b4cbbfaa689ad3fd80043d5be79b7bc99a`
- 上游文件：[ScrollSnap/Managers/StitchingManager.swift](https://github.com/Brkgng/ScrollSnap/blob/74a613b4cbbfaa689ad3fd80043d5be79b7bc99a/ScrollSnap/Managers/StitchingManager.swift)
- 本地改编文件：`capcap/Capture/ScrollStitcher.swift`
- 许可证：MIT，Copyright (c) 2025 Berker Gungor，完整文本见 [LICENSE](LICENSE)

capcap 借鉴并改编其中的累计拼接和恢复状态处理，包括回滚时保留已捕获内容、匹配失败时保留可靠参考帧，并接入 capcap 自己的串行采集队列、预览和结束状态。当前位移匹配复用 capcap 主线的 `ScrollFrameMatcher`，对高密度像素图补充要求多列位移唯一的逐字节重叠校验；界面、ScreenCaptureKit 采集、编辑及上传流程仍由 capcap 提供。

本地及发布打包流程会把许可证复制到 `capcap.app/Contents/Resources/ScrollSnap-LICENSE.txt`

本轮拼接存储参考 capcap main 的 `ScrollImageStitcher` 原始像素缓冲与独立缩略图做法，改用几何扩容并保留首帧像素格式；固定底栏从本实现验证的正文接缝处覆盖。测试中的高吸顶标题和单行底栏场景参考 capcap main 的 `ScrollImageStitcherTests`，不属于 ScrollSnap 原始测试。主线 `ScrollFrameMatcher` 已注明借鉴 [PR #222](https://github.com/realskyrin/capcap/pull/222)，当前匹配路径直接复用其正文移动证据与歧义校验，并保留该来源说明。
