# Kit 重构、最佳化与裁剪计划

本文件只描述现况与建议，不修改任何产品程式，范围是整个仓库：Swift 原始码、测试脚本、建置设定、资源与文件，数字以本次检视时的程式为准，应用程式本体 62 个 Swift 档、约一万五千行，测试 22 个档、约六千行，依赖只有 KeyboardShortcuts、Sparkle、swift-markdown（连带 swift-cmark），以及系统 `sqlite3`

## 结论

Kit 的采集策略、贴上事务、WAL 图片回收与缩图解码排程已经清楚，不该整包重写，真正拖累维护与执行期的是四件事：

1. `ClipboardStore` 在主执行绪上同时做资料库、全文索引、拼音、图片识字、档案巡检、堆叠与复原
2. 记忆体视窗保留最多 1000 笔完整文字，搜寻还会再复制一份
3. 剪贴簿读取用并行的 `Task.detached`，失败的查询又被画成空列表
4. 单一 App 目标把领域、储存与 AppKit 外观捆在一起，测试不进 Xcode，也不进 CI

裁剪应先删确定没用的资源与打包项，再拆档但不改行为，最后才动记忆体模型与执行绪边界

## 现况架构

资料流与 `docs/architecture/架构图.md` 一致：`KitApp` 启动 `AppCore`，`ClipboardManager` 每 0.1 秒看一次 `NSPasteboard.changeCount`，快照交给 `ClipboardCapturePipeline`，写入 `ClipboardStore`，调色盘由 `PaletteViewModel` 分页查询，贴上走 `PasteTransaction` 与 `Paster`

目录只是分组，不是模组，`Kit.xcodeproj` 只有一个 `Kit` 目标，`Kit/Core` 同时放领域、SQLite、视窗、主题与卷轴，`Kit/Features` 同时放 SwiftUI 与直接呼叫 `AppCore.shared` 的设定页，没有 `Package.swift`，测试用 `scripts/test.sh` 以 `@testable import Kit` 编 Debug App，不使用 XCTest 目标，GitHub Actions 只有 `.github/workflows/publish-appcast.yml`，不跑测试

已值得保留、重构时不要改语意的部分：

- `ClipboardCapturePolicy` 是纯函式，敏感类型与排除清单可测
- `PasteTransaction.run` 把权限、准备、目标就绪、写入、投递分成固定顺序
- 图片删除走 `pending_blob_deletions`，崩溃后可重试，且 `managedBlobURL` 拒绝任意路径
- `ImageThumbnail.DecodeCoordinator` 限制同时解码数，列缩图与预览分开计成本
- `SWIFT_STRICT_CONCURRENCY = complete`，储存与识别器已可注入目录与闭包

## 具体发现

### 1. 储存型别过大，主执行绪承担写入

`Kit/Core/ClipboardStore.swift` 约 1565 行，标成 `@MainActor`，同一型别拥有连线、十四个预编译 statement、记忆体视窗、堆叠、单笔复原、保留期、拼音伫列、OCR 工人、档案巡检、缩图预热与 blob 删除

热点：

- `insert`、`refresh`、`prune`、`clearAll`、`saveImageOCR`、`reconcileFileSource` 都在主执行绪 `sqlite3_step`
- 插入会触发 `Kit/Core/ClipboardSQLite.swift` 的 `items_ai`，FTS5 `tokenize='trigram'` 对正文、拼音、拼音首字母各建一份索引，大段文字的索引写入会卡住调色盘
- `clearAll` 用 `DELETE FROM items`，每一列都跑删除触发器，仍在主执行绪
- `publishDeferredHistoryUpdates` 直接呼叫 `load()`，连堆叠状态一起重读
- `openDatabase` 失败时只 `return`，之后 `loadStmt == nil`，历史静默变成空的，没有 `sqlite3_errmsg`，也没有 `Logger`，全专案只有 `Paster` 与 `ClipboardFileAccess` 使用 `os.Logger`
- `stacks.position` 只在 `createStack` 写入 `stacks.count`，没有重排 API，栏位有用（排序），但不要在这次重构加拖曳排序

`Kit/Core/ClipboardSearch.swift` 的 `queryDatabase` 每次查询都 `sqlite3_open_v2` 再开一条唯读连线，WAL 下这是正确方向，但连线建立没有复用，`busy_timeout` 只有 500 毫秒，查询失败、取消、锁等待都回传 `nil`，`ClipboardStore.searchAsync` 把 `nil` 收成空的 `ClipboardSearchPage`，调色盘会把「资料库忙」画成「没有结果」

关闭图片文字搜寻时，`textPredicate` 仍可能命中档案路径里的拼音栏，程式用 `validatesFileImageText` 把 `LIMIT` 绑成 `-1`，先取出全部候选再在 Swift 里过滤，历史变长后，短查询会一次拉进大量列

拼音是插入后非同步写的，所以第一页还要把居民列送进 `ClipboardSearch.query` 做记忆体比对，这补上索引空窗是对的，但送进去的是完整 `ClipboardItem`，不是待索引 id

栏位投影有两份，`ClipboardStore.itemSelection` 与 `ClipboardSearch` 的 `SELECT` 各自列栏位，`ClipboardSQLite.row` 用写死的栏位编号，搜寻多读第 16 栏 `rowid`，以后加栏位很容易整列变成 `nil` 并被静默丢掉

### 2. 记忆体：一千笔全文，加上搜寻复制

`ClipboardStore.memoryWindow` 是 1000，`items` 保存完整 `text`，`ClipboardCapturePipeline.maxTextBytes` 是 8 MiB，没有对应的图片位元组或像素上限，`addImage` 只做 SHA-256 与 PNG 正规化，`normalizedPNG` 用 `NSBitmapImageRep` 解出第一帧，超大截图会在采集 actor 上放大记忆体

`PaletteViewModel.refreshResults` 每次按键或 `revision` 变化都重查 `pageSize * loadedPageCount`（页大小 160），`searchAsync` 在第一页且查询非空时，把符合筛选的居民列整包传进 `Task.detached`，列表列型别 `ClipboardTableRow.item(ClipboardItem)` 又把全文放进 `Equatable`，`resultsGeneration` 变化时 `Kit/Features/Clipboard/ClipboardView.swift` 会 `reloadData()`，比对与重载都跟着全文走

预览另算一次成本，`ClipboardPreviewPayload.load` 对选中文字逐个 Unicode scalar 数字数与字数，8 MiB 文字可以接受在背景做，但不该同时留在主执行绪的千笔阵列里

`ImageThumbnail.removeCachedImage(for:)` 名为删一张，实作是 `rowCache.purge()` 与 `previewCache.purge()`，`deleteBlob` 与 blob 回收工人每删一张图就清掉全部记忆体缩图，磁碟缩图有按 URL 删除，记忆体快取没有

### 3. 剪贴簿轮询与并行读取

`ClipboardManager.pollInterval` 是 0.1 秒，`Timer` 加在主 RunLoop `.common`，没有 `tolerance`，暂停时计时器仍每秒触发约十次，只为了更新 `changeCount`

`poll` 为每次变化建立 `Task.detached` 呼叫 `readSnapshot`，`captureTail` 只把后续处理串成顺序，读取本身并行，`NSPasteboard` 没有执行绪安全保证，快速连续复制时，多个背景工作会同时读同一块剪贴簿，处理链有 `changeCount` 复核，能丢掉过期快照，挡不住并行读取本身

0.1 秒是为了缩短「复制当下的前景 App」归属窗口，这是产品取舍，不是必须维持的实作，建议改成单一序列伫列读取，主执行绪只读 `changeCount` 与型别，把位元组复制出去后再解码，计时器加上 tolerance，连续数秒没有变化时把间隔放宽，一有变化再回到短间隔，不要为了省电把归属窗口放到接近旧的 0.5 秒而不另记前景 App

### 4. 图片识字与档案巡检

`ClipboardImageTextRecognition.recognize` 每次都 `supportedRecognitionLanguages()`，再用 `.accurate` 跑 Vision，语言含 `zh-Hans`、`zh-Hant`、`en-US`，工人在 `startImageOCRWorkerIfNeeded`，每张图之间只让出 25 毫秒，大量历史回填时 CPU 会长期占用，语言支援清单应快取，调色盘开启或使用者正在搜寻时应降优先级，而不是取消已完成的索引

`startFileRefreshIfNeeded` 从 `load()` 启动后每 15 秒跑一次，没有档案也会醒，`refreshFileReferences` 在主执行绪把所有 `file_is_image = 1` 的列读进阵列，再逐个做书签与 `stat`，选中预览的 `ClipboardPreviewPayload.load` 还会再呼叫 `refreshFileReference`，同一签名比对在 OCR 工人里又写了一次

### 5. 半成品与死资源

`ClipboardItem.customTitle` 有栏位、列表显示、搜寻 `LIKE` 与测试往返，`ClipboardStore` 没有重新命名方法，选单与设定也没有写入入口，每一列读取与搜寻仍为它付费，冻结它：重构不要扩充，除非另案做最小重新命名，不要在没有迁移计划时直接删栏

未使用的图示：`Kit/Assets.xcassets/lucide-history.imageset`，设定页只用 `lucide-settings`、`lucide-keyboard`、`lucide-sun-moon`、`lucide-volume-2`、`lucide-clipboard`、`lucide-info`（`Kit/Features/Settings/SettingsTab.swift`），原始码没有 `lucide-history`

`Kit.xcodeproj/project.pbxproj` 把字体说明 `Kit/Resources/Fonts/README.md` 放进 App Resources，`AboutSettingsView` 不读它，档案要留在仓库，打包项可以拿掉

重复的二进位资源，杂凑相同：

| 档案 | 约略大小 | 说明 |
| --- | --- | --- |
| `.github/assets/logo.png`、`.github/assets/readme-icon.png`、`docs/site/assets/icon.png` | 各 1.4 MB | 同一张图三份 |
| `.github/assets/readme-screenshot.png`、`docs/site/assets/screenshot.png` | 各 972 KB | 同一张截图两份 |
| `.github/assets/app.png` | 1.1 MB | 没有第二份，但是大图 |

静态站与 README 需要可独立开启的路径，不必删光，应留一份主档，其余改引用或缩小到实际显示尺寸，README 图示显示宽度是 112

不要删的资源：

- `SymbolsNerdFontMono-Regular.ttf` 约 2.5 MB，`NerdSymbolsFont` 要给剪贴簿里任意私人使用区字元做回退，无法安全子集化
- JetBrains Mono 与两份授权文字，预览与法规都要用
- 四个复制音效，设定页有对应选项

### 6. 模组边界与重复

分类器依赖渲染器，`ClipboardTextClassifier.kind(for:)` 呼叫 `MarkdownAttributedRenderer.isMarkdown`，采集路径因此连到 swift-markdown 与整棵 AppKit 属性字串渲染，判断「有没有 Markdown 结构」应留在领域层，渲染留在 `Kit/Support/MarkdownAttributedRenderer.swift`

文字预览有三条路，职责不同，不要合成一个套件，但可以共用一个文字视图生命周期：

- `Kit/Support/AttributedTextPreview.swift`
- `Kit/Support/MarkdownPreview.swift` 与 `MarkdownAttributedRenderer.swift`（约 428 行）
- `Kit/Support/CodeSyntaxHighlighter.swift` 的正则词法上色

`CodeSyntaxHighlighter` 对整段（上限 512 KiB）跑多条正则再排序，选中程式码时这是 CPU 热点，可先维持规则，把工作留在已取消即停的背景，避免在主执行绪呼叫 `highlight`

过大的档，适合拆档而不是重写：

| 档案 | 约略行数 | 建议切法 |
| --- | --- | --- |
| `Kit/Core/ClipboardStore.swift` | 1565 | 连线与 CRUD、保留期、堆叠、复原、索引工人分开 |
| `Kit/Features/Clipboard/ClipboardView.swift` | 999 | 表格协调与卷动几何分开 |
| `Kit/Features/Clipboard/ClipboardPreview.swift` | 950 | `ClipboardPreviewPayload` 与视图分开 |
| `Kit/Core/PaletteViewModel.swift` | 942 | 搜寻分页与选单状态机分开 |
| `Kit/Features/Clipboard/ClipboardTableCells.swift` | 711 | 列布局维持，标题与缩图载入可再分 |
| `Kit/Features/PopoverMenu.swift` | 679 | 维持自订选单，不要改成 `NSMenu` |
| `Kit/Core/ImageThumbnail.swift` | 544 | 档案签名快取与解码协调器分开 |
| `Kit/Core/PalettePanel.swift` | 490 | 视窗行为维持 |
| `Kit/Features/RootPaletteView.swift` | 476 | 布局维持 |

`Kit/Core/MenuBarController.swift` 末尾的 `CopySoundPlayer` 与选单列无关，应跟音效资源放在一起，`Kit/Core/Theme.swift`、`ThinScrollbar.swift`、`EdgeDissolve.swift` 是介面，不该继续放在 `Core`

`AppCore.shared` 被选单、设定、贴图、档案授权、触觉、更新服务直接抓取，`PaletteViewModel` 已经接收 `AppCore`，测试也用 `AppCore(clipboardStore:)`，新的画面依赖应沿这条建构子走，不要再增加 `shared` 呼叫点，`PaletteHaptics`、`ClipboardFileAccess.showFailure`、`UpdateService` 仍读全域状态

反应式风格有三套：`PaletteViewModel` 是 `@Observable`，却用 Combine 听 `clipboardStore.$revision`，`AppSettings` 与 `UpdateService` 是 `ObservableObject`，不要为了统一而一次改完，新程式跟所在画面的既有风格走，拆 `ClipboardStore` 时不要顺便把 `@Published` 改掉

`Kit/Info.plist` 的 `LSApplicationCategoryType` 是 `public.app-category.productivity`，目标建置设定又写了 `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities`，上架类别以实际合并结果为准，两处应收成一个来源

沙盒是关的（`Kit/Kit.entitlements`），剪贴簿历史、辅助使用与档案书签需要这个选择，不要把开启沙盒列进裁剪阶段

### 7. 错误处理

多数储存 API 回传 `Bool` 或 `nil`，呼叫端无法区分锁、磁碟满、约束失败与「没有这一列」，`addImage` 写档失败就返回，不通知，`CopySoundPlayer` 播放失败只把 player 设回 `nil`

建议的最低线：SQLite 失败记 `sqlite3_errmsg` 与 SQL 名称，开库失败要让启动路径可见，而不是继续跑一个永远插入失败的 store，搜寻要能表示失败，让列表维持上一页，而不是清空，不需要引入新的错误处理框架

### 8. 测试与建置

测试品质比目标结构好，`docs/dev/TESTING.md` 与 `scripts/test.sh` 覆盖分类、几何、贴上事务、储存、设定、搜寻、调色盘、采集、日期、图片与旧回归，储存测试使用暂存目录，不启动轮询与 Sparkle

缺口：

- 没有 Xcode 测试目标，`ENABLE_TESTABILITY` 只为了脚本连结 Debug App
- 七个 runner 各自编译，CI 不跑
- 真实轮询、辅助使用、Sparkle、登入启动仍靠人工，这是合理的，不该用单测假装覆盖
- `scripts/benchmark-palette-opening.swift` 已在，重构前后应用它看开窗，而不是只看体感

建置本身没有明显的多余编译旗标，Release 已是 whole module 与 `-O`，不要为了「整理」改 Swift 6.4、部署目标 macOS 27 或严格并行

文件方面，`docs/architecture/架构图.md` 与同名 HTML、`复制流程.html`、`docs/research/raycast-clipboard-research.md` 是研究材料，不是死码，可留在仓库，不要在裁剪程式时一并删除

## 建议目标架构

仍是单一 App 目标，先按档案边界拆，确认测试仍绿，再考虑本机套件，不要一开始拆成多个 Swift package

```text
App
  KitApp、ApplicationMenu、AppCore
  AppCore 只做组装、快捷键、视窗与传输任务

Capture
  ClipboardManager、ClipboardCapturePipeline、ClipboardCapturePolicy
  主执行绪只观察 changeCount
  一条序列伫列拥有 NSPasteboard 读取

Domain
  ClipboardItem、Kind、Retention、Stack
  ClipboardTextClassifier
  Markdown 结构判断的纯函式，不引用渲染器

Storage
  ClipboardSQLite          结构、迁移、栏位投影
  ClipboardDatabase        连线、交易、错误
  ClipboardHistoryStore    插入、去重、分页读取、复原、保留期
  ClipboardStackStore      堆叠
  SearchIndexWorker        拼音，离开主执行绪
  ImageTextIndexWorker     OCR
  FileReferenceMonitor     签名与书签

Search
  ClipboardSearch          查询规划与 FTS
  一条长寿的唯读连线

Transfer
  PasteTransaction、Paster、Permissions、ClipboardFileAccess

UI
  Palette 视窗、状态、列表、预览、选单
  Settings、MenuBar、PinnedImage
  Theme、卷轴、边缘淡出
```

记忆体模型改成列表投影：id、种类、标题片段、时间、来源、是否有图、档案是否为图，全文与图片位元组按预览与贴上再读，FTS 仍可索引全文，但索引写入不要跟列表投影的发布绑在同一次主执行绪交易里，若要限制索引成本，正文索引用前缀上限，完整内容仍存 `items.text`，这是行为取舍，要单独做，并用现有搜寻测试锁住「前缀以内的命中」

`AppCore.shared` 可以留下给 `KitApp` 与选单列，设定页与贴图改为接收 store、settings、updateService，这一步不改变快捷键与贴上顺序

## 删除与裁剪

可以直接删或解除打包，风险低：

- 删除 `Kit/Assets.xcassets/lucide-history.imageset`
- 从 `project.pbxproj` 的 Resources 移除 `README.md`，仓库档案保留
- 行销图留一份主档，另外三份 icon 与一份截图改为引用或缩小

冻结，不在本计划实作，也不要顺便扩充：

- `customTitle` 的写入 UI
- 堆叠拖曳重排
- 把 `PopoverMenu` 换成 `NSMenu`
- 子集化 Nerd Font
- 开启 App Sandbox
- 把研究 HTML 与 Raycast 笔记移出仓库

可以稍后再拆、现在不要删的大档：`ClipboardStore`、`ClipboardView`、`ClipboardPreview`、`PaletteViewModel`、`ImageThumbnail`，它们大，但是活的

## 优先顺序

影响是使用者可感知的流畅度、记忆体或正确性，工作量是改动面，风险是行为回归机率

### 高

| 项目 | 影响 | 工作量 | 风险 | 位置 |
| --- | --- | --- | --- | --- |
| 列表只留投影，全文按需读取 | 高 | 中 | 中 | `ClipboardStore` 记忆体视窗与 `searchAsync` 居民列、列表储存格 |
| 剪贴簿读取改成单序列，解码放在复制之后 | 高 | 中 | 中 | `ClipboardManager.readSnapshot` |
| 搜寻失败不要变成空列表 | 高 | 低 | 低 | `ClipboardSearch.queryDatabase`、`ClipboardStore.searchAsync`、`PaletteViewModel.refreshResults` |
| 大文字插入与 FTS 触发器离开主执行绪关键路径 | 高 | 中 | 中 | `ClipboardStore.insert`、`ClipboardSQLite` 触发器 |
| 删一张图只失效该 URL 的记忆体缩图 | 高 | 低 | 低 | `ImageThumbnail.removeCachedImage` |
| 关闭图片文字搜寻时不要 `LIMIT -1` 全表拉取 | 高 | 低 | 中 | `ClipboardSearch.textPredicate` 与绑定参数 |

### 中

| 项目 | 影响 | 工作量 | 风险 | 位置 |
| --- | --- | --- | --- | --- |
| 拆 `ClipboardStore`，行为不变 | 中 | 中 | 中 | 同上，先搬移 OCR、档案巡检、拼音工人 |
| 复用唯读连线，记录 `sqlite3_errmsg` | 中 | 低 | 低 | `ClipboardSearch`、`openDatabase` |
| 档案巡检不要在主执行绪一次载入全部图片档列 | 中 | 中 | 中 | `refreshFileReferences`，15 秒回圈 |
| 图片像素或位元组上限 | 中 | 低 | 中 | `ClipboardCapturePipeline.normalizedPNG`、`addImage` |
| OCR 语言清单快取，回填在调色盘互动时降优先级 | 中 | 低 | 低 | `ClipboardImageTextRecognition` |
| 轮询计时器加 tolerance，空闲放宽间隔 | 中 | 低 | 中 | `ClipboardManager.start` |
| 单一栏位投影，去掉魔术编号 | 中 | 中 | 中 | `ClipboardSQLite.row`、两处 `SELECT` |
| 分类器与 Markdown 渲染脱钩 | 中 | 低 | 中 | `ClipboardTextClassifier.kind` |
| 减少新的 `AppCore.shared`，设定与贴图改建构子 | 中 | 中 | 中 | 设定页、`PinnedImageWindow`、`ClipboardFileAccess` |
| 测试进入 CI，至少跑 `scripts/test.sh` 的子集或全量 | 中 | 中 | 低 | `.github/workflows`，目前只有 appcast |

### 低

| 项目 | 影响 | 工作量 | 风险 | 位置 |
| --- | --- | --- | --- | --- |
| 删未用图示、停止打包 README、合并重复行销图 | 低 | 低 | 低 | 资产与 `project.pbxproj` |
| 类别键收成一处 | 低 | 低 | 低 | `Info.plist` 与建置设定 |
| `CopySoundPlayer` 移出选单列档 | 低 | 低 | 低 | `MenuBarController.swift` |
| `Theme`、卷轴、边缘淡出移到 UI 目录 | 低 | 低 | 低 | `Kit/Core` |
| 统一 Observable 与 Combine | 低 | 高 | 中 | 全 App，现在不做 |
| 抽成本机 Swift package | 低 | 高 | 中 | 拆档稳定之后才考虑 |
| 程式码高亮改增量或真正的语法树 | 低 | 高 | 中 | `CodeSyntaxHighlighter`，现在只保证不在主执行绪跑 |

## 分阶段推出

每一阶段结束都要能单独合并，先跑 `scripts/test.sh`，有开窗与列表变更时加跑 `scripts/benchmark-palette-opening.swift`，不要把储存拆分和记忆体模型放在同一个变更里

### 阶段 0：基线

不改行为，记录现有测试指令与开窗基准，确认 `openDatabase` 失败时今天的症状（空历史、无日志），避免后面把旧问题当成回归

### 阶段 1：裁剪与可观察性

删 `lucide-history`，解除 README 打包，收敛 App 类别键，SQLite 失败写日志，搜寻区分取消、失败与零笔，删图时只清该 URL 的记忆体缩图

这个阶段不改结构描述，也不改索引内容，搜寻测试要新增「锁等待或准备失败时保留上一页」这类案例，现有零笔查询测试保持不变

### 阶段 2：拆档，行为冻结

把 OCR 工人、档案巡检、拼音伫列、堆叠、保留期从 `ClipboardStore.swift` 搬到同目标的新档，公开方法签名先留在原型别上转呼叫，`ClipboardPreviewPayload` 移出视图档，`CopySoundPlayer` 移出选单列

验收是 diff 以搬移为主，`scripts/test.sh` 全绿，不要在此阶段改 SQL

### 阶段 3：执行绪与查询

剪贴簿读取序列化，计时器加 tolerance，唯读连线复用，关闭图片文字搜寻时用分页条件，不再 `LIMIT -1`，档案巡检的列举离开主执行绪，没有图片档时不要周期醒来，OCR 快取语言清单

采集、去重、档案生命周期与 OCR 测试是这一阶段的闸门，人工再看一次快速连续复制是否仍归到正确的来源 App

### 阶段 4：记忆体模型与索引写入

引入列表投影，居民比对只带尚未写入拼音的 id，全文插入后，FTS 与拼音在背景交易提交，列表先显示投影，加上图片像素或位元组上限，超过则拒绝或缩小后再存，并在测试写明选择哪一种

这是唯一会改变搜寻延迟与超大图片行为的阶段，用 `tests/SearchSemanticsTests.swift`、`tests/ClipboardStoreIntegrationTests.swift`、`tests/ImageInfrastructureTests.swift` 锁定，另准备一笔接近 8 MiB 的文字与一张超大图，确认主执行绪不再同步做 trigram 与全图解码

### 阶段 5：依赖方向

`ClipboardTextClassifier` 不再呼叫渲染器，设定页、贴图、档案对话框改为接收依赖，`AppCore.shared` 的既有呼叫可以留到下一个触碰该档案时再换，不要全库机械替换

### 阶段 6：测试进 CI

在 macOS runner 上跑现有脚本，若 runner 没有专案要求的 Xcode 27，先把工作流程写成可手动触发，并在文件注明机器需求，不要为了 CI 重写一套 XCTest，除非脚本编译成本已经高到无法接受，抽 Swift package 放在 CI 稳定之后

## 不做的事

- 不把 SQLite 换成 SwiftData 或另一个封装，现有 C API 与测试已经贴着真实结构
- 不把 FTS trigram 换成空白分词，中文与无空白片段需要它，要减的是主执行绪写入与索引范围，不是演算法品牌
- 不重写 `PopoverMenu`、贴图视窗与解码协调器，它们大，但边界清楚
- 不在裁剪中删除拼音、OCR 或档案书签，那是功能，不是重复实作
- 不开启沙盒，不改部署目标，不放宽严格并行
