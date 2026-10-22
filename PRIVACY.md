# Cloudn 隐私政策 · Privacy Policy

生效日期 / Effective date: 2026-10-22

[中文](#中文) · [English](#english)

---

## 中文

Cloudn 是一个开源的 iOS 应用（[源代码](https://github.com/mengangs/Cloudn)，AGPL-3.0），用来解析和下载网盘分享、短视频与网页视频，并管理你自己的网盘。本政策说明 Cloudn 如何处理你的信息。

### 一句话概括

**Cloudn 没有自己的服务器，不收集、不上传、不出售任何个人信息。** 所有解析、下载和网盘操作都在你的设备上完成，由你的设备直接与对应平台（如百度网盘、OneDrive、Google 云端硬盘）通信。

### 1. 保存在你设备上的数据

- **登录凭据**：你在 Cloudn 里登录的网盘 / 视频平台账号（Cookie、访问令牌、刷新令牌）只保存在 iOS 系统钥匙串中，不会发送给开发者或任何第三方。退出登录即从钥匙串删除。
- **下载的文件、收藏与最近记录、设置**：只保存在本机的应用沙盒里。删除应用会一并删除。
- **诊断日志**：只记录在本机，用于排查问题；只有你主动点「复制排查信息」并发给别人时才会离开设备。日志不包含密码与令牌。

### 2. 与第三方的通信

- **各平台自己的服务器**：解析链接、下载文件、管理网盘时，Cloudn 直接访问对应平台的接口，传给它们的是完成你所请求的操作所必需的信息（例如分享链接、提取码、你的登录凭据）。这些平台按各自的隐私政策处理数据。
- **GitHub**：「检查更新」读取 GitHub 上本项目的公开发布信息；从 GitHub 下载更新包。
- **「星海」口令服务**：解析夸克 / UC 网盘的中文口令时，只有在你同意后才会把**口令文字**发给这个第三方服务换取分享链接，不发送任何账号信息；可在「设置 › 解析」中关闭。这是 Cloudn 唯一用到的非平台方第三方服务。
- Cloudn 不包含广告、统计分析或崩溃上报 SDK。

### 3. Google 用户数据

当你选择用 Google 账号登录以管理自己的 Google 云端硬盘时：

- **访问范围**：Cloudn 请求 `https://www.googleapis.com/auth/drive` 权限，仅用于在应用内实现你主动发起的操作——浏览、下载、上传、新建文件夹、重命名、移动、删除你的文件，创建或取消分享，以及显示已用空间。
- **存储**：Google 返回的访问令牌与刷新令牌只保存在你设备的钥匙串中；文件内容只在你选择下载时保存在你的设备上。
- **不共享、不转移**：Cloudn 不会把你的 Google 用户数据发送给开发者或任何第三方，不用于广告，不出售，也不用于训练任何人工智能 / 机器学习模型。
- Cloudn 对从 Google API 获得的信息的使用和转移，遵守 [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)，包括其中的 Limited Use（有限使用）要求。

### 4. Microsoft 用户数据

当你用微软账号登录以管理自己的 OneDrive 时，Cloudn 请求 `Files.ReadWrite.All`、`offline_access`、`User.Read` 权限，仅用于在应用内实现你主动发起的文件管理与分享操作并显示你的账号名称。令牌只保存在你设备的钥匙串中，不发送给开发者或任何第三方。

### 5. 撤销授权与删除数据

- 在 Cloudn「我的」页对相应账号点「退出登录」，即可删除保存在设备上的凭据。
- 你也可以随时在账号设置中撤销 Cloudn 的访问权限：
  - Google：<https://myaccount.google.com/permissions>
  - Microsoft：<https://account.live.com/consent/Manage>（工作或学校账号：<https://myapps.microsoft.com>）
- 删除 Cloudn 应用会删除其沙盒里的全部数据；钥匙串中的凭据可在删除前通过「退出登录」清除。

### 6. 儿童

Cloudn 不面向 13 岁以下儿童，也不会有意收集儿童的任何信息。

### 7. 政策变更

本政策如有变更，会更新本文件并修改顶部的生效日期；变更记录可在 GitHub 的提交历史中查看。

### 8. 联系方式

如有疑问，请在 GitHub 提交 Issue：<https://github.com/mengangs/Cloudn/issues>

---

## English

Cloudn is an open-source iOS app ([source code](https://github.com/mengangs/Cloudn), AGPL-3.0) for resolving and downloading cloud-drive shares, short videos and web videos, and for managing your own cloud drives. This policy explains how Cloudn handles your information.

### Summary

**Cloudn has no servers of its own and does not collect, upload or sell any personal information.** All resolving, downloading and drive operations run on your device, which talks directly to the respective service (for example Baidu Netdisk, OneDrive or Google Drive).

### 1. Data stored on your device

- **Sign-in credentials** (cookies, access tokens and refresh tokens) for accounts you sign in to within Cloudn are stored only in the iOS Keychain and are never sent to the developer or any third party. Signing out removes them.
- **Downloaded files, bookmarks, recent history and settings** stay in the app's sandbox on your device and are deleted with the app.
- **Diagnostic logs** are kept on the device for troubleshooting and leave it only if you explicitly copy and share them. They do not contain passwords or tokens.

### 2. Communication with third parties

- **The services you use**: Cloudn contacts each service's own servers directly and sends only what is needed to perform the action you requested (such as a share link, its passcode, or your credentials for that service). Those services process data under their own privacy policies.
- **GitHub**: "Check for updates" reads this project's public release information on GitHub, and updates are downloaded from GitHub.
- **"Xinghai" passcode service**: to resolve a Quark/UC text passcode, Cloudn sends **only the passcode text** to this third-party service, and only after you consent; no account information is sent. You can turn this off in Settings › Resolving. This is the only non-platform third-party service Cloudn uses.
- Cloudn contains no advertising, analytics or crash-reporting SDKs.

### 3. Google user data

If you choose to sign in with Google to manage your own Google Drive:

- **Scope**: Cloudn requests `https://www.googleapis.com/auth/drive` solely to provide the user-facing features you initiate in the app: browsing, downloading, uploading, creating folders, renaming, moving and deleting your files, creating or removing sharing permissions, and showing your storage usage.
- **Storage**: access and refresh tokens returned by Google are stored only in your device's Keychain; file contents are saved on your device only when you choose to download them.
- **No sharing or transfer**: Cloudn does not transfer your Google user data to the developer or any third party, does not use it for advertising, does not sell it, and does not use it to train any AI/ML models.
- Cloudn's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

### 4. Microsoft user data

If you sign in with a Microsoft account to manage your own OneDrive, Cloudn requests `Files.ReadWrite.All`, `offline_access` and `User.Read` solely to provide the file-management and sharing features you initiate and to show your account name. Tokens are stored only in your device's Keychain and are never sent to the developer or any third party.

### 5. Revoking access and deleting data

- Sign out of the account on Cloudn's "Me" tab to delete the stored credentials from your device.
- You can revoke Cloudn's access at any time:
  - Google: <https://myaccount.google.com/permissions>
  - Microsoft: <https://account.live.com/consent/Manage> (work or school accounts: <https://myapps.microsoft.com>)
- Deleting the app removes all data in its sandbox; sign out first to clear Keychain credentials.

### 6. Children

Cloudn is not directed to children under 13 and does not knowingly collect information from children.

### 7. Changes

Changes to this policy will be made in this file with an updated effective date; the history is visible in the GitHub commit log.

### 8. Contact

Questions: open an issue at <https://github.com/mengangs/Cloudn/issues>
