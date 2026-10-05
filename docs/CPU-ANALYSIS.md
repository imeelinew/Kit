# Kit CPU 场景分析与 C++／Rust 重写评估

本文回答两个问题：**Kit 在哪些场景吃 RAM 和 CPU**，以及**把高消耗逻辑换成 C++／Rust 是否有明显体验提升**。

所有数字来自本机实测：M5 / 10 核 / 16 GB / macOS 27.0.1。Swift 侧用 `-O` 编译仓库里的真实源文件（与发布构建同级优化），Rust／C++ 侧读同一份语料。基准代码在 `tools/cpu-bench/`（该目录在 `.gitignore` 内）。

本文是 [RAM-ANALYSIS.md](RAM-ANALYSIS.md) 的补充：那份文档针对 v0.3.1 的 RAM 做逐行分析，本文针对当前 v0.4.0 的 CPU／RAM **场景**与**重写收益**。

## 一、结论先行

**1. 空闲状态几乎不耗 CPU。** 运行 22 分钟的应用，实测 120 秒内只消耗 0.08 秒 CPU（0.067%）。10 Hz 的剪贴板轮询（`ClipboardManager.swift:9`）在这台机器上可忽略。

**2. RAM 与 CPU 的大头都不在剪贴板数据上，而在 GUI 框架里。** 数据库 363 行、文本合计约 60 KB、图片 104 张共 33 MB，但进程 `phys_footprint` 是 185 MB；**一个空数据库的冷启动就已经占用 90 MB RSS**。这部分是 AppKit／SwiftUI／TextKit 的框架成本。C++／Rust 无法触及它——除非放弃 AppKit 重写整个界面层。

**3. 真正能被原生代码加速的只有「纯字节处理」的几处，而且收益来自换算法／换引擎，不是换语言。**

| 512 KB 代码、7 条高亮规则、仅扫描 | 耗时 |
| --- | --- |
| Swift / ICU（`NSRegularExpression`） | **122.5 ms** |
| Rust / `fancy-regex`（回溯引擎，忠实移植） | **158.2 ms**（比 Swift 还慢） |
| Rust / `regex` crate（DFA 引擎） | **6.4 ms**（快 19 倍） |

同一批正则，Rust 用回溯引擎比 Swift 慢 29%，换成 DFA 引擎快 19 倍。**语言不是变量，引擎和算法才是。** C++ 侧的 `std::regex` 也验证了这一点：12 KB 文本跑其中 3 条规则要 6.6 ms，和 Swift 的 7 条规则（10.8 ms）同档。

**4. 有些路径换成原生代码会变慢，不要动：**

| 路径 | Swift／系统框架 | Rust |
| --- | --- | --- |
| SHA-256 指纹 5 MB | **3.1 ms**（CryptoKit，硬件 SHA 指令） | 17.3 ms（`sha2` crate） |
| 4000×2500 PNG → 1600 px 解码 | **95 ms／张**（ImageIO） | 170 ms／张（`image` crate） |

**5. 逐项判定：**

| 路径 | 值得用 C++／Rust 重写吗 | 理由 |
| --- | --- | --- |
| 代码高亮扫描 | **值得，但要先换引擎／算法** | 122.5 ms → 6.4 ms；只换语言无收益 |
| 常驻窗口搜索匹配 | **值得，但要先改数据结构** | 每键 22.9 ms → 0.5 ms；成因是区域敏感比较与 NSCache 桥接，不是 Swift 本身慢 |
| 拼音转写 | 收益低 | 热路径已按文本缓存；冷路径只在首次索引 |
| 文本分类 | 不值得 | 每次复制一次，后台线程，6–11 ms |
| Markdown 解析 | 不值得 | 每次选中一次且已缓存，4.8 ms |
| SHA-256 指纹 | **不要** | CryptoKit 快 6 倍 |
| 图片解码／缩放 | **不要** | ImageIO 快 1.8 倍 |
| OCR | **不要** | Vision 走 ANE，已是原生 |
| TextKit 文本布局 | **无法重写** | 1 MB 预览布局 494 ms，是真正的卡顿源，但那是文本引擎本身；应在长度和视口上裁剪 |
| AppKit／SwiftUI 视图树 | **无法重写** | 空载 90 MB 基线来自框架对象 |
| SQLite FTS 索引与查询 | 已是 C | — |

**一句话：把 Kit 的热点逻辑换成 Rust，最好情况能让「选中有大段代码的条目」和「在搜索框里打字」快一个数量级；但同样的收益基本可以用 Swift 改算法拿到，而 RAM 主要占用方（视图树、TextKit 布局、图片缓存）一行 Rust 也省不掉。**

## 二、测试方法与环境

**机器**：MacBook Air M5（10 核）/ 16 GB / macOS 27.0.1（26A434）。

**Swift 侧**：`tools/cpu-bench/run_swift.sh` 用 `xcrun swiftc -O` 把仓库里的真实源文件（`Pinyin.swift`、`ClipboardTextClassifier.swift`、`CodeSyntaxHighlighter.swift`、`SearchHighlight.swift`、`MarkdownAttributedRenderer.swift`、`AttributedTextPreview.swift`、`ImageThumbnail.swift`、`ClipboardItem.swift` 等，均未修改）与探针一起编译成一个可执行文件。

之所以不用应用的 `Kit.debug.dylib`：Xcode 只在 `-Onone` 下生成 debug dylib，用它会测到未优化的 Swift，对 Rust 不公平。少数只被引用、不会被执行的壳层类型（`AppLocalization`）在 `shims.swift` 里等价替换。

**Rust 侧**：`tools/cpu-bench/rust-bench/`，`opt-level = 3`、`lto = true`。每个场景跑两遍——`fancy`（`fancy-regex`，忠实移植原模式，含反向引用和环视）与 `dfa`（`regex` crate，把 `(?=...)`、`\1`、`(?<!...)` 改写成等价构造）。

**C++ 侧**：`tools/cpu-bench/cpp-bench/bench.cpp`，`c++ -O3 -std=c++20`。

**语料**：由 Swift 探针导出（`KIT_CPU_PROBE_DUMP=corpus`），三侧读同一批文件，逐字节一致。

**计时**：先预热一轮不计时，再跑若干轮取中位数，同时记录 `getrusage` 的进程 CPU 时间。

**方法学限制（请连同数字一起读）**：

- Rust／C++ 的「代码高亮」只产出 token 列表，**不含**把颜色写进 `AttributedString`／`NSAttributedString` 的那一步——那一步是 AppKit 绑定的。因此 6.4 ms 是「扫描部分」的下界收益，不是端到端。
- 文本分类场景里，Swift 用 `JSONSerialization` 判 JSON，Rust 用一个结构等价的括号配对检查代替（`JSONSerialization` 无法在 Rust 侧复现）。
- 图片场景的 PNG 由 `NSBitmapImageRep` 生成，两侧解码同一份文件，但 Rust 侧用 Lanczos3 重采样、ImageIO 用系统缩略图路径，两者算法不必相同。

## 三、RAM 在哪些场景被吃掉

实测（运行 22 分钟、363 条目、104 张图的真实进程）：

| 场景 | 实测 | 来源 |
| --- | --- | --- |
| 冷启动后常驻（**空数据库**） | RSS 90 MB | 面板预热：`AppCore.swift:58` → `PaletteWindowController.prewarm()` 在启动时构建整棵 `RootPaletteView`＋`NSTableView` |
| 冷启动后常驻（真实历史） | footprint 185 MB / RSS 238 MB | 常驻 1000 行窗口（含全文与 OCR 文本）、五层缓存、TextKit 布局数据 |
| 浏览大图 | 解码突发峰值可达 76 MB | 预览缓存 48 MB ＋ 同时最多 2 个解码（`ImageThumbnail.swift:210`） |
| 选中长文本预览 | 每 1 MB 正文约 +47 MB | TextKit 全量布局：`AttributedTextPreview.swift:238` 的 `ensureLayout` 配 `.greatestFiniteMagnitude` 容器高度，整篇 glyph 与 line fragment 全量生成 |
| 长文本条目的瞬时占用 | 一条 8 MB 粘贴内容同时存在原文、`NSMutableAttributedString`、`NSTextStorage`、glyph/fragment、`PreviewContentID` 里的又一份引用 | `AttributedTextPreview.swift:5`、`ClipboardPreview.swift:171` |

RAM 的分布与优化方向已在 [RAM-ANALYSIS.md](RAM-ANALYSIS.md) 与 [RAM-TODO.md](RAM-TODO.md) 中详细展开（前两项已完成并验证）。本文只强调一点：**这四类占用全部是框架对象，没有一类能靠 C++／Rust 消除。**

## 四、CPU 在哪些场景被吃掉

### 4.1 常驻空闲：可忽略

`ClipboardManager.swift:9,31-35` 用 10 Hz（每 0.1 秒）的 `Timer` 挂在主 runloop 的 `.common` 模式上轮询 `NSPasteboard.general.changeCount`，无 tolerance。

**实测**：真实进程 120 秒消耗 0.08 秒 CPU，即 **0.067%**。隔离启动的 Release 构建在 t=1s 时 CPU 时间 0.25 秒，到 t=30s 才 0.27 秒。

结论：轮询值得改成 `NSPasteboard` 通知或降低频率，但**它不是问题**，优先级最低。

### 4.2 每次复制：热点在后台，主线程有少量同步写

| 步骤 | 位置 | 线程 | 成本 |
| --- | --- | --- | --- |
| 快照读取 | `ClipboardManager.swift:75` | detached utility | 低 |
| 规范化＋PNG 重编码 | `ClipboardCapturePipeline.swift:79` | actor | 中（一次 zlib 编码） |
| **文本分类** | `ClipboardManager.swift:121` | detached | **0.3–11 ms**（实测，见第五节） |
| SHA-256 指纹 | `ClipboardStore.swift:217` | detached | 低 |
| 去重等值比较、`INSERT`＋FTS 三元组索引、`items.insert`、裁剪 | `ClipboardStore.swift:816-825` | **主 actor** | 单条，主要是 FTS 写入 |
| 拼音元数据回填 | `ClipboardStore.swift:749` | detached＋新连接 | 单条 |

每次复制的固定成本不高（毫秒级），但有两处结构性问题：

- **FTS 三元组索引在插入 / OCR 更新时于主线程写入**（`ClipboardStore.swift:67-70, 700-733`），大段文本时为一次可感知的主线程停顿。
- **每次复制都会触发一次完整搜索**：`PaletteViewModel.swift:228-234` 的 `revisionObserver` 无条件调用 `refreshResults`，**即使面板是隐藏的**。也就是「复制一次 = 打开一次新 SQLite 连接 + 一次分页查询 + 一次常驻窗口过滤」。

### 4.3 每次按键：当前最大的可控 CPU 开销

搜索框无防抖（全项目 grep `debounce` 无结果），每次按键都重跑一次查询。链路：`RootPaletteView.swift:359` → `PaletteViewModel.swift:147` → `refreshResults()`（`:801`）。每次按键会

1. **在 detached 任务里对常驻窗口逐条做文本匹配**（`ClipboardStore.swift:598-607`）。注意：主 actor 上只有 `:581-584` 那段廉价的 kind/stack 过滤，昂贵的 `item.matches(trimmed)` 在后台——这一点与「主线程扫描」的直觉相反。
2. 新开一个只读 SQLite 连接并查询（`ClipboardSearch.swift:28`）。
3. 渲染层对每个可见行重算高亮（`SearchHighlight.nsAttributed`），并对选中条目的**全文**重算高亮（`ClipboardPreview.swift:217`）。
4. **结果要等第 1 步完成才能返回**（`ClipboardStore.swift:608`），所以第 1 步在「按键到出结果」的关键路径上。

**实测**：1000 条、平均 242 字符的常驻语料，一次过滤

| 子步骤 | 耗时 |
| --- | --- |
| `items.filter { $0.matches("kaili") }` 合计 | **22.9 ms** |
| 其中 `localizedCaseInsensitiveContains`（区域敏感的字面量预检） | 7.7 ms |
| 其中 `Pinyin.matches`（NSCache 查找 + 拼音子串） | 15.2 ms |
| 汉字查询（不走拼音分支） | 7.0 ms |
| 构造 `Data(text.utf8)` 缓存键本身 | 0.13 ms |

也就是说：**每输入一个字母，后台要烧掉约 23 ms，而这 23 ms 挡在结果显示前面。** 成因不是「字符串扫描慢」，而是

- `ClipboardItem.swift:125-130` 用 `localizedCaseInsensitiveContains` 做预检：区域敏感比较比 ASCII 快速路径慢 1–2 个数量级；
- `Pinyin.swift:75-78` 每次查找都重建 `Data(text.utf8)` 当 NSCache 键，走 Objective-C 桥接、加锁、哈希与比较。1000 次查找的固定开销就是 15 ms。

对照：等价的 Rust 实现（`HashMap<&str, _>` 查找 + 字节子串）**0.269 ms**，大小写不敏感扫描 128 KB 只要 0.105 ms。**这一项约有 40–50 倍的空间**，且与语言关系不大——Swift 里换成 ASCII 快速路径＋按条目 id 缓存索引也能拿到大部分。

### 4.4 选中条目：TextKit 全量布局是真正的卡顿源

`AttributedTextPreview.swift:232-245` 的 `updateDocumentGeometry()` 把 `containerSize` 高度设为 `.greatestFiniteMagnitude`，然后 `ensureLayout(for:)` 全文布局，`PreviewTextView.intrinsicContentSize`（`:270`）再取 `usedRect`。全部在主线程。

**实测**（纯 ASCII 正文，`PreviewTextScrollView` 端到端）：

| 正文字节 | 布局耗时 | 附加 footprint |
| --- | --- | --- |
| 64 KB | 37 ms | +2.1 MB |
| 256 KB | 143 ms | +8.1 MB |
| 1 MB | **494 ms** | +46 MB |

这条路径**不可能用 Rust 重写**——它就是文本引擎。可行的做法是限制预览长度、按视口布局、或对超长条目退回廉价渲染。

紧随其后的是高亮：`CodeSyntaxHighlighter.highlight` 端到端实测 32 KB／128 KB／512 KB = 8.6／33.4／131.6 ms（AppKit 属性），SwiftUI `AttributedString` 版则是 19.8／83.3／**345.1 ms**——`CodePreview`（`CodeSyntaxHighlighter.swift:171`）走的正是后者。它跑在 detached 任务上，所以不直接卡主线程，但会实打实吃掉一个核几百毫秒（笔记本上有续航与风扇代价）。

### 4.5 浏览图片：解码贵在「全量解码」，与目标尺寸无关

`ImageThumbnail.loadAsync` 用 `CGImageSourceCreateThumbnailAtIndex` 降采样，并发上限 2（`ImageThumbnail.swift:210`）。

**实测**（4000×2500 PNG，每张 CPU 时间）：请求 1600 px = **95 ms**；请求 256 px 也要 **65–99 ms**。原因是 PNG 无损，ImageIO 必须完整解码，缩略图尺寸只省内存不省时间（JPEG 才有 DCT 缩放）。

对照 Rust `image` crate 解码 + Lanczos3 缩放：**170 ms／张**，比 ImageIO 慢 1.8 倍。**这一项重写成原生代码是负收益。**

### 4.6 启动与 OCR 回填

启动路径全部在主线程同步执行（`AppCore.swift:38-68`）：注册字体 → 打开数据库并跑 schema 迁移（`ClipboardStore.swift:970-1045`，其中 `migrateImageSearch` 含一次全表 `UPDATE`）→ 加载 1000 行常驻窗口 → `prune()` → 面板预热＋整棵 SwiftUI 视图树求值。

**实测**（隔离 bundle、Release 构建、**空历史**）：t=1s 时 CPU 时间 0.25 秒、RSS 90 MB，之后 30 秒内 CPU 只涨 0.02 秒。所以空库启动约 **0.25 秒 CPU / 90 MB RAM**；真实历史会在此基础上叠加常驻窗口装载、`prune` 与图片回填。

OCR 回填（`ClipboardStore.swift:647-698`）在有待处理图片时才启动，逐张 25 ms 间隔，`recognize` 走 Vision／ANE。它是**一次性**的：本次采样的真实库里 104 张图已全部 `complete`/`empty`，没有待办，因此本次运行没有回填开销。但它的循环体在 `@MainActor` 上（类标注），`nextImageOCRItem()` 与 `saveImageOCR` 的 UPDATE＋FTS 触发器都在主线程。

## 五、Swift / Rust / C++ 对照实测

单位：毫秒。"—" 表示该侧不适用或未测。

| 场景 | 规模 | Swift | Rust（DFA） | Rust（回溯） | C++ |
| --- | --- | --- | --- | --- | --- |
| 代码高亮**仅扫描** | 512 KB | **122.5** | **6.4** | **158.2** | — |
| 代码高亮仅扫描 | 128 KB | 29.1 | 1.6 | — | — |
| 代码高亮仅扫描 | 32 KB | 7.2 | 0.41 | — | — |
| 代码高亮端到端（AppKit 属性） | 512 KB | 131.6 | — | — | — |
| 代码高亮端到端（SwiftUI 属性） | 512 KB | 345.1 | — | — | — |
| 文本分类 | 12 KB markdown | 10.8 | 0.10 | 1.8 | 6.6（仅 3/7 条规则） |
| 文本分类 | 12 KB 散文 | 6.9 | 0.19 | 1.3 | — |
| 文本分类 | 12 KB 代码 | 0.33 | 0.073 | 1.36 | — |
| **常驻窗口过滤** | 1000×242 字符，拼音查询 | **22.9** | **0.27＋约 0.2**（拼音查找＋扫描） | — | — |
| 大小写不敏感子串扫描 | 128 KB | 13.0 | 0.105 | — | 0.082 |
| 拼音索引构建（冷） | 1000×40 汉字 | 21.4 | 1.86 | — | — |
| 拼音索引构建（热，命中缓存） | 1000×40 汉字 | 0.41 | — | — | — |
| 拼音匹配（热，含查找） | 1000 条 | 15.2 | 0.269 | — | — |
| Markdown 解析（仅解析，不建属性） | 32 KB | 4.84 | 0.46 | — | — |
| Markdown 渲染（解析＋属性串） | 32 KB / 128 KB | 15.4 / 62.8 | — | — | — |
| SHA-256 指纹 | 5 MB | **3.1** | **17.3** | — | — |
| 图片解码＋缩放 | 4000×2500 PNG → 1600 px | **95** | **170** | — | — |
| Nerd Font 私用区扫描 | 256 KB | 0.38 | — | — | 0.36 |
| TextKit 全量布局 | 64 KB / 256 KB / 1 MB | 37 / 143 / 494 | 不适用 | 不适用 | 不适用 |

几个值得单独说的读数：

- **`NerdSymbolsFont` 的私用区扫描不是瓶颈**：Swift 0.38 ms vs C++ 0.36 ms。它的提前返回（`NerdSymbolsFont.swift:56`）已经把普通文本挡在字形探测之外，不需要动。
- **SwiftUI `AttributedString` 比 `NSAttributedString` 慢 2.5 倍**（512 KB：345 ms vs 132 ms），这是纯框架开销，跟算法无关，但换掉它能省一大截——比如让 `CodePreview` 也走 AppKit 属性路径。
- **CryptoKit 与 ImageIO 是硬件／系统加速的**：CryptoKit 用 ARMv8 SHA 指令，ImageIO 走 Accelerate 与硬件解码器。用 `sha2`／`image` crate 替换它们是明确倒退。

## 六、重写评估

### 6.1 为什么「换语言」本身不产生收益

三侧实测给出了直接证据：

- 同一批正则，**Rust 回溯引擎 158 ms 比 Swift/ICU 的 122.5 ms 更慢**；C++ `std::regex` 与 Swift 同档。三者都是回溯／朴素实现。
- 换成 **Rust DFA 引擎才降到 6.4 ms**。C++ 要达到同一水平必须用 RE2 或手写扫描器——`std::regex` 不行。
- 反过来，`localizedCaseInsensitiveContains` 与 NSCache 的开销，换成 Rust 的 `HashMap`＋字节扫描就消失了，但**同样的修法在 Swift 里也成立**（ASCII 快速路径、按 id 索引、避开 ObjC 桥接）。

所以正确的问题不是「哪里该用 Rust」，而是「哪里的算法／数据结构选错了」。语言只是决定了你**能不能**换成 DFA 引擎、能不能避开桥接。

### 6.2 各项判定

**值得（但先改算法，再谈语言）**

1. **代码高亮扫描**——把 7 遍 `NSRegularExpression` 换成一遍手写词法扫描，或至少把 DFA 化的规则合并。预期 512 KB 从 122 ms 降到个位数毫秒，32 KB（常见规模）从 8.6 ms 降到 1 ms 以内。这一步在 Swift 里做同样有效；只有在手写词法器仍不够快时，才值得把这一个函数挪到 Rust。
2. **常驻窗口匹配**——目标是把每键 23 ms 降到 1 ms 以内。按收益排序：先给 ASCII 查询加快速路径、把拼音索引按条目 id 缓存（而不是每次重建 `Data(text.utf8)` 走 NSCache），再考虑 Rust。这一项是本文里**唯一直接决定打字手感**的 CPU 开销。

**不值得**

3. **文本分类**：每次复制一次、在后台、6–11 ms。重写收益相对日常负载很小。
4. **Markdown 解析**：每次选中一次且已缓存，4.8 ms。
5. **拼音转写**：热路径已有按文本缓存（1000 条只剩 0.41 ms）；冷路径 21 ms 只在首次索引，用户看不到。
6. **SHA-256／图片解码／OCR**：重写会变慢，见第五节。

**无法重写**

7. **TextKit 布局**（1 MB 预览 494 ms）与 **AppKit／SwiftUI 视图树**（空载 90 MB）。这两项是 RAM 与卡顿的主要来源，但它们就是框架本身。要动只能在**用量**上动：限制预览长度、按视口布局、把 `RootPaletteView` 推迟到首次呼出时再建、给缓存加真实字节预算、响应内存压力通知。

### 6.3 如果确实要引入原生代码

- 选 **Rust** 而不是 C++。仓库已有 Swift 6 并发模型与严格类型，Rust 的 `Sendable`／所有权语义更容易对接，cargo 交叉编译与静态链接也比 CMake 干净。
- 只搬**纯字节处理**的循环：分词、扫描、UTF-8／UTF-16 位置映射。这些都是无状态、可单独测试的函数。
- 不要搬：加密（CryptoKit 有硬件指令）、图像解码（ImageIO 有硬件解码器）、OCR（Vision 走 ANE）、SQLite（已是 C）、文本布局（TextKit）。
- 跨语言调用的固定开销约在微秒级；只有当单次调用的工作量明显大于这个量级（例如整篇文本扫描）时才划算。像 `NerdSymbolsFont` 那种 0.38 ms 的调用不值得跨边界。

## 七、比「换语言」更值得做的事

按「收益／风险比」排序。

| # | 改动 | 预期收益 | 风险 |
| --- | --- | --- | --- |
| 1 | 常驻匹配：ASCII 查询走字节快速路径，拼音索引按条目 id 缓存 | 每键 23 ms → 数毫秒，直接改善打字手感 | 低 |
| 2 | 代码高亮：合并 7 遍正则或改手写词法器；`CodePreview` 改走 AppKit 属性路径 | 512 KB 从 345 ms 降到十毫秒内 | 中，需 UI 回归 |
| 3 | 搜索加防抖并跳过重复查询 | 减少连打时的重复查询与重复匹配 | 低 |
| 4 | `revisionObserver` 加可见性判断，面板隐藏时不重跑搜索 | 每次复制省一次连接＋查询＋过滤 | 低 |
| 5 | 预览按长度与视口裁剪，超长文本退回廉价渲染 | 消除 1 MB 预览 494 ms 的主线程停顿 | 中，影响预览体验 |
| 6 | OCR 的 SQL 与 FTS 写入移出主 actor | 消除回填期间的主线程停顿 | 中 |
| 7 | 沿用 [RAM-TODO.md](RAM-TODO.md) 的第 3–5 项（悬浮图按实际尺寸解码、字节预算、AI 分类并发） | 降低图片场景峰值 | 低 |

只有在做完 1–2 之后仍然不够快，才需要考虑把那两个函数改成 Rust——那时你已经有了现成的基准和回归基线。

## 八、复现

```sh
cd tools/cpu-bench

# Swift 侧：-O 编译真实源文件并跑全部场景
./run_swift.sh
KIT_CPU_PROBE_ONLY=resident ./run_swift.sh     # 只跑常驻窗口过滤
KIT_CPU_PROBE_DUMP=corpus ./run_swift.sh       # 只导出共享语料

# 仅扫描的 ICU 对照
xcrun swiftc -O -swift-version 6 -parse-as-library RegexScan.swift -o out/regex-scan
./out/regex-scan corpus

# Rust 侧
cd rust-bench && cargo build --release
./target/release/kit-cpu-bench ../corpus
./target/release/kit-cpu-bench ../corpus syntax    # 只跑某个场景

# C++ 侧
cd ../cpp-bench && c++ -O3 -std=c++20 bench.cpp -o bench && ./bench ../corpus

# 真实进程的空闲 CPU（120 秒采样）
PID=$(pgrep -f "/Applications/Kit.app/Contents/MacOS/Kit" | head -1)
a=$(ps -p $PID -o time=); sleep 120; b=$(ps -p $PID -o time=)
echo "$a -> $b"
```

原始输出保存在 `tools/cpu-bench/results-{swift,rust,cpp,resident,regexscan}.txt`。
