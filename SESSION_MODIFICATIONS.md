# PlayTools 维护记录

[PlayCover 与 PlayTools 维护手册](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md) 汇总运行时行为、自检方法和实机验证。双仓库本地工作区可直接打开 `PlayCover/SESSION_MODIFICATIONS.md`。

## 第二轮契约测试

- Phase 7 的 `webkit` 探针在独立 Catalyst 应用覆盖 iPhone、Duo 和原生平台设置。默认 WebView 在 320 CSS px 视口自带 `Mobile` UA，显式桌面模式、UA 后缀和自定义 UA 都得到保留。三个配置共通过 12 项。Catalyst 报告 `navigator.platform = iPad` 和 `maxTouchPoints = 0`。保留 WebKit 原生设备报告，生产运行时无需添加 Hook。
- 安装的 iOS Chrome 在主屏加载本地 H5 页面，经 Page Down 滚动并点击测试按钮成功。模拟触摸滑动在该页触发了文本选择。测试结束后关闭临时标签页和测试进程。
- Phase 8 的 `urls` 探针确认随机未注册 Scheme 和无 Scheme 的相对 URL 分别在约 8 ms 和 12 ms 回调 `false`。HTTPS、设置和电话只做 `canOpenURL`，没有执行外部跳转。独立应用正常退出，UpTimer 平台自检通过。保留 UIKit 的原生处理。
- Phase 9 的 `presentations` 探针在 Duo 的自适应宽窗、窄窗和等比缩放窗口中执行 15 项检查。无锚点 action sheet、分享面板、照片和文档选择器均显示在窗口内，并由程序正常关闭。探针记录相机与图库的可用性，未取用媒体或文件。三个夹具进程与实机酷安正常退出，UIKit 呈现路径保留原样。
- Phase 10 在相同 Duo 夹具上做 5 组各 10 万次 `ProcessInfo.isMacCatalystApp` 调用。兼容模式基准中位数由约 50.4 µs 降至 8.6 ns，原生模式约 7.2 ns。修复前采样主要停在 `dladdr` 的最近符号查找。32 个原子槽只缓存主程序、PlayTools 自身及 dyld 共享缓存内镜像的确切调用地址，可卸载镜像继续走原始查询。
- Apple 登录与 GameKit 入口提供独立的 `selftestAuthorization` IPC 探针，各有 8 秒超时。本轮保持内建屏显示设置，两项交互待随航复测。常规全量探针通过 70 项。新夹具另行通过临时通知授权并清理测试通知，同一轮 StoreKit 模拟产品查询曾超时，复跑返回无效产品 ID。

## 已安装应用的系统服务

- `services` 探针覆盖定位服务状态、初始授权代理回调、蓝牙授权状态与 APNs 注册失败回调。iPhone、Duo 和原生平台三种配置各通过 5 项。定位和蓝牙只读取授权状态。无 APNs entitlement 的夹具在主线程收到 `UNErrorDomain (1)`，与未注入 PlayTools 的 Catalyst 对照一致。
- APNs 重试限流仅用于可确认缺少两种 APNs entitlement 的进程。限流使用单调时钟，已授权或无法确认签名状态的进程由 UIKit 处理。受控测试核对了两种签名键、签名查询失败和无权限重试分支。真实已签名的设备令牌注册待验证。

## 2026-11-23 后台输入与对象生命周期

手柄映射遵循 AppKit 激活状态，失焦时释放触摸并停止辅助显示回调与摇杆轮询。滑动计时器按需创建、弱引用回调并以激活状态取消。`python3 Tests/check-input-lifecycle.py` 验证空闲和活动对象释放、后台零新增分发及恢复。实体手柄的按键行为仍需设备回归。

对照方法、37 项核心自检和实际应用冒烟结果见 [性能与兼容性核查](https://github.com/Rengwang/PlayCover/blob/develop/PERFORMANCE_REVIEW.md)。本轮没有建立普遍降低应用常驻内存或 GPU 功耗的结论。
