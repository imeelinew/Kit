# 设置界面 UI UX 重构执行计划

编制日期：2026 年 10 月 8 日

## 一、 重构背景与目标

当前设置界面采用 7 个标签页架构，存在剪贴板捕获规则与历史存储物理割裂、部分区块层级定义不清晰的问题

本次重构旨在达成以下目标：
- 结构清晰：按视觉与交互认知合理归纳标签页，确立「通用、外观、音效与触感、剪贴板、快捷键、关于」的渐进式探索顺序
- 专业高效：剪贴板核心业务形成闭环，整合规则、智能增强与本地存储维护
- 视觉美观：统一区块层级，规范标题与留白，对标 macOS 原生人机交互标准
- 严格遵循约束：仅调整标签页编排与区块标题，区块内部所有控件、名称与结构原封不动，界面不增设多余二级说明文本，文案不使用句号

## 二、 标签页信息架构

标签页调整为 6 个核心维度，呈现自基础环境至核心业务、再到辅助工具的专业递进关系：

| 顺序 | 标签页标识 | 标签页名称 | 图标资产 | 定位与核心职责 |
| --- | --- | --- | --- | --- |
| 1 | `general` | 通用 | `lucide-settings` | 基础运行语言、开机启动与输入法行为 |
| 2 | `appearance` | 外观 | `lucide-sun-moon` | 视觉外观、渲染材质、菜单栏状态与卡片规范 |
| 3 | `sound` | 音效与触感 | `lucide-volume-2` | 独立交互反馈控制，包含复制音效与触觉反馈 |
| 4 | `clipboard` | 剪贴板 | `lucide-clipboard` | 剪贴板捕获规则、智能增强识别、历史保留与存储维护 |
| 5 | `shortcuts` | 快捷键 | `lucide-keyboard` | 全局唤起热键与面板内部操作快捷键录制 |
| 6 | `about` | 关于 | `lucide-info` | 应用版本展示、更新通道与开源生态致谢 |

注：原 `History`（历史记录）收敛至 `Clipboard`（剪贴板），形成剪贴板捕获与存储完整闭环

## 三、 各标签页详细区块（Section）排布与规范

### 1. 通用（General）

聚焦应用的基础运行环境与启动规范，保持轻盈利落

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | 语言（Language） | 原 General 区块 | 应用语言菜单（Picker: "App Language"） |
| 2 | 启动（Startup） | 原 General 区块 | 登录时启动开关（Toggle: "Launch at Login"） |
| 3 | 输入法（Input Method） | 原 General 区块 | 打开时切换到英文输入法开关（Toggle: "Switch to English When Opening"） |

### 2. 外观（Appearance）

聚焦视觉风格与界面展示元素，保持利落整齐

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | 主题（Theme） | 原 Appearance 区块 | 外观分段选择（Picker: "Appearance"，跟随系统/浅色/深色） |
| 2 | 视觉风格（Visual Style） | 原 Appearance 区块 | 视觉风格分段选择（Picker: "Visual Style"，毛玻璃/Liquid Glass） |
| 3 | 菜单栏（Menu Bar） | 原 Appearance 区块 | 显示菜单栏图标开关、图标动画开关 |
| 4 | 钉选卡片（Pinned Cards） | 原 Appearance 区块 | 图片尺寸分段选择（Picker: "Pinned Image Size"，小/中/大） |

### 3. 音效与触感（Sound & Haptics）

作为独立标签页承载所有多模态交互反馈，提供专注的听觉与触觉调节

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | 音效（Sound Effects） | 原 Sound & Haptics 区块 | 开启音效开关（Toggle: "Enable Sound Effects"）、音效选择菜单（Picker: "Sound Effect"） |
| 2 | 触感（Haptics） | 原 Sound & Haptics 区块 | 触感反馈开关（Toggle: "Haptic Feedback"） |

### 4. 剪贴板（Clipboard）

整合剪贴板全生命周期，串联捕获、智能识别、内容展示与数据留存，解决 OCR 识别与索引维护跨标签页撕裂的痛点

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | 系统剪贴板（System Clipboard） | 原 Clipboard 区块 | 禁用系统剪贴板开关（Toggle: "Disable System Clipboard"） |
| 2 | 排除的应用（Disabled Applications） | 原 Clipboard 区块 | 排除应用图标列表、删除按钮、添加应用按钮（`+`） |
| 3 | LLM 识别分类（LLM Classification） | 原 Clipboard 区块 | 开启 LLM 识别分类开关、分类引擎选择、API 渠道选择、API 密钥输入框及保存按钮 |
| 4 | 图片文字识别（Image Text Recognition） | 原 "Image Text Search" 改名 | 搜索图片中的文字开关（Toggle: "Search Text in Images"） |
| 5 | 内容预览（Content Preview） | 原 Clipboard 区块 | 渲染 Markdown 开关（Toggle: "Render Markdown"） |
| 6 | 历史保留（History Retention） | 原 History 移入赋予标题 | 历史保留时长选择菜单（Picker: "Keep history for"） |
| 7 | 危险操作（Danger Zone） | 原 History 移入 | 图片文字索引操作按钮（清除/重建）、清空历史按钮 |

### 5. 快捷键（Shortcuts）

确立「全局唤起」与「面板操作」两级结构，消除顶部匿名区块的突兀感

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | 激活（Activation） | 原 Shortcuts 匿名区块赋予标题 | 打开 Kit 快捷键录制（PreferencesRow: "Show Kit"） |
| 2 | 面板（Palette） | 原 Shortcuts 区块 | 8 项面板内快捷键录制（操作、复制到剪贴板、钉到屏幕上、在 Finder 中显示、显示下一个类型、显示上一个类型、显示下一个 Stack、显示上一个 Stack） |

### 6. 关于（About）

规整品牌视觉、更新通道与开源社区信息，统一区块标题韵律

| 序号 | 区块标题 | 来源说明 | 包含控件与结构（维持原样） |
| --- | --- | --- | --- |
| 1 | （无标题 Header） | 原 About 头部 | 64×64 高清应用图标、应用名称（Kit）、版本号展示 |
| 2 | 更新（Updates） | 原 About 区块 | 自动检查更新开关（Toggle: "Automatically Check for Updates"） |
| 3 | 代码仓库（Repository） | 原 About 匿名区块赋予标题 | GitHub 仓库跳转按钮 |
| 4 | 致谢（Acknowledgments） | 原 About 匿名区块赋予标题 | 开源依赖项外部链接列表（TinyCast, KeyboardShortcuts, Sparkle, swift-cmark, swift-markdown） |

## 四、 交互与体验规范

1. 侧边栏导航交互：
   - 窗口固定尺寸 778 × 509，侧边栏宽度 196
   - 侧边栏按「通用、外观、音效与触感、剪贴板、快捷键、关于」顺序排列
   - 保持 macOS 原生 Source List 高亮风格，窗口处于前台时始终映射系统强调色
   - 支持顶栏前进与后退按钮，完整保留前进后退导航栈，快速穿梭于近期访问的标签页
2. 表单与区块视觉节奏：
   - 保持 Grouped Form 原生分组卡片质感
   - 区块标题采用大写次要字体（Subheadline/Caption），与系统偏好设置严格对齐
   - 各区块间距保持 16pt，卡片内行高与控件对齐基线一致
3. 联动与危险操作交互：
   - 开启音效开关关闭时，音效选择项自动置灰禁用
   - 显示菜单栏图标关闭时，图标动画项自动置灰禁用
   - 更改历史保留时长为更短时间时，保持既有原生统计确认弹窗机制
   - 图片文字索引与清空历史继续触发双重确认 Sheet，防止误触导致数据丢失
4. 微文案一致性：
   - 严格遵循设计规范，不增加未经批准的副标题描述
   - 避免使用任何句号，维持干练克制的技术品质
