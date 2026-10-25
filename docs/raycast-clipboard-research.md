# Raycast 剪贴板行为调研

## 文档状态

本文已完成当前范围内的只读代码审计、公开资料调研与 Raycast 实机观察整合

当前确认范围：

- Kit 现有文本剪贴板实现
- Raycast 官方 Clipboard History 手册
- Raycast macOS `v0.63` 更新日志
- Raycast 本机 `2.9.0.0` 两轮实机观察
- 未推测 Raycast 内部数据结构或未公开行为
- 本文作者未操作图形界面，实机结果由外部分支代理提供

证据等级：

- “本地事实”来自当前仓库代码及行号
- “官方事实”来自文末 Raycast 官方链接
- “实机事实”来自 Raycast 本机 `2.9.0.0` 在 2026-10-25 的观察
- “建议”是针对 Kit 的设计建议，不代表 Raycast 内部实现
- “待实测”是官方资料未明确且不能从现象安全推导的项目

## 本地实现事实

### 文件捕获入口

本地读取阶段已经能取得多个文件 URL，见
[ClipboardManager.swift:128](../Kit/Core/ClipboardManager.swift#L128)

`PasteboardSnapshot` 保存 `fileURLs: [URL]`，见
[ClipboardCapturePipeline.swift:9](../Kit/Core/ClipboardCapturePipeline.swift#L9)

但处理阶段只要 `fileURLs` 非空就直接返回 `nil`，连同时存在的文本和图像也一起丢弃，见
[ClipboardCapturePipeline.swift:33](../Kit/Core/ClipboardCapturePipeline.swift#L33)

代码注释明确说明，原因是文件必须保留再次粘贴时的文件身份，而当前能力尚未实现，见
[ClipboardCapturePipeline.swift:31](../Kit/Core/ClipboardCapturePipeline.swift#L31)

因此当前结论是：

- Finder 多文件复制不会进入 Kit 历史
- 文件 URL 加文本或图像表示时也不会进入 Kit 历史
- 文件 URL 数据已进入 `PasteboardSnapshot`，缺口位于归一化边界

### 当前条目模型

`ClipboardItem.Kind` 只有 `text`、`markdown`、`code`、`link`、`path`、`image`，没有文件或文件数组类型，见
[ClipboardItem.swift:5](../Kit/Core/ClipboardItem.swift#L5)

条目模型只有单个 `text`、单个内部图片路径和图片指纹，没有文件引用集合，见
[ClipboardItem.swift:21](../Kit/Core/ClipboardItem.swift#L21)

`path` 是文本分类结果，正文仍是路径字符串，并未保存可再次粘贴的文件对象

重新粘贴时，`path` 与普通文本一样走 `Payload.text`，见
[Paster.swift:82](../Kit/Core/Paster.swift#L82)

所以本地 `path` 只能复制路径文字，不能恢复文件或多文件选择

### 当前图片语义

内联图片会被规范化并写入 Kit 管理目录，数据库保存内部 PNG 路径和内容指纹，见
[ClipboardStore.swift:252](../Kit/Core/ClipboardStore.swift#L252)

粘贴图片到 Finder 时，Kit 写入内部 PNG 的 `.file` URL，见
[Paster.swift:87](../Kit/Core/Paster.swift#L87)

粘贴图片到其他应用时，Kit 读取内部 PNG 并通过 `Payload.image` 写入图片数据，见
[Paster.swift:98](../Kit/Core/Paster.swift#L98)

这条路径适合剪贴板内联位图，但不能替代用户文件对象

### 整项复制与选区复制

默认整项复制快捷键是 `⌘Return`，见
[ShortcutRecorder.swift:15](../Kit/Features/Settings/ShortcutRecorder.swift#L15)

普通列表收到 `⌘C` 后进入编辑快捷键路由，而不是整项复制，见
[PalettePanel.swift:200](../Kit/Core/PalettePanel.swift#L200)

搜索框无选区时 `⌘C` 被消费但没有整项动作，搜索框有选区时只复制搜索词，见
[PalettePanel.swift:322](../Kit/Core/PalettePanel.swift#L322)

本地搜索框选区复制后还会调用 `markCurrentPasteboardInternal`，因此当前 Kit 会忽略这次捕获，见
[PalettePanel.swift:331](../Kit/Core/PalettePanel.swift#L331) 与
[Paster.swift:71](../Kit/Core/Paster.swift#L71)

这与 Raycast 实机中搜索选区复制会新增条目不同

预览文本当前不可编辑且不可选择，见
[AttributedTextPreview.swift:246](../Kit/Support/AttributedTextPreview.swift#L246)

整项文本复制会写入 `.string` 和 Kit 内部类型标记，见
[Paster.swift:128](../Kit/Core/Paster.swift#L128)

### 写入与历史回写

监控器会拒绝 Kit 内部写入，避免把自己的复制再次捕获为外部条目，见
[ClipboardCapturePipeline.swift:83](../Kit/Core/ClipboardCapturePipeline.swift#L83)

整项复制在写入成功后显式调用 `recordHistoryAction`，见
[Paster.swift:65](../Kit/Core/Paster.swift#L65)

该动作会增加复制次数、更新时间并按设置决定是否更新历史位置，见
[ClipboardStore.swift:282](../Kit/Core/ClipboardStore.swift#L282)

粘贴使用有序事务，写入剪贴板并成功发送粘贴后才回写历史，见
[PasteTransaction.swift:17](../Kit/Core/PasteTransaction.swift#L17)

### 去重、排序与来源

文本按完整原文二进制相等去重，见
[ClipboardStore.swift:1189](../Kit/Core/ClipboardStore.swift#L1189)

图片按指纹去重，见
[ClipboardSQLite.swift:144](../Kit/Core/ClipboardSQLite.swift#L144)

列表与搜索按最近复制时间降序，数据库查询见
[ClipboardSearch.swift:87](../Kit/Core/ClipboardSearch.swift#L87)

来源应用在检测剪贴板变化时取当前前台应用的 `bundle ID`，见
[ClipboardManager.swift:58](../Kit/Core/ClipboardManager.swift#L58)

外部再次复制相同内容会更新来源，Kit 内再次复制会保留原来源，见
[ClipboardItem.swift:69](../Kit/Core/ClipboardItem.swift#L69)

## Raycast 实机第一轮结果

观察环境为 Raycast 本机 `2.9.0.0`

### 预览选区与搜索选区

实机确认：

- 预览支持鼠标拖选局部文本
- 在预览中选中 `20261025-01` 后按 `⌘C`，列表顶端新增文本条目
- 新增条目来源为 Raycast
- 在搜索框选中 `61025` 后按 `⌘C`，列表顶端同样新增文本条目
- 新增条目来源为 Raycast

该结果修正了此前“预览片段默认不进入历史”的推断

以下为 Kit 复刻建议：

- 整项复制是历史条目的动作，使用内部写入标记阻止监控器再次捕获，再由动作层回写原条目次数、时间与来源，并按设置决定位置
- 选区复制产生新的文本载荷，走正常文本捕获路径，由捕获器创建新条目
- 选区复制不应直接更新父条目，因为它复制的是新载荷而不是复用父条目

父条目不应因选区复制增加次数、刷新位置或改变来源

选区来源显示 Raycast 只是观察结果，不能据此推导 Raycast 如何为选区分配来源字段

### 整项复制

实机确认：

- 对条目按 `⌘Return` 后没有新增列表行
- 原条目位置保持不变
- 原条目复制次数增加
- 来源仍为原来源 Kit
- 只读检查设置时，`Update history after action` 为开启状态

该次样本复制后位置没有变化，但测试时选中项是否已经在顶端等前置状态没有完整记录

因此不能据此推翻官方对开关开启后置顶的说明，也不能直接认定该开关失效

Kit 建议继续使用“内部写入被监控器忽略，再由动作层回写原条目”的两段式流程

### 跨来源文本重复

前一版记录“两条同字符串均来自 Kit”是误读，现已纠正

实机两条同内容文本分别来自：

- 第一条来源 Kit，字符数为 19，复制次数为 3
- 第二条来源 TextEdit，字符数为 19，时间为 12:24:08

Raycast 在该样本中保留了跨来源的两个相同内容条目

可以确认的事实仅限于：

- 跨来源并不保证仅按字符串合并
- 本次样本确实存在两条内容相同但来源不同的条目
- 不能声称 Raycast 全局只按字符串去重
- 不能推导同来源重复文本一定去重或一定新增

### 文件回写、移动与删除

实机确认：

- 单个文件夹显示的 Type 为 `File`
- 单个普通文件显示的 Type 为 `File`
- 一次复制一个文本文件和一个图片文件，形成一项 `Files Count2`
- 两个同名目录显示为两行并用路径区分
- 单个 PNG 文件显示的 Type 为 `Image`
- 单 PNG 文件条目显示图片尺寸和文件大小

文件回写测试使用全新空 Finder 目录，Raycast 保持运行，没有删除其他样本文件

文本文件从历史按 `⌘Return` 后，在空目录按 `⌘V` 真实生成：

```text
/Users/eli/Desktop/RESEARCH-Raycast-Paste-Target-01/RESEARCH-SameName.md
```

单 PNG 文件使用同样方式真实生成并保留原名：

```text
/Users/eli/Desktop/RESEARCH-Raycast-Paste-Target-02/RESEARCH-ImageFile-01.png
```

因此用户可以观察到文件复制，而不是只复制了路径文字

当前没有检查具体 pasteboard type，不能断言 Raycast 写入了哪一种文件类型标识

文件状态测试的样本位于：

```text
/Users/eli/Desktop/RESEARCH-Raycast-Files-20261025
```

观察结果：

- `RESEARCH-TextFile-01.md` 改名为 `RESEARCH-TextFile-renamed.md` 后重新打开历史，旧项仍显示原名和旧路径
- 改名后的文件大小显示为空
- 文件移动到 `RESEARCH-SameName-A` 后重新打开历史，旧项仍显示原路径
- 文件移入废纸篓后重新打开历史，旧项仍然存在
- 废纸篓样本路径为 `~/.Trash/RESEARCH-TextFile-renamed.md`

观察窗口较短，尚未验证延迟清理

因此不能写成 Raycast 永久保留失效文件项

本次短窗口内没有立即移除失效项，与 `v0.63` 更新日志公开的删除清理期望存在时间差

具体清理触发点和延迟仍需后续验证

### 文件展示的边界

以上只证明 Raycast 会把一次多文件复制显示在同一历史条目中，并分别展示 File、Files 和单 PNG Image

这些现象不能推出 Raycast 底层保存了文件引用数组、文件对象或 URL 与图片副本

单个 PNG 的 Image 结果只覆盖该格式样本，不能推广到所有图片文件、多图片复制或其他图片格式

文件引用数组、文件对象、物理 URL 保留与展示类型分离全部属于后续 Kit 建议

### 快捷键观察差异

`Option+C` 的设置界面显示为 Alias，不是确认可用的全局直达热键

实机从非 Raycast 应用进入 Raycast 主搜索后，在主搜索内按 `Option+C` 会输入带变音符号的 `ç`

本次没有修改快捷键设置

因此此前传递的 `Option+C` 快捷键信息与 Raycast 设置显示及实际输入行为存在差异

本调研不把 `Option+C` 作为已确认的全局直达快捷键，也不把该输入结果用于判断剪贴板复制行为

## Raycast 官方已确认行为

以下内容来自 Raycast 官方 Clipboard History 手册

- Raycast 会保存复制时的多种原始格式
- 一次复制多个文件或多项内容时，它们会合并成一个剪贴板条目
- 选中条目后按 `Return` 粘贴
- 选中条目后按 `⌘Return` 执行复制到剪贴板
- 开启 `Update history after action` 后，复制或粘贴动作会把条目移动到列表顶部
- 禁用应用列表中的应用不会被记录

官方手册：
[Raycast Clipboard History](https://manual.raycast.com/clipboard-history)

以下内容来自 Raycast macOS `v0.63` 官方更新日志

- 修复了关联文件删除后失效文件条目未被移除的问题
- 修复项只说明结果，没有公开检测时机
- 修复项没有公开文件移动后的行为
- 修复项没有公开文件改名后的行为
- 官方页面日期为 2026-06-04

官方更新日志：
[Raycast macOS v0.63](https://www.raycast.com/changelog/macos/0-63)

这里的公开事实只能确定“关联文件删除后不应继续留下失效条目”，不能据此推导 Raycast 的清理实现

本机 `2.9.0.0` 的实机结果仍应作为当前版本行为的主要证据，不能把旧版本日志中的细节直接等同于当前版本的全部行为

官方现有资料没有明确普通文本是否普遍去重

## Kit 复刻差异

### 文本去重

当前 Kit 会按完整文本查找已有条目，命中后复用同一 ID、更新时间并更新来源，见
[ClipboardStore.swift:223](../Kit/Core/ClipboardStore.swift#L223)

Raycast `2.9.0.0` 本次观察到 Kit 与 TextEdit 的相同内容保留为两个条目

因此至少存在一项复刻差异：

- 当前 Kit 会把跨来源相同文本更新到已有条目
- 本次 Raycast 样本保留了两个跨来源相同文本条目

若目标贴近该样本，Kit 不能只用文本内容作为唯一身份

可先把来源加入身份判断，但不能据此认定 Raycast 对所有来源组合都这样处理

同来源重复、连续重复和交错重复仍没有足够样本确定

### 复制路径

Kit 复刻建议保留两条独立路径：

- 整项复制继续添加内部忽略标记，再由动作层回写原条目
- 预览或搜索选区正常写入文本并正常捕获为新条目，不更新父条目

这样可以分别覆盖 Raycast 实机观察到的整项复用和选区新增行为

## 文件条目设计建议

以下全部是 Kit 设计建议，不是 Raycast 内部实现结论

### 数据模型

推荐增加 `files` 引用数组和文件元数据快照

建议的语义字段包括：

```text
files: [
  fileReference,
  originalURL,
  displayName,
  contentType,
  fileSize,
  modificationDate,
  metadataSnapshot
]
```

`fileReference` 应作为重新定位与重新粘贴的主要身份来源

`originalURL` 用于展示、搜索和调试，不应单独承担文件身份

`metadataSnapshot` 用于列表展示和缺失文件判断，不应替代实时文件状态

首版 Kit 可以采用 `files` 引用数组与路径检查完成文件捕获和回写

文件移动跟踪可以使用 `bookmark`、文件资源标识或其他本地持久引用方案

这些移动跟踪字段属于 Kit 自身扩展，不能表述为 Raycast 已确认采用相同逻辑

### 内容优先级

当剪贴板同时广告文件对象、文本和图像表示时，建议文件对象优先

推荐规则：

- 文件对象存在时生成一条文件载荷
- 多个文件对象保存在同一 `files` 数组
- 伴随文本保留为展示和搜索元数据
- 文件缩略图或伴随位图只作为预览缓存
- 文件 URL 不应被降级为普通 `path` 文本
- Kit 可让图片文件保留原始 URL 语义，不转换成 Kit 自有内嵌副本，此条仅为设计建议
- 没有文件 URL 的内联图片继续使用现有图片数据存储与图片指纹路径
- 展示类型由载荷内容推导，不能直接用底层存储类型替代
- 单个 PNG 可按 Image 展示，其他图片类型不能据此推广
- 多个文件或混合文件可展示为 Files
- 普通文件和文件夹可展示为 File

这样可以同时满足文件身份、多文件单项、路径搜索和内联图片粘贴

Kit 可让数据层区分“内联图片”和“图片文件”，即使两者在展示层都使用 Image

这是本地建模建议，不表示 Raycast 已被观察到采用同样模型

### 失效规则

Kit 应在复制或粘贴前检查每个文件是否存在且可读

任一必需文件缺失时应明确失败，不能伪造复制或粘贴成功

文件失效后的清理节奏可以独立于动作前检查

Raycast `v0.63` 日志期望关联文件删除后的失效条目被清理，但本次短暂观察内旧项仍存在

因此不能把 Raycast `2.9.0.0` 描述为永久保留，也不能声称本次已经复现了清理时机

当前仍未确认清理发生在列表刷新、应用重启、定时扫描还是文件访问时

官方尚未公开以下状态是否视为失效：

- 文件移入废纸篓
- 文件改名
- 文件移动到同卷其他目录
- 文件移动到其他卷
- 外接卷断开
- 网络卷离线
- 多个文件中只缺失一部分

多文件部分失效时的动作行为仍需后续验证

## 可执行状态流

### 整项复制

当前可保留的路径：

```text
选中条目
→ 读取条目 ID
→ 准备原始内容或文件对象
→ 写入系统剪贴板
→ 添加 Kit 内部标记
→ 按设置调用 recordHistoryAction
→ 结束
```

这条路径不需要新增文件能力，适合文本、内联图片和 Kit 自有的图片数据

### 选中文本复制

需要先把预览选区提升为明确上下文：

```text
⌘C
→ 判断动作菜单是否打开
→ 判断输入法是否仍组合文字
→ 判断当前第一响应者是否可编辑且有选区
→ 判断预览是否存在文本选区
→ 没有选区时执行当前整项复制
→ 有搜索选区时复制搜索词
→ 有预览选区时复制片段
```

预览片段应携带：

```text
itemID
sourceRange
plainText
originKind
selectionRevision
```

执行前必须重新确认条目 ID、选区版本和文本内容仍然一致，避免异步 Markdown 或代码渲染后复制错项

片段写入建议使用明确的纯文本路径：

```text
准备 plainText
→ 写入 .string
→ 不添加整项复制的内部忽略标记
→ 走正常文本捕获路径
→ 创建新的文本条目
→ 不更新父条目
→ 结束
```

Kit 建议让预览选区和搜索选区采用同一正常文本捕获语义

整项复制仍走内部忽略与历史回写路径，两类动作不得共用一个“永远添加内部标记”的写入函数

### 文件条目复制

推荐目标路径：

```text
捕获到多个 fileURLs
→ 创建一条 files 条目
→ 保存每个文件的 `fileReference` 与 `metadataSnapshot`
→ 保留伴随文本用于展示和搜索
→ 复制或粘贴时一次写入全部可读文件对象
→ 按文件失效规则更新条目状态
→ 结束
```

是否允许部分文件失效后继续粘贴其余文件，需要实机确认

Kit 建议在执行文件动作前重新检查路径或引用是否有效，缺失时返回失败并保留原历史记录

失效历史记录是否立即删除属于独立清理策略，不应吞掉动作失败信息

### 图片 OCR 文本

图片条目当前没有可直接复制的 `text`，OCR 位于 `imageOCR`

如果产品需要复制图片中的文字，应使用独立动作语义：

```text
选择图片条目
→ 检查 imageOCR 是否完整且非空
→ 复制 OCR 文本
→ 按产品策略决定是否更新历史
→ 结束
```

这条动作不能与“复制图片条目”混为同一操作

## 后续验证

已测的文本选区、整项复制次数、跨来源双记录、单文件回写和单 PNG 回写不再列入待测

仍需验证的边界只有：

- 文件删除后延迟清理的触发时机
- 同来源重复文本是否合并
- 多文件条目回写到 Finder 的实际结果
- 多文件条目中部分文件缺失时的动作结果
- 从不同目录选中的文件能否在一次复制中合并

## 实现边界

本文只记录调研、实机观察和建议

未修改任何代码

未增加任何测试代码或测试脚本

未进行图形界面操作

后续文件清理结果可在“后续验证”章节补充
