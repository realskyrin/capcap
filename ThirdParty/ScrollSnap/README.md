# ScrollSnap 来源说明

- 上游项目：[Brkgng/ScrollSnap](https://github.com/Brkgng/ScrollSnap)
- 固定版本：`74a613b4cbbfaa689ad3fd80043d5be79b7bc99a`
- 上游文件：[ScrollSnap/Managers/StitchingManager.swift](https://github.com/Brkgng/ScrollSnap/blob/74a613b4cbbfaa689ad3fd80043d5be79b7bc99a/ScrollSnap/Managers/StitchingManager.swift)
- 本地改编文件：`capcap/Capture/ScrollStitcher.swift`
- 许可证：MIT，Copyright (c) 2025 Berker Gungor，完整文本见 [LICENSE](LICENSE)

capcap 采用并改编其中的多区域重叠匹配和拼接状态处理，包括回滚时保留已捕获内容、匹配失败时保留可靠参考帧。改编用于接入 capcap 自己的串行采集队列、预览和结束状态，并将精匹配改为逐行校验以避免 Retina 重复像素行造成一像素位移误差；界面、ScreenCaptureKit 采集、编辑及上传流程仍由 capcap 提供。

本地及发布打包流程会把许可证复制到 `capcap.app/Contents/Resources/ScrollSnap-LICENSE.txt`
