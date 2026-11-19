# PlayTools 智能窗口适配与自动化通道改动整理

本仓库为 [`PlayCover/PlayTools`](https://github.com/PlayCover/PlayTools)（基线 `master@fbc8880`）的个人 Fork，配合宿主端 [`Rengwang/PlayCover`](https://github.com/Rengwang/PlayCover) 实现 **Smart Auto-Adapt 双模式窗口引擎**、**通用自定义 `UICollectionViewLayout` 懒计算修复**、**Sidecar 副屏定位** 与 **进程内零抢鼠标自动化 IPC**。

> 完整的全项目（含宿主端 `PlayCover` 与多应用实机验证报告）整理请见 [`Rengwang/PlayCover` 的 `SESSION_MODIFICATIONS.md`](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md)。

---

## 修改文件清单

1. **`AKPlugin.swift` & `Plugin.swift`**
   - 新增 `AKAppLayoutInfo`：读取 `UIDeviceFamily`、`UIRequiresFullScreen`、支持方向与 `UIApplicationSceneManifest`，判定应用是否支持自由自适应或推导推荐比例（`16:9` / `3:4` / `9:16`）。
   - 多窗口跟踪（`configuredWindows` / `verifiedTargetWindows`），响应 `didFinishLaunching` 与 `NSWindow` 焦点/曝光事件。
   - 导出 `contentLayoutRect`、`applyWindowAspectLock`、`clearWindowAspectLock` 与 `placeWindowOnTargetScreenIfNeeded`。
   - 支持环境变量 `PLAYCOVER_TARGET_SCREEN=sidecar|secondary`，将测试窗口居中并钳制在副屏可见区域。

2. **`PlayTools/PlaySettings.swift`**
   - 将默认 `resolution` 升级为 `7`（`smartAdaptive`），新增 `dynamicWindowMode`（`resolution == 6 || 7`），为 `AppSettingsData` 补全 `Codable` 安全缺省解码。

3. **`PlayTools/PlayScreen.swift`**
   - 实现双模式显示状态 `PlayDisplayMode`：
     - **`.adaptive`**：放开场景最小尺寸限制（`360x540`），同步活跃主 `UIWindow` 尺寸到 `UIScreen.bounds`/`nativeBounds`，在窗口 resize 后节流触发子视图树与 `UICollectionViewLayout` / `UITableView` 递归刷新，并在检测到非横向滚动容器横向溢出（`> 24pt`）时自动降级到 `.scaled`。
     - **`.scaled`**：将主 `UIWindow.bounds` 锁定在逻辑画布尺寸，计算并应用居中 `CGAffineTransform` 等比缩放，拦截 `setFrame:`/`setBounds:`/`setRootViewController:`/`didAddSubview:` 并钳制直接全屏子视图（如 `UITransitionView` / `TopmostView`）避免局部裁切。
   - 实现 `PLAYTOOLS_AUTOMATION=1` 进程内 IPC 服务（`~/Library/Containers/io.playcover.PlayCover/Automation/<bundleId>/{ready.json,cmd.json,state.json}`）：
     - 支持 `dump`、`dumpTree`、`tap`、`swipe`（调用 `PTFakeMetaTouch` 进程内派发，不占用系统鼠标）与 `setMode`。
     - 输出 `clippedViews` 越界统计与 `interactiveElements` UIKit 坐标。

4. **`PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m`**
   - 为 swizzle 辅助方法添加空类/空方法保护。
   - 在 `dynamicWindowMode` 下 Hook `UIScreen`（`bounds`、`applicationFrame`、`nativeBounds`、`nativeScale`、`scale`）、`UIWindow`（`layoutSubviews`、`setFrame:`、`setBounds:`、`setRootViewController:`、`didAddSubview:`）与 `UIViewController`（`viewWillLayoutSubviews`、`viewDidAppear:`）。
   - **通用自定义 `UICollectionViewLayout` 懒计算修复**：通过 `dladdr` 检测非系统且非 PlayTools 本身的自定义 `UICollectionViewLayout` 子类，Hook `prepareLayout`、`collectionViewContentSize`、`invalidateLayoutWithContext:` 以及 `UICollectionView` 的创建/换布局/`layoutSubviews`，在 `collectionViewContentSize` 返回 `{0, 0}` 时自动触发一次 `layoutAttributesForElementsInRect:` 预热并维护重入与尺寸缓存，避免部分瀑布流与详情页布局因懒计算导致空白。

5. **`PlayTools/Controls/Frontend/EventAdapter/Mouse/Instances/TouchscreenMouseEventAdapter.swift`**
   - 改用 `contentLayoutRect` 计算指针归一化坐标并兼容 `dynamicWindowMode` 与常规缩放模式，修复标题栏偏移导致的点击偏差。

6. **`PlayTools/MysticRunes/PlayedApple.swift` & `PlayedAppleDB.swift`**
   - 打开 SQLite 数据库前自动确保 `PlayChain` 目录存在，通过 `PRAGMA user_version` + 空文件检查避免高频重复建表 `fsync`，并补全默认 `kSecAttrAccessGroup`。

7. **`PlayTools/Controls/Backend/Toucher.swift`**
   - 触控开始命中测试前对 `screen.keyWindow` 做空值保护，避免窗口尚未就绪时点击崩溃。

8. **`iPhone Duo`、UI Scale（`iOSMacScaleFactor`）、`SDK Shift` 与运行时护栏**
   - `PlaySettings.swift`、`AKPlugin.swift`、`PlayScreen.swift`、`NSObject+Swizzle.m`：支持 `layoutIdiom = 3`（`iPhone19,4`）Duo 展开态侧边安全区、`UIWindowSceneGeometry.interfaceOrientation`、独占模拟内屏下 `_UIScreenFixedCoordinateSpace.bounds` 面积占比、`UIRequiresFullScreenIgnoredStartingWithVersion`、`sdkShift`（内存级 `NSBundle` SDK 元数据切换）及模式 6 `resizableAspectRatioType == 0` 优先级修复。
   - `PlayLoader.m`：应用 `uiScale`（`iOSMacScaleFactor`）、libc interpose 指针快照、CloudKit 缺失权限降级桩、`UINSUIKitTerminationController` 退出超时收敛与稳定性护栏。
