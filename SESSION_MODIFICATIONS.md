# PlayTools 维护记录

[PlayCover 与 PlayTools 维护手册](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md) 汇总运行时行为、自检方法和实机验证。双仓库本地工作区可直接打开 `PlayCover/SESSION_MODIFICATIONS.md`。

## 第二轮契约测试

- Phase 7 的 `webkit` 探针在独立 Catalyst 应用覆盖 iPhone、Duo 和原生平台设置。默认 WebView 在 320 CSS px 视口自带 `Mobile` UA，显式桌面模式、UA 后缀和自定义 UA 都得到保留。三个配置共通过 12 项。Catalyst 报告 `navigator.platform = iPad` 和 `maxTouchPoints = 0`。保留 WebKit 原生设备报告，生产运行时无需添加 Hook。
- 安装的 iOS Chrome 在主屏加载本地 H5 页面，经 Page Down 滚动并点击测试按钮成功。模拟触摸滑动在该页触发了文本选择。测试结束后关闭临时标签页和测试进程。
- Phase 8 的 `urls` 探针确认随机未注册 Scheme 和无 Scheme 的相对 URL 分别在约 8 ms 和 12 ms 回调 `false`。HTTPS、设置和电话只做 `canOpenURL`，没有执行外部跳转。独立应用正常退出，UpTimer 平台自检通过。保留 UIKit 的原生处理。
- Phase 9 的 `presentations` 探针在 Duo 的自适应宽窗、窄窗和等比缩放窗口中执行 15 项检查。无锚点 action sheet、分享面板、照片和文档选择器均显示在窗口内，并由程序正常关闭。探针记录相机与图库的可用性，未取用媒体或文件。三个夹具进程与实机酷安正常退出，UIKit 呈现路径保留原样。
- Phase 10 在相同 Duo 夹具上做 5 组各 10 万次 `ProcessInfo.isMacCatalystApp` 调用。兼容模式基准中位数由约 50.4 µs 降至 8.6 ns，原生模式约 7.2 ns。修复前采样主要停在 `dladdr` 的最近符号查找。32 个原子槽只缓存主程序、PlayTools 自身及 dyld 共享缓存内镜像的确切调用地址，可卸载镜像继续走原始查询。
- Apple 登录与 GameKit 入口提供独立的 `selftestAuthorization` IPC 探针，各有 8 秒超时。本轮保持内建屏显示设置，两项交互待随航复测。常规全量探针通过 70 项。新夹具另行通过临时通知授权并清理测试通知，同一轮 StoreKit 模拟产品查询曾超时，复跑返回无效产品 ID。
