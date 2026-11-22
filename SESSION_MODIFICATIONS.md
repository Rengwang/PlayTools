# PlayTools 维护记录

[PlayCover 与 PlayTools 维护手册](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md) 汇总运行时行为、自检方法和实机验证。双仓库本地工作区可直接打开 `PlayCover/SESSION_MODIFICATIONS.md`。

## 第二轮契约测试

- Phase 7 的 `webkit` 探针在独立 Catalyst 应用覆盖 iPhone、Duo 和原生平台设置。默认 WebView 在 320 CSS px 视口自带 `Mobile` UA，显式桌面模式、UA 后缀和自定义 UA 都得到保留。三个配置共通过 12 项。Catalyst 报告 `navigator.platform = iPad` 和 `maxTouchPoints = 0`。保留 WebKit 原生设备报告，生产运行时无需添加 Hook。
- 安装的 iOS Chrome 在主屏加载本地 H5 页面，经 Page Down 滚动并点击测试按钮成功。模拟触摸滑动在该页触发了文本选择。测试结束后关闭临时标签页和测试进程。
- Phase 8 的 `urls` 探针确认随机未注册 Scheme 和无 Scheme 的相对 URL 分别在约 8 ms 和 12 ms 回调 `false`。HTTPS、设置和电话只做 `canOpenURL`，没有执行外部跳转。独立应用正常退出，UpTimer 平台自检通过。保留 UIKit 的原生处理。
