# PlayTools 维护与测试说明

完整的双仓库构建、运行时架构与各专项边界统一维护于主仓库手册：[`PlayCover/SESSION_MODIFICATIONS.md`](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md)（本地双仓库工作区可直接查阅 `../PlayCover/SESSION_MODIFICATIONS.md`），2026-11-23 性能与兼容性基准对照见 [`PERFORMANCE_REVIEW.md`](https://github.com/Rengwang/PlayCover/blob/develop/PERFORMANCE_REVIEW.md)。

## 核心模块概览

- **能效、自适应帧率与悬浮监测**：[PlayEfficiencyHooks.h](PlayTools/PlayEfficiencyHooks.h) / [PlayEfficiencyHooks.m](PlayTools/PlayEfficiencyHooks.m)（省电/省内存模式、`NSCache`/`NSURLCache` 与 `CAMetalLayer`/视频限制、多档与 iOS 语义自适应 `1–60 FPS`、`fpsOverlay` 实时悬浮窗、窗口遮挡降频与深色不透明回退）。
- **加载器与兼容性拦截**：[PlayLoader.m](PlayTools/PlayLoader.m)、[PlaySettings.swift](PlayTools/PlaySettings.swift)、[PlayInfo.swift](PlayTools/Utils/PlayInfo.swift)（App Group 迁移、弱框架守护、开屏广告通用拦截、`PT_RISK_*` 结构化风控中性化）。
- **场景与外设兼容**：[PlayScreen.swift](PlayTools/PlayScreen.swift)、[CameraCompatibility.m](PlayTools/CameraCompatibility.m)、[LocationCompatibility.m](PlayTools/LocationCompatibility.m)、[DuoVerticalBarCompatibility.m](PlayTools/DuoVerticalBarCompatibility.m)、[OneNoteSceneCompatibility.m](PlayTools/OneNoteSceneCompatibility.m)、[CTPocketOutputCompatibility.mm](PlayTools/CTPocketOutputCompatibility.mm)、[OptionScrollZoomController.swift](PlayTools/Controls/OptionScrollZoomController.swift)。

## 自动化测试套件（`Tests/`）

- `python3 Tests/check-compat-invariants.py`：源码与已安装构建产物全量不变式检查（最近运行 **147 passed / 0 failed**）。
- `python3 Tests/check-input-lifecycle.py`：手柄/触摸状态机、后台零分发及滑动计时器对象释放回归。
- `python3 Tests/check-option-scroll-zoom.py`：Option + 滚轮缩放手势回归。
- `python3 Tests/check-msc-mouse-bridge.py`：WebKit 鼠标转触控与指针去重回归。
- `python3 Tests/check-duo-vertical-bar.py` & `python3 Tests/check-global-back.py`：Duo 侧栏布局与全局返回手势回归。
- `python3 Tests/check-launch-crash-guards.py` & `python3 Tests/check-wireless-insights-compat.py`：启动防崩守护与 `WirelessInsights` 兼容存根回归。
