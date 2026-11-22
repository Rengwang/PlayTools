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
   - `PlaySettings.swift`、`AKPlugin.swift`、`PlayScreen.swift`、`NSObject+Swizzle.m`：支持 `layoutIdiom = 3`（`iPhone19,4`）Duo 展开态几何体、`UIWindowSceneGeometry.interfaceOrientation`、独占模拟内屏下 `_UIScreenFixedCoordinateSpace.bounds` 面积占比、`UIRequiresFullScreenIgnoredStartingWithVersion`、`sdkShift`（内存级 `NSBundle` SDK 元数据切换）及模式 6 `resizableAspectRatioType == 0` 优先级修复（已移除不再需要的 `UIWindow.safeAreaInsets` swizzle）。
   - `PlayLoader.m`：应用 `uiScale`（`iOSMacScaleFactor`）、libc interpose 指针快照、CloudKit 缺失权限降级桩、`UINSUIKitTerminationController` 退出超时收敛与稳定性护栏。

9. **低功耗「应用模式（App Mode）」默认配置与 P0/P1 性能功耗优化**
   - **共享默认配置（`PlaySettings.swift`、`DiscordActivity.swift`、`AKPlugin.swift`）**：将 `keymapping` 与 `DiscordActivity.enable` 默认值改为 `false`，新增 `spoofPowerState = false`（兼容缺省解码），在 `AKPlugin` 的 4 个事件监听注册入口补充 `keymappingSetting` 防护，同时保持窗口自适应、Sidecar、Duo、UI Scale 与菜单栏不受影响。
   - **`CADisplayLink` 按需启停与 App Nap 兼容（`PlayInput.swift`、`ControllerFocus.m`）**：将 `CADisplayLink` 移至 `keymapping` 开关之后，且仅在已连接 `GCController` 且应用处于前台活跃状态时创建运行；手柄断开即失效销毁，应用失焦/后台/隐藏/最小化立即暂停，彻底消除静态 60–120 Hz 空转唤醒；`ControllerFocus.m` 的后台手柄监听同步受 `keymapping` 门控。
   - **Discord RPC 零线程泄漏防护（`DiscordIPC.swift`）**：除检查 `enable` 与非空 `applicationID` 外，在实例化 `SwordRPC` 或请求 iTunes 图标前先用 `access(..., F_OK)` 检查可达的 `discord-ipc-0..9` socket，避免 Discord 未运行时泄漏 10 个 SwiftNIO `MultiThreadedEventLoopGroup` 线程；连接后强引用持有 `activeRPC` 并在退出时 `disconnect()`。
   - **真实温控/低电量/电池状态透传（`PlayInfo.swift`、`BatteryLevel.m`）**：移除 `BatteryLevelLoader` 中无条件的 `setBatteryMonitoringEnabled:YES`，并移除 `extension ProcessInfo` 对 `thermalState` / `isLowPowerModeEnabled` 的无条件分类覆盖，改由 `spoofPowerState == true` 时再按需 swizzle 电池与温控接口。
   - **热路径 CPU / 内存 / I/O 优化**：
     - `PlayScreen.swift`：主线程弱引用缓存 `activePrimaryWindow`，在窗口/场景通知变更时失效，消除高频 `UIScreen.bounds` 与方向查询的重复遍历排序。
     - `PlayLoader.m`：将 `deviceModel` / `oemID` / `blockSleepSpamming` 原子缓存为 C 状态，避免 `sysctl`/`uname`/`usleep` 热路径重复 ObjC 消息；仅在进程存在 `JPUSHService` 类时才 Hook `NSNotificationCenter`。
     - `NSObject+Swizzle.m`：使用 `CFMutableSetRef` + 16 槽主线程 `Class` 指针缓存替代 `NSMutableSet<NSValue *>`，使 `UICollectionView.layoutSubviews` 热路径零锁零 `NSValue` 分配；缓存 `customScaler`。
     - `PTFakeMetaTouch.m`：在 `sendEvent:` 后将已结束/取消的触控槽位清空为 `[NSNull null]` 再归还复用位图，避免持续持有旧 `UIView`/`UIWindow`。
     - `PlayedAppleDB.swift`：在 `dbLock` 下复用持久化 WAL 模式 `sqlite3*` 连接并在 I/O/锁错误时自动重连，避免每次 Keychain 查询重复 `mkdir`/`stat`/`open`/`close`。
     - `Keymapping.swift`：基于 `stat()` `st_mtimespec` 缓存 `keymapConfig` 与各 `KeymappingData`，避免 `ActionDispatcher.build()` 重复读取并解析 XML plist。

10. **PlayChain 查询语义修复：按全部属性匹配（2026-11-22）**
   - **根因（实证）**：工商银行启动期查询 `gena = IMEIString`（`kSecAttrGeneric`）时，`PlayKeychainDB.query` 只用主键列（`agrp/acct/svce`）构造 `WHERE`，忽略了 `gena`。于是它返回了同 access group 下 `acct = bundleIDPrefix` 的另一条记录，且该记录没有 `v_Data`；工行把返回值当自己的记录使用，执行 `-[__NSDictionaryM setObject:forKey:]`（key `v_Data`）时触发 `NSInvalidArgumentException` 崩溃。
   - **修复**：`query` 的 `WHERE` 改为覆盖该表全部列（主键 + 属性列 + 值列），与 Keychain「查询中每个属性都参与匹配」的语义一致；`update` / `delete` 仍只按主键定位。
   - **验证**：同一 `gena = IMEIString` 查询由「错误命中」变为 `errSecItemNotFound`，工行转入正常新建流程（日志出现 `Wrote keychain item to db`），冷启动后持续运行 ≥15 秒并进入 2 秒一次的正常状态轮询，不再抛异常。

11. **SecItem 返回值语义收敛（`MysticRunes/PlayedApple.swift`）**
   - `SecItemAdd`：请求了返回值但属性中没有 `v_Data` 时，由「返回 `errSecSuccess` 且不写 out 指针」改为 `errSecParam`，避免调用方拿到未初始化的结果后自行解引用。
   - `SecItemCopyMatching`：同时请求 `kSecReturnAttributes` 与 `kSecReturnData`、但条目没有 `v_Data` 时返回 `errSecItemNotFound`，而不是返回缺字段的字典。
   - `addResult` 的密钥构造回退项由 `kSecAttrKeyType` 误用改为 `kSecAttrKeyClass`。

13. **PlayChain 空值 / 批量 / 删除语义补齐（2026-11-22）**
   - `encodeData`：零长度 `CFData` 改用 `sqlite3_bind_zeroblob(...,0)`，不再因为 `CFDataGetBytePtr == NULL` 被写成 `SQLITE_NULL`；`decodeData` 对 `SQLITE_BLOB` 先取 `column_bytes`，为 0 时返回 `Data()`，只有 `SQLITE_NULL` 才返回 `nil`。
   - `copyAllMatches` 与单条查询共用 `resultDictionary(_:query:)`：请求 `kSecReturnData` 但条目无 `v_Data` 时不视为匹配，空集合返回 `errSecItemNotFound`。
   - `SecItemDelete`：仅当 query 只有 `kSecClass` 时执行整表删除；若包含任何无法转成 SQL 的限定键（如 `kSecMatchItemList`），直接返回 `errSecParam` 且不执行 SQL，避免“定向删除变成清表”。`SecItemUpdate/Delete` 用 `sqlite3_changes` 判断是否命中，未命中返回 `errSecItemNotFound`。
   - 验证：class-only 清表 0 残留；带 `kSecMatchItemList` 返回 `errSecParam` 且 2 行数据零丢失；带 `svce+gena` 只删 1 行；改主键 `acct` 命中 1 行；无匹配返回 0。
