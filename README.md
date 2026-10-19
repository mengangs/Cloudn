<div align="center">

<img src="Cloudn/Assets.xcassets/Logo.imageset/Logo.png" width="112" alt="Cloudn" />

# Cloudn

**粘贴分享链接，浏览并高速下载 —— SwiftUI 原生 iOS 网盘 / 短视频解析下载应用**

</div>

---

Cloudn 是一款个人独立开发的 iOS 应用：粘贴网盘分享链接即可浏览分享内容、直接下载文件；粘贴短视频链接即可解析无水印视频与图集。

## 功能

- **网盘分享解析**：夸克网盘、UC 网盘、百度网盘、迅雷网盘、115 网盘、123 云盘、139 网盘、光鸭云盘、蓝奏云、蓝奏云优享版，自动识别链接里的提取码（迅雷中文口令也能直接粘贴解析），支持多级目录浏览、多选、整个文件夹下载（保留目录结构）
- **游客下载**：蓝奏云 / 蓝奏云优享版 / 光鸭云盘 / UC 未登录即可下载，夸克（约 50MB 以内）与 115（小文件）也可直接下载；登录夸克后不限大小，直链失败时自动回退「临时转存后取链」并在下载完成后清理
- **登录后下载**：百度、迅雷借助临时转存取直链、取完即删；115 大文件转存后走电脑端通道取链，下载完成后自动清理；123、139 登录后直接取分享直链。未登录时这些网盘也能浏览分享内容
- **短视频 / 图集解析**：抖音、小红书（需登录，图集自动换去水印原图）、快手、微博、AcFun、Pixiv（粘贴 Cookie 后可解析受限作品）、哔哩哔哩（登录后 1080P+，DASH 音视频下载后用 AVFoundation 无损合轨）
- **高速下载**：Range 多连接分片并发、断点续传（任务表与分片进度持久化，重启后可继续）；切到后台或锁屏后，普通文件剩余分片交给系统后台下载会话继续下载，完成后发通知、m3u8（含 AES-128）分片下载、直链过期后「重新获取直链并继续」
- **转存到我的网盘**：夸克、UC、百度、迅雷、115、123、139 登录后可把分享里的文件 / 文件夹（单个、多选或整个目录）转存到自己网盘，可逐级选择目标文件夹
- **下载设置**：全局限速、失败重试次数、按平台单独设置连接数、免转存下载开关、完成后移动到「文件」App 中任意文件夹（如 iCloud 云盘）、导出诊断日志
- **在线预览**：视频 / 音频在线播放（逐请求带 Referer / Cookie），图片缩放查看，文本文件在线查看，下载完成的文件用 QuickLook 打开；整个文件夹 / 一组图片在下载页收成可折叠分组
- **文件管理**：下载文件出现在「文件」App →「我的 iPhone」→ Cloudn，可分享、存入相册
- **账号**：网页登录（独立的 WKWebView 会话，自动识别登录完成，Cookie 或网页本地存储里的令牌都能读取）或手动粘贴凭据；凭证只存钥匙串，可用口令加密导出 / 导入备份
- **分享扩展**：在 Safari、微信等应用里「分享 → Cloudn」直接唤起解析
- **收藏与历史**：常用分享一键打开；`cloudn://resolve?text=<链接>` 可从快捷指令等外部唤起解析

光鸭云盘中「分享者未开放免登录下载」的分享暂不支持（需要光鸭账号转存）。

## 构建

要求：Xcode 16 及以上，iOS 17 及以上。

```bash
git clone https://github.com/mengangs/Cloudn.git
open Cloudn/Cloudn.xcodeproj
```

在 Xcode 中选择自己的开发者团队（Signing & Capabilities）后运行即可。

每次推送 CI 都会构建一个**未签名的 IPA**（Actions → 最近一次运行 → Artifacts → `Cloudn-unsigned-ipa`），可用 AltStore / Sideloadly 等工具自签安装。

## 项目结构

```
Cloudn.xcodeproj        Xcode 工程（同步文件夹，新增文件无需手动加入工程）
CloudnShare/            分享扩展（把链接交给主应用）
Cloudn/                 SwiftUI 应用
  App/                  入口与全局状态（AppModel）
  Services/             钥匙串账号、设置、收藏、下载状态、隐藏 WebView、AVFoundation 合轨
  Views/                解析 / 账号 / 下载 / 设置 四个标签页
CloudnKit/              与界面无关的核心 Swift Package（可在 Linux 上编译与测试）
  Share/                链接识别与各网盘解析（夸克 / UC / 百度 / 迅雷 / 115 / 123 / 139 / 光鸭 / 蓝奏云 / 蓝奏云优享版）
  Support/              HTTP、动态 JSON、纯 Swift 摘要与 AES / RSA（各网盘签名参数用，Linux 上同样可测）
  Video/                抖音 / 快手 / 微博 / AcFun / 哔哩哔哩解析
  Download/             分片下载引擎、HLS、断点续传
  Tests/                单元测试 + 本地测试服务器（Range / HLS / 模拟夸克接口）
```

运行核心测试：

```bash
cd CloudnKit
python3 Tests/Server/test_server.py 8765 &
CLOUDN_TEST_SERVER=http://127.0.0.1:8765 swift test
```

## 许可与致谢

Cloudn 以 [GNU AGPL-3.0](LICENSE) 发布。

Cloudn 是独立开发的应用，与 YunX 项目及其作者没有关联；但其中部分网盘与视频平台的协议实现参考了开源项目 [YunX](https://github.com/CYQawa/YunX)（AGPL-3.0），依照该许可，Cloudn 的源代码同样以 AGPL-3.0 开放，相关文件头部已注明来源。

## 免责声明

本项目仅供个人学习与技术交流，不得用于商业用途。请只解析你有权访问的分享内容，遵守各平台服务条款与当地法律法规。各平台接口随官方调整可能失效。
