# capcap (Tiếng Việt)

![capcap](images/app-banner.png)

[English](README.md) &nbsp;·&nbsp; [简体中文](README.zh-CN.md) &nbsp;·&nbsp; [繁體中文](README.zh-TW.md)

**Cách nhanh nhất để chụp, chỉnh sửa, và chia sẻ ảnh màn hình trên macOS.** Nhấn đúp phím `⌘` ở bất kỳ đâu — chụp theo cửa sổ, kéo vùng chọn, ghép cuộn trang dài, rồi chú thích và làm đẹp trong một cửa sổ nổi gọn nhẹ. Chạy dạng menu bar (không hiện Dock icon), không telemetry, không subscription, không phụ thuộc bên thứ ba.

<p align="center">
  <img src="images/editor.png" alt="capcap annotation editor" width="760" />
</p>

<p align="center">
  <a href="https://github.com/realskyrin/capcap/releases/latest"><b>Tải bản mới nhất</b></a> &nbsp;·&nbsp;
  macOS 14+ &nbsp;·&nbsp; Universal (Apple Silicon + Intel)
</p>

## Tại sao capcap

- **Một phím tắt, gần như tức thì.** Nhấn đúp `⌘` để mở capcap trong vài mili-giây (hoặc tự đặt hotkey).
- **Chụp theo cửa sổ hoặc vùng chọn chuẩn pixel.** Hover cửa sổ để chụp một chạm, hoặc kéo vùng chọn với độ phân giải Retina đầy đủ.
- **Trình chú thích “thật”.** Mũi tên, đánh số, chữ, mosaic, highlighter, bút… có thể chỉnh sửa/di chuyển/undo sau khi đặt.
- **Ghép ảnh cuộn.** Chọn vùng cuộn, xem preview ghép trực tiếp và tiếp tục chỉnh sửa kết quả.
- **Làm đẹp & ghim ảnh.** Nền gradient/wallpaper, bo góc, shadow, padding hoặc ghim ảnh nổi lên trên mọi cửa sổ.
- **Lịch sử ngay trên menu bar.** Chép lại ảnh gần đây hoặc màu đã pick chỉ với một cú nhấp.
- **Tải lên tuỳ chọn.** Có thể cấu hình host ảnh của riêng bạn để lấy URL 1-click (tuỳ nhà cung cấp).
- **Thuần AppKit.** Không SwiftUI/Electron, không XIB/Storyboard.

## Yêu cầu quyền

- macOS 14.0+
- **Accessibility**: dùng cho trigger mặc định nhấn đúp `⌘`
- **Screen Recording**: dùng cho ScreenCaptureKit và chụp màn hình
- **Automation (Finder)**: sẽ hỏi khi dùng tính năng “sửa ảnh đang chọn trong Finder”

## Cài đặt

### Homebrew

Repo có Homebrew cask tại `Casks/capcap.rb`:

```bash
brew tap realskyrin/capcap https://github.com/realskyrin/capcap
brew install --cask capcap
```

### Build từ mã nguồn

```bash
# Build + bundle ra build/capcap.app
./scripts/bundle.sh
```

Dev local (rebuild, kill app đang chạy, mở app mới và verify):

```bash
bash scripts/rebuild-and-open.sh
```

## Cách dùng nhanh

1. Nhấn đúp `⌘` (hoặc hotkey tuỳ chỉnh) hoặc chọn **Take Screenshot** từ menu bar.
2. Hover cửa sổ và click để chụp, hoặc kéo để chọn vùng.
3. Dùng toolbar nổi để chú thích, pick màu, ghép cuộn, làm đẹp, lưu, ghim, huỷ, hoặc xác nhận.
4. Bấm dấu tick xanh hoặc `Enter` để copy ảnh vào clipboard. Bấm `Esc` hoặc `x` để huỷ.

### Sửa ảnh có sẵn trong Finder

Chọn đúng **1** file ảnh trong Finder, sau đó dùng cùng phím tắt. capcap sẽ copy ảnh sang vị trí tạm và mở vào editor; file gốc không bị sửa.

## Đóng góp

- Nếu bạn muốn góp bản dịch: chỉnh `Resources/vi.lproj/Localizable.strings`.
- Pull request: tạo nhánh từ `main`, commit gọn, mô tả rõ thay đổi và ảnh hưởng UI.

## Ghi chú

Tài liệu tiếng Việt này tập trung phần giới thiệu và hướng dẫn nhanh. Xem README tiếng Anh để đầy đủ các mục (showcase, tool list chi tiết, packaging, v.v.).

