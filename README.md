<div align="center">

<img src="Cloudn/Assets.xcassets/Logo.imageset/Logo.png" width="112" alt="Cloudn" />

# Cloudn

**粘贴分享链接，浏览并高速下载 —— SwiftUI 原生 iOS 网盘 / 短视频解析下载应用**

</div>

---

Cloudn 是一款个人独立开发的 iOS 应用：粘贴网盘分享链接即可浏览分享内容、直接下载文件；粘贴短视频链接即可解析无水印视频与图集。

## 功能

- **网盘分享解析**：夸克网盘、UC 网盘、蓝奏云，自动识别链接里的提取码，支持多级目录浏览、多选、整个文件夹下载（保留目录结构）
- **游客下载**：夸克（约 50MB 以内）/ UC / 蓝奏云未登录即可下载；登录夸克后不限大小，直链失败时自动回退「临时转存后取链」并在下载完成后清理
- **短视频 / 图集解析**：抖音、快手、微博、AcFun、哔哩哔哩（登录后 1080P+，DASH 音视频下载后用 AVFoundation 无损合轨）
- **高速下载**：Range 多连接分片并发、断点续传（任务表与分片进度持久化，重启后可继续）、m3u8（含 AES-128）分片下载、直链过期后「重新获取直链并继续」
- **在线预览**：视频 / 音频在线播放（逐请求带 Referer / Cookie），图片缩放查看，下载完成的文件用 QuickLook 打开
- **文件管理**：下载文件出现在「文件」App →「我的 iPhone」→ Cloudn，可分享、存入相册
- **账号**：网页登录（独立的 WKWebView 会话，自动识别登录完成）或手动粘贴 Cookie；凭证只存钥匙串
- **收藏与历史**：常用分享一键打开；`cloudn://resolve?text=<链接>` 可从快捷指令等外部唤起解析

识别但暂未支持解析的平台（迅雷、百度、139、123、115、光鸭、蓝奏云优享版）会给出明确提示。

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
Cloudn/                 SwiftUI 应用
  App/                  入口与全局状态（AppModel）
  Services/             钥匙串账号、设置、收藏、下载状态、隐藏 WebView、AVFoundation 合轨
  Views/                解析 / 账号 / 下载 / 设置 四个标签页
CloudnKit/              与界面无关的核心 Swift Package（可在 Linux 上编译与测试）
  Share/                链接识别、夸克 / UC / 蓝奏云解析
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
