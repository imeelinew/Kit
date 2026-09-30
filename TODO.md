# TODO

## 连续撤销动画错位（未修复，优先级：中）

**症状**：连续快速 ⌘Z 撤销删除时，列表行有概率视觉错位（行的显示位置和逻辑位置脱钩）。
单次撤销、连续删除都正常，只有"持续撤回"会触发，且是概率性的。

**已尝试但未解决**：commit `614a338`（Defer follow scrolls until row animations settle）——
把与行编辑动画并发的 `.follow` 滚动推迟到动画结束后执行。逻辑本身是对的（有回归测试锁定，
CI 全绿），但**用户实测问题依旧**——说明错位另有来源，或不止一个来源。该修复建议保留。

### 复现

列表条目较多（需要能滚动）时，快速连续按 ⌘Z 多次。恢复的条目位置分布越散、当前滚动位置
越深，越容易触发。

### 已确认的事实

1. 删除路径从不改 `scrollIntent`（`apply(scroll:)` 不执行）；撤销每次发新 nonce，必触发
   `.follow` 滚动——这是删除正常、撤销出问题的结构性差异。
2. 撤销是异步刷新（`PaletteViewModel.refreshResults`）：连续按 ⌘Z 会取消旧搜索任务、
   动画彼此重叠；任务开头还有 `waitForSearchMetadata()`（拼音写入含 100ms 重试路径）。
3. 行编辑动画在 `ClipboardView.updateRows()`：`beginUpdates/endUpdates` +
   `removeRows/insertRows` + 动画组内 `noteHeightOfRows(0)`；行差分用
   `CollectionDifference`（remove+insert，不是 move）。

### 明天的排查建议（按性价比排序）

1. **二分定位**：把 `ClipboardView.update()` 里动画条件的 `|| scroll.kind == .follow`
   临时去掉（撤销插入不做动画）。错位消失 → 问题在插入动画路径；依旧 → 问题在别处
   （差分结果本身 / 异步任务重叠）。
2. **慢放观察**：`Theme.Motion.contentDuration` 临时改成 `1.0`，肉眼看清错位发生在
   哪一帧、是瞬时还是持续到下次 reloadData。
3. **疑点清单**（都未验证）：
   - 连续撤销时第二个 `insertRows` 动画叠加在未完成的第一个动画上（与滚动无关的
     AppKit 并行动画问题）
   - 恢复条目改变日期分组时，差分产生的 remove+insert 索引映射与真实变换不符
     （分组头位移）
   - 动画组内 `noteHeightOfRows(0)`（首行高度变化）与插入并发
   - `applySelection` 的 `selectRowIndexes` 在动画飞行中执行
   - `scrollToTop` 的 `reflectScrolledClipView` 与动画交互

### 相关文件

- `Kit/Features/Clipboard/ClipboardView.swift` — `update()` / `updateRows()` / `apply()`
- `Kit/Core/PaletteViewModel.swift` — `undoDeletion()` / `refreshResults()`
- `Kit/Core/ScrollIntent.swift`
- 回归测试：`tests/ClipboardListAnimationTests.swift`（撤销形态的滚动推迟断言，保留）

---

## 预览面板主线程 O(n) 重建（未修复，优先级：中）

**症状**：选中较大条目后，预览面板的**每次** SwiftUI 更新都会在**主线程**重建整段富文本，
并对**每个字符**做一次字形回退扫描。Markdown 路径约 0.1s/次，代码路径无长度上限，
最坏可到秒级卡顿。

**根因**：`AttributedTextPreview.updateNSView` 无条件调用 `nsAttributed(from:)`，后者调用
`NerdSymbolsFont.applyFallback`，其实现是逐字符 `rangeOfComposedCharacterSequence` +
两次 `CTFontGetGlyphsForCharacters`；随后还要用 `textView.currentAttributedString() != ns`
全串比较（同为 O(n)）。该扫描循环实测约 2.5–4.5M chars/s。

**影响范围**：

- `.markdown`：受 `MarkdownAttributedRenderer.maximumRenderedBytes = 512 * 1024` 约束 → 约 0.11s/次
- `.code`：**没有任何尺寸上限**（仅受 `ClipboardCapturePipeline.maxTextBytes = 8MB` 约束）
  → 最坏约 1.8s/次。语法高亮本身已放在 detached task（那部分是好的），
  被拉回主线程的是「转换 + 字形回退」这一步
- `.text` / `.path` / `.link`：`ClipboardTextPreview` 带 `.equatable()` 保护，通常不触发

**建议修法（按性价比排序）**：

1. 给 `NerdSymbolsFont.applyFallback` 加廉价前置判断：只有字符串含 PUA 区段
   （`0xE000...0xF8FF`、`0xF0000...`）时才走逐字符扫描——该函数存在的唯一理由是
   Nerd Font 图标，对绝大多数真实文本可直接跳过。单这一条就能消掉绝大部分开销
2. `updateNSView` 按输入 identity 记忆化转换结果，不要每次重建再比较
3. 给代码预览加与 Markdown 同级的字节上限（超出回落纯文本）

**相关文件**：

- `Kit/Support/AttributedTextPreview.swift` — `updateNSView` / `nsAttributed(from:)`
- `Kit/Support/NerdSymbolsFont.swift` — `applyFallback`
- `Kit/Support/MarkdownAttributedRenderer.swift` — `maximumRenderedBytes`
- `Kit/Support/CodeSyntaxHighlighter.swift` — `CodePreview`（无上限）
- `Kit/Core/ClipboardCapturePipeline.swift` — `maxTextBytes`

---

## 预览滚动位置状态机是死代码（待删除，优先级：低）

`scrollPosition` 与 `onScroll` 从 `AttributedTextPreview` 一路透传到 `MarkdownPreview` 和
`CodePreview`，但**全项目没有任何调用方传入**（`ClipboardPreview` 两个都不传），
整条滚动位置保存/恢复逻辑从未被执行。

**待删除**：

- `Kit/Support/AttributedTextPreview.swift`：`scrollPosition` / `onScroll` 属性与两个 init 参数、
  `desiredScrollPosition`、`restoringScrollPosition`、`lastReportedScrollPosition`、
  `setScrollPosition`、`restoreScrollPosition`、`clampedScrollPosition`、`CGPoint.nearlyEquals`，
  以及 `layout()` / `reflectScrolledClipView` 中相关分支（约 60 行）
- `Kit/Support/MarkdownPreview.swift`：`scrollPosition` / `onScroll` 属性与透传
- `Kit/Support/CodeSyntaxHighlighter.swift`：`CodePreview` 的 `scrollPosition` / `onScroll` 属性与透传

**替代方案**：若希望保留「切换条目时恢复预览滚动位置」这个能力，则应改为接上调用方，而不是删除。

---

## VisualEffectView.swift 是死文件（待删除，优先级：低）

`Kit/Core/VisualEffectView.swift`（21 行）全项目零引用。在做全项目类型引用扫描时，
它是唯一一个没有任何外部引用的类型声明（`KitApp` 是 `@main`，属误报）。

`PalettePanel` 已直接在 AppKit 层创建 `NSVisualEffectView`（frosted 样式）与
`NSGlassEffectView`（liquid 样式），不再需要这个 SwiftUI 包装。

**待删除**：`Kit/Core/VisualEffectView.swift`
