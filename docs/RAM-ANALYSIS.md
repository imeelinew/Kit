# Kit 内存占用分析与优化建议

对 `/Applications/Kit.app` v0.3.1 (120) 的实测分析。所有数字来自对真实运行进程的 `footprint` / `vmmap` / `heap` 采样，以及源码逐行核对。

## 1. 结论先行

Kit 的 RAM 不是被剪贴板数据吃掉的。数据库里只有 **345 行、全部文本合计约 58 KB**，而进程 `phys_footprint` 是 **123–171 MB、峰值 260–295 MB**。

内存全部花在四件事上，按可优化空间排序：

| 排名 | 来源 | 实测占用 | 性质 |
| --- | --- | --- | --- |
| 1 | 启动时预热、关闭后不释放的整套面板视图树 | Malloc Small 46–98 MB 的主要构成 | 结构性，恒定支出 |
| 2 | 图片缩略图／预览的五层 NSCache | CG Raster 22 MB + CG Image + 缓存上限合计 120 MB | 上限过高，可 4 倍下调 |
| 3 | Vision/Espresso OCR 网络 | 常驻约 6 MB 对象 + 更大的推理 arena | 永久常驻，可避免 |
| 4 | UI 高频路径的分配抖动 | 15 万–40 万个活跃 malloc 节点 | 抬高基线并随时间增长 |

最重要的观察：**冷启动后 123 MB，运行 7.7 小时后 171 MB，活跃分配节点从 14.5 万涨到 40.5 万**。同一个空闲状态、同样关闭面板，占用却翻了近三倍。所以优化目标不只是“降低基线”，更是“让它不随时间上涨”。

## 2. 实测数据

### 2.1 三个采样点

| 采样点 | RSS | phys_footprint | 峰值 | Malloc Small | 活跃 malloc 节点 |
| --- | --- | --- | --- | --- | --- |
| 冷启动 3 分钟 | 155 MB | 123 MB | 260 MB | 46 MB | 145,607 |
| 运行 7.7 小时 | 90–159 MB | 171 MB | 295 MB | 98 MB | 404,565 |

RSS 会上下浮动（共享库页可回收），`phys_footprint` 才是真实占用。

### 2.2 内存去向明细（7.7 小时那次）

```
Dirty      Category            Regions
 98 MB     Malloc Small            185
 22 MB     CG Raster Data           81
 15 MB     CoreAnimation           103
7.7 MB     Malloc Large              2
4.1 MB     __DATA                 1081
3.9 MB     Untagged                 41
3.0 MB     CG Image                 59
3.0 MB     __DATA_DIRTY            958
1.8 MB     Malloc Metadata          17
1.7 MB     IOAccelerator            38
1.7 MB     IOSurface                12
```

`Malloc Small` 用了 **185 个独立 region**，按每个 region 至少 80 KB 的元数据与保护页计算，仅分箱开销就超过 14 MB。活跃节点只有 14.5 万（冷启动）时它只占 46 MB，说明这 98 MB 里相当一部分是碎片与元数据，不是有效负载。

### 2.3 谁持有这些对象（heap 类直方图，7.7 小时那次）

```
177,054   38.5 MB   non-object (malloc 原始块)
 43,825    1.8 MB   CFString
  5,691    0.9 MB   SwiftUICore PropertyList.Element
  5,263    0.2 MB   NSKeyValueDependency (AppKit)
  3,933    0.4 MB   Espresso blob<float,2>
  3,925    0.9 MB   Espresso quantized_weights_helper
  3,671    3.8 MB   Espresso inner_product_kernel_cpu
  3,070    0.1 MB   NSMutableDictionary
  2,952    0.3 MB   CoreSVG SVGAttribute
  2,747    0.1 MB   NSMutableArray
  2,374    0.1 MB   CFSet
  1,397    0.2 MB   CGPath
```

同时 AppKit 对象数量其实很小：`NSView` 44 个、`NSTextField` 43 个、`CALayer` 87 个、`NSTextStorage` 30 个。**这不是视图泄漏**，而是大量小型堆分配：64 字节 77,274 个、32 字节 97,114 个、48 字节 59,970 个、16 字节 27,993 个、128 字节 14,044 个、112 字节 13,870 个。

### 2.4 磁盘侧事实

| 项目 | 大小 |
| --- | --- |
| `clipboard.sqlite3` | 1.8 MB |
| `clipboard.sqlite3-wal` | 2.4 MB |
| `images/` 100 个 PNG | 28 MB（最大单个 3.0 MB） |
| 全部文本列合计 | 约 58 KB |

## 3. 根因分析

### 3.1 整套面板视图树在启动时就建好，且永不释放

[AppCore.swift:58](<Kit/Core/AppCore.swift:58>) 在 `start()` 里调用 `windowController.prewarm()`，直接走到 [PaletteWindowController.swift:148](<Kit/Core/PaletteWindowController.swift:148>) 的 `ensurePanel()`，构建 `RootPaletteView`、`PalettePanel`、`NSGlassEffectView` 外壳，以及整个 `NSTableView`。对一个纯快捷键呼出的菜单栏应用来说，用户可能一次都不打开面板，但这些对象在登录后就常驻。

关闭也不释放：[PalettePanel.swift:306](<Kit/Core/PalettePanel.swift:306>) 设置 `isReleasedWhenClosed = false`，[PaletteWindowController.swift:117](<Kit/Core/PaletteWindowController.swift:117>) 的 `hide()` 只做 `orderOut`。表视图的 cell 由 `makeView(withIdentifier:)` 回收复用，也从不缩小。

这解释了 `PropertyList.Element` 5,691 个、`NSKeyValueDependency` 5,263 个、以及大量 32/64 字节分配从哪来。

### 3.2 五层 NSCache，上限合计 120 MB，其中两层算错

| 缓存 | 位置 | 名义上限 | 问题 |
| --- | --- | --- | --- |
| `ImageThumbnail.previewCache` | [ImageThumbnail.swift:25](<Kit/Core/ImageThumbnail.swift:25>) | 48 MB | 900 px 预览约 3.2 MB/张，约 14 张。只在关闭面板时清 |
| `IconCache.cache` | [IconCache.swift:10](<Kit/Support/IconCache.swift:10>) | 32 MB | 从未清理；实际内容远小于上限 |
| `ClipboardPreviewPayload.cache` | [ClipboardPreview.swift:19](<Kit/Features/Clipboard/ClipboardPreview.swift:19>) | 16 MB / 32 项 | **成本算错**：文本项记为 1 字节，图片按 point 而非 pixel 算，实际可超 4 倍 |
| `MarkdownPreviewCache.shared` | [MarkdownPreview.swift:35](<Kit/Support/MarkdownPreview.swift:35>) | 16 MB | **成本算错**：用字符数当字节数；且缓存的 key 对象持有完整原文 |
| `ImageThumbnail.rowCache` | [ImageThumbnail.swift:18](<Kit/Core/ImageThumbnail.swift:18>) | 8 MB | 关闭面板时不清，设计如此 |

`purgePreviews()` 只清 `previewCache`（[ImageThumbnail.swift:61](<Kit/Core/ImageThumbnail.swift:61>)），其余全部依赖系统驱逐。这对应实测的 22 MB CG Raster Data —— 每张 900 px 预览的位图约 1.6 MB，浏览十几张就到位。

同时 [ClipboardStore.swift:577-588](<Kit/Core/ClipboardStore.swift:577-L588>) 每次搜索都会 `let resident = items; let membership = stackMembership`，把整个 1,000 行常驻窗口（含全部文本）复制一份交给 detached task。这是每次按键都会发生的整体拷贝。

### 3.3 OCR 后台 worker 把视觉模型永久拉进内存

[ClipboardStore.swift:629](<Kit/Core/ClipboardStore.swift:629>) 的 `startImageOCRWorkerIfNeeded()` 会遍历**整部历史**（不只是常驻的 1,000 行）为图片补 OCR，每张之间只 sleep 25 ms。

[ClipboardImageOCR.swift:35](<Kit/Core/ClipboardImageOCR.swift:35>) 在**每张图片的路径内**调用 `request.supportedRecognitionLanguages()`，只为校验语言列表。这个调用会加载 Vision 的语言识别资产。配合 [:31](<Kit/Core/ClipboardImageOCR.swift:31>) 的 `.accurate` 与 [:33](<Kit/Core/ClipboardImageOCR.swift:33>) 的 `usesLanguageCorrection = true`，选中了最大的网络。

实测常驻 Espresso 对象：`inner_product_kernel_cpu` 3,671 个共 3.8 MB、`quantized_weights_helper` 3,925 个、`blob<float,2>` 3,933 个 —— 这些是**一次加载、永久常驻**的成本，不是随图片数增长。当前库里 100 张图已全部 `complete`/`empty`，所以这是一次性支出，但代价被永久留在进程里。冷启动峰值 260 MB 就出现在这批回填期间。

值得肯定：[ClipboardImageOCR.swift:28](<Kit/Core/ClipboardImageOCR.swift:28>) 正确使用了 `autoreleasepool`，请求与 handler 对象会被释放。

### 3.4 面板关闭后不收缩

`hide()` 只在面板当时可见时才清预览缓存（[PaletteWindowController.swift:107-111](<Kit/Core/PaletteWindowController.swift:107-L111>)）。之后：

- `PaletteViewModel.results` 不清空，`loadMoreResults()`（[PaletteViewModel.swift:850](<Kit/Core/PaletteViewModel.swift:850>)）可以无限分页追加，会话内可涨到整部历史
- `ClipboardStore.items` 常驻 1,000 行从不收缩
- `previewWarmTask`（[PaletteViewModel.swift:892](<Kit/Core/PaletteViewModel.swift:892>)）完成后不置空，长期强引用第一个结果项及其完整文本
- `rowCache`、`IconCache`、`ClipboardPreviewPayload.cache`、`MarkdownPreviewCache` 都不清

### 3.5 全项目没有任何内存压力响应

全 `Kit/` 树中 `DispatchSource.makeMemoryPressureSource`、`os_proc_available_memory`、任何驱逐钩子的匹配数都是 **0**，`autoreleasepool` 全项目只有一处（OCR）。macOS 没有 `didReceiveMemoryWarning`，正确做法是挂 `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 或在面板隐藏时主动裁剪。

### 3.6 UI 高频路径的分配抖动

这些不持有内存，但在持续制造短命分配，抬高了 zone 数量与碎片，正是 32–128 字节桶里 25 万个节点的来源：

- [ClipboardTableCells.swift:516](<Kit/Features/Clipboard/ClipboardTableCells.swift:516>)：`showKind()` 每次都 `NSImage(systemSymbolName:)?.withSymbolConfiguration(...)` 造新符号图，对应实测 1,509 个 `CoreSVG SVGAttribute`
- [ClipboardTableCells.swift:172](<Kit/Features/Clipboard/ClipboardTableCells.swift:172>)：每次更新标题都 `deactivate` + `activate` 约束
- [ClipboardTableCells.swift:216](<Kit/Features/Clipboard/ClipboardTableCells.swift:216>)：截断二分搜索里每轮 `Array(source.indices)` 和 `candidate.size()`，后者触发完整文本布局
- [AttributedTextPreview.swift:88](<Kit/Support/AttributedTextPreview.swift:88>)：整段预览文本构造 `NSMutableAttributedString` 并交给 TextKit，`ensureLayout(for:)` 对全文布局（[:232](<Kit/Support/AttributedTextPreview.swift:232>)）—— 对 8 MB 的粘贴内容，glyph 与 line fragment 全量生成

渲染层的几个具体机制：

- 预览是“全量文本 + 全量布局”，不是视口裁剪。[PreviewTextView.intrinsicContentSize](<Kit/Support/AttributedTextPreview.swift:264>) 先 `ensureLayout(for:)` 全文再取 `usedRect`；[PreviewTextScrollView.updateDocumentGeometry](<Kit/Support/AttributedTextPreview.swift:226>) 把 `containerSize` 的高度设为 `.greatestFiniteMagnitude`，TextKit 会把整段文字的 glyph 与 line fragment 全部生成。可见区域以外的布局数据全部驻留。
- 内容标识符携带全文。[PreviewContentID](<Kit/Support/AttributedTextPreview.swift:5>) 的 `source: String` 保存整段预览文本，而它被放进 `Input: Equatable`（[:47](<Kit/Support/AttributedTextPreview.swift:47>)），每次 SwiftUI 更新都要做一次整串相等比较。
- 属性串每帧重建。[SearchHighlight.attributed](<Kit/Support/SearchHighlight.swift:9>) 每次调用都新建 `AttributedString` 并跑一遍 `applyFallback`；[ClipboardTextPreview](<Kit/Features/Clipboard/ClipboardPreview.swift:171>) 虽然声明了 `Equatable`，但 `attributed` 是在 `body` 里现算的，等于每次求值都重建。
- 搜索高亮的匹配范围每次重算。[SearchHighlight.matchingRanges](<Kit/Support/SearchHighlight.swift:61>) 对源串做 `range(of:options:)` 循环，源串是整段文本，不缓存在条目上。
- `NerdSymbolsFont.applyFallback` 的两个重载都会把整串转成数组／`NSString` 再扫描（[NerdSymbolsFont.swift:37](<Kit/Support/NerdSymbolsFont.swift:37>)、[:84](<Kit/Support/NerdSymbolsFont.swift:84>)）。设计上已限定只处理私用区，但 `privateUseRanges` 的全串遍历仍是 O(全文)。
- 万幸的是，[NerdSymbolsFont.swift:55](<Kit/Support/NerdSymbolsFont.swift:55>) 对普通文本走的是提前返回（`guard !ranges.isEmpty else { return }`），没有为每个字符分配 glyph 缓冲。

综合起来：对一条 8 MB 的粘贴内容，一次选中就会同时产生（a）原文 `String`、（b）`NSMutableAttributedString` 副本、（c）TextKit 的 `NSTextStorage` 字符存储、（d）全量 glyph 与 line fragment、（e）`PreviewContentID` 里的又一份原文引用。这是文本类条目在列表里上下移动时最主要的瞬时占用。

## 4. 优化清单

按“预期收益 / 风险比”排序。前四项是低风险高收益。

### P0 — 立刻可做，行为不变

| # | 改动 | 预计收益 | 风险 |
| --- | --- | --- | --- |
| 1 | 把 `supportedRecognitionLanguages()` 移出每图路径，进程内只校验一次或直接静态信任语言表（[ClipboardImageOCR.swift:35](<Kit/Core/ClipboardImageOCR.swift:35>)） | 避免每张图重新拉取语言资产 | 无，语言表由应用固定 |
| 2 | 修正两处成本计算：`ClipboardPreview` 用真实位图字节、文本项给真实成本（[ClipboardPreview.swift:66](<Kit/Features/Clipboard/ClipboardPreview.swift:66>)）；`MarkdownPreviewCache` 按属性串实际占用计费（[MarkdownPreview.swift:85](<Kit/Support/MarkdownPreview.swift:85>)） | 让现有上限真正生效，避免超限 4–10 倍 | 无 |
| 3 | `purgePreviews()` 里同时清 `rowCache`；补齐 [PaletteWindowController.swift:107](<Kit/Core/PaletteWindowController.swift:107>) 的提前返回分支 | 空闲时省约 8 MB | 下次打开多一次解码，面板本就预热 |
| 4 | `previewWarmTask` 完成后置空（[PaletteViewModel.swift:892](<Kit/Core/PaletteViewModel.swift:892>)） | 去掉对首个结果项及其文本的会话级强引用 | 无 |

### P1 — 需要少量验证

| # | 改动 | 预计收益 | 风险 |
| --- | --- | --- | --- |
| 5 | `previewCache` 上限 48 MB → 16 MB（[ImageThumbnail.swift:27](<Kit/Core/ImageThumbnail.swift:27>)） | 最多省 32 MB，直接压低 CG Raster Data | 回看历史时重新解码，SSD 上每张数毫秒 |
| 6 | 挂 `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`，在 `.warning` 时清四层缓存并裁剪 `results` | 系统压力下不再是被杀的那个 | 无，需要新代码 |
| 7 | 面板隐藏时把 `results` 截断回默认页、并清 `IconCache`／`MarkdownPreviewCache` | 消除唯一能涨到整部历史的集合 | 重开面板丢失滚动位置，与现有“下次呈现即重置”的意图一致 |
| 8 | 搜索时不要整体复制常驻窗口（[ClipboardStore.swift:580](<Kit/Core/ClipboardStore.swift:580>)）：查询为空时跳过，或只捕获谓词所需字段 | 去掉每次按键的整体拷贝，很可能是 295 MB 峰值的主因 | 低。常驻 overlay 只是为了让刚捕获、拼音索引还没写好的中文立刻可搜 |
| 9 | 设置窗口关闭时释放（[KitSettingsWindowController.swift:55](<Kit/Features/Settings/KitSettingsWindowController.swift:55>)） | 省下整个 `NavigationSplitView` 与其状态栈 | 重开需重建，约数十毫秒 |

### P2 — 结构性，需先测量

| # | 改动 | 预计收益 | 风险 |
| --- | --- | --- | --- |
| 10 | `prewarm()` 只建面板外壳，`RootPaletteView` 推迟到首次 `show()`（[PaletteWindowController.swift:43](<Kit/Core/PaletteWindowController.swift:43>)） | 最大的一笔结构性节省，直接砍掉常驻视图树 | 直接影响首次呼出延迟，而 `prewarm()` 存在的唯一目的就是保护它。必须先测“按键到可见”耗时 |
| 11 | 后台 OCR 改用 `.fast`，或只索引最近 N 张图（[ClipboardImageOCR.swift:31](<Kit/Core/ClipboardImageOCR.swift:31>)） | 让 Espresso 推理图根本不实例化 | 图片文字搜索召回下降，但 OCR 只是搜索元数据，不改变内容 |
| 12 | 降低 UI 抖动：符号图缓存、约束只在切换图片行时换、截断用 TextKit 原生截断替代二分（[ClipboardTableCells.swift:172](<Kit/Features/Clipboard/ClipboardTableCells.swift:172>)、[:216](<Kit/Features/Clipboard/ClipboardTableCells.swift:216>)、[:516](<Kit/Features/Clipboard/ClipboardTableCells.swift:516>)） | 减少 zone 数量与碎片，直接缩小 Malloc Small | 截图式 UI 回归测试需要覆盖，改动点在绘制路径 |

## 5. 优先级建议

先做 1–4（半天，几乎无风险，并且第 2 项让后续上限调整真正生效），再单独做 5。第 6、7、8 项解决的是“随时间上涨”，建议一起上并做一次 24 小时驻留对比。

第 10 项收益最大但直接触碰应用的核心体验承诺，应该先量数据再决定：记录从按下快捷键到面板首帧的耗时，如果当前已是数十毫秒且延迟建成后仍在可接受范围，才值得动。

## 6. 附：复现测量命令

```bash
PID=$(pgrep -f "/Applications/Kit.app/Contents/MacOS/Kit" | head -1)
footprint $PID                     # phys_footprint / 峰值 / 分类明细
heap $PID                          # 分配节点总数与类直方图
heap $PID -s                       # 按字节排序的类直方图
vmmap $PID | grep -E "MALLOC"      # malloc region 数量与元数据
```
