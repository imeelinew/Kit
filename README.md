<p align="center">
  <img src=".github/assets/readme-icon.png" width="112" height="112" alt="Kit app icon">
</p>

<h1 align="center">Kit</h1>

<p align="center">
  为键盘工作流设计的原生 macOS 剪贴板历史工具。<br>
  捕获文字、代码、链接和图片，快速搜索并粘贴回原应用。
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black.svg" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
</p>

<p align="center">
  <img src=".github/assets/readme-screenshot.png" alt="Kit 剪贴板历史面板" width="820">
</p>

## Kit 是什么

Kit 把剪贴板历史做成一个随叫随到的命令面板。按下快捷键，搜索刚才复制过的内容，选中后即可粘贴回原来的应用。

## 功能

- **记录常用内容**：捕获文字、代码、链接和图片，并显示复制来源
- **快速找到历史记录**：使用 SQLite 全文索引搜索完整历史，中文也支持拼音全拼和首字母
- **用键盘完成操作**：呼出面板、搜索、选择和粘贴，无需切换工作流
- **预览图片**：列表显示图片缩略图，按空格查看大图
- **管理剪贴板**：按时间浏览记录，设置保留期限，并排除指定应用

## 使用方式

默认按 `Option + W` 呼出或隐藏面板。输入关键词过滤记录，用方向键选择，然后按回车粘贴。

| 按键 | 操作 |
| --- | --- |
| `Return` | 粘贴并关闭面板 |
| `⌘ Return` | 复制所选内容 |
| `Space` | 预览图片 |

也可以从操作菜单中选择保持面板打开并粘贴、在 Finder 中显示图片或删除记录。呼出快捷键可在设置中重新录制。

## 隐私与权限

剪贴板历史和图片保存在本机，不需要云端服务。你可以设置历史保留期限，并指定不参与捕获的应用；“钥匙串访问”和“密码”默认排除。

Kit 需要辅助功能权限，才能将选中的内容发送回呼出面板前正在使用的应用。

## 从源码构建

需要 macOS 26、Xcode 26 和 Swift 6。

```bash
git clone https://github.com/imeelinew/Kit.git
cd Kit
open Kit.xcodeproj
```

在 Xcode 中选择 **Kit** scheme，然后运行 **Product → Run**。首次粘贴前，请按系统提示授予辅助功能权限。

## 许可证

Kit 基于 [GNU Affero General Public License v3.0](LICENSE) 发布。
