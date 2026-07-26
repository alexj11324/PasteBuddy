# Screen Capture, Screen Pins, OCR, and Translation

PasteBuddy follows the interaction scope documented by PixPin while using native
macOS frameworks and PasteBuddy's existing history, asset, copy HUD, and stable
runtime owners. The reference behavior was inventoried from:

- [Static capture](https://pixpin.cn/docs/capture/static-capture)
- [Long capture](https://pixpin.cn/docs/capture/long-capture)
- [Pin basics](https://pixpin.cn/docs/pin/base-use), [image](https://pixpin.cn/docs/pin/image),
  [text](https://pixpin.cn/docs/pin/text), [file](https://pixpin.cn/docs/pin/file),
  [color](https://pixpin.cn/docs/pin/color), [LaTeX](https://pixpin.cn/docs/pin/latex),
  and [groups](https://pixpin.cn/docs/pin/pin-group)
- [Translation](https://pixpin.cn/docs/other/translate)

## Feature matrix

| Area | PasteBuddy behavior | Native/shared owner |
|---|---|---|
| Static trigger | Menu and Command-Shift-2; stable development control supports `--open-capture static` | Existing global hot-key owner and `ScreenshotCaptureCoordinator` |
| Selection | Custom area, AX UI-element bounds when Accessibility is trusted, otherwise frontmost CGWindow bounds; manual dimensions and recent-region recall | SwiftUI session model with one AppKit overlay |
| Precision | Arrow-key move; Shift/Control plus arrow resizes the corresponding edge by one pixel; free, 1:1, and current-aspect locks | `CaptureSelectionGeometry` |
| Capture presentation | Magnifier, pixel color display/copy, delay presets, optional cursor, rounded corners, border, and shadow | ScreenCaptureKit/CoreGraphics and native SwiftUI controls |
| Completion | Copy, save PNG, screen pin, and automatic insertion into existing PasteBuddy history/assets | `CapturedImageHistoryWriter`, `PasteboardWriter`, and shared copy HUD |
| Long capture | User-controlled vertical or horizontal scrolling, incremental overlap matching, live preview/progress/status, start/stop/cancel, along-axis region movement, leading/trailing crop, copy/save/pin/history | `LongScreenshotController` and `LongScreenshotAccumulator` |
| Long-capture failures | Dynamic, repetitive, nonmatching, and multi-scroll content fail visibly with diagnostics | `LongScreenshotOverlapMatcher` |
| Long-capture safety | 64,000,000 output pixels, 80,000 px per dimension, 500 frames, and 96,000,000 retained source pixels | `LongScreenshotLimits` |
| Screen pins | Screenshot, history card, or clipboard image/text/file/color/LaTeX; native floating windows with move, nudge, zoom, opacity, lock, always-on-top, click-through recovery, close/destroy, drag, title, save, and recent restore | `ScreenPinController` and `ScreenPinRegistry` |
| Pin groups | Create/select groups; show, hide, close, and save all | Existing status-menu owner and `ScreenPinRegistry` |
| OCR and codes | Local Vision multilingual text recognition plus QR/barcode recognition; selectable/drag-enabled text, copy all, copy code, and safe HTTP(S) open action | Shared `OCRService` |
| Translation | System language detection/selection and native Translation session; original and translated text, copy, and translated-text pin | `NativeTranslationService` and the existing pin window |
| Stable TCC/runtime | Capture controls target only the installed integrated development bundle and reuse its single process, bundle identity, signing requirement, and history | `script/build_and_run.sh` stable control gate |

## Deliberate boundaries

- Screen recording is excluded. PasteBuddy does not add a recording pipeline,
  recording menu, or recording permission flow.
- Broad annotation tools are deferred.
- Vision table/formula extraction is not presented as supported because the native
  path is not reliable enough for this delivery.
- Clipboard LaTeX is pinned as selectable source text. Native macOS does not supply
  a general LaTeX renderer, and this delivery adds no cloud service or dependency.
- Native Translation is used only where the installed macOS version supports the
  direct Translation session. Older systems fail visibly; there is no paid or
  secret-backed fallback.
- The long-capture limits above are PasteBuddy safety limits, not PixPin's
  advertised maximum. A 64-million-pixel RGBA image is approximately 256 MB before
  framework and export overhead; retained source frames stop at approximately
  384 MB of raw RGBA before output rendering.

## Delivery gate

Unit tests cover geometry, overlap/stitching, limits, state transitions, pin
semantics, OCR parsing, translation preconditions, stable control routing, and
localization. Final acceptance additionally requires one signed stable install,
Screen Recording permission against that bundle identity, real static/long/pin/OCR/
translation UI evidence, one PasteBuddy Dev process, and the authoritative
PasteBuddy Dev database unchanged.
