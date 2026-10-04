# 图片 OCR 对比测试：Apple Vision vs PaddleOCR

测试时间 2026-10-04，测试代码在 `tools/ocr-bench/`（未纳入 git），原始数据在该目录的 `results/`。

## 结论

**继续用 Apple Vision，不要换 PaddleOCR。**

| | Apple Vision（Kit 当前配置） | PaddleOCR PP-OCRv6 medium（默认） | PaddleOCR PP-OCRv5 mobile（轻量） |
|---|---|---|---|
| 单张耗时（中位） | **109 ms** | 2662 ms（**26 倍**） | 1215 ms（11 倍） |
| 单张耗时（P95） | **157 ms** | 5703 ms | 2127 ms |
| 20 张截图总耗时 | **2.2 s** | 53 s | 24 s |
| 峰值内存 | **164 MB** | 4269 MB | 1637 MB |
| 冷启动 | **0.2 s** | 6.0 s | 12.9 s |
| 内容 CER（越低越好，全部图片） | 0.034 | **0.018** | 0.029 |
| 中文 CER | 0.001 | **0.000** | 0.011 |
| 英文 CER | 0.037 | **0.008** | 0.021 |
| 中英混排 CER | 0.068 | 0.067 | 0.073 |
| 关键词命中率（搜索场景） | 99.1% | **99.9%** | 97.7% |
| 整图完全正确率 | 48.5% | **68.4%** | 49.3% |
| 部署体积 | 0（系统框架） | venv 1.1 GB + 模型 132 MB | venv 1.1 GB + 模型 21 MB |

准确率上 PaddleOCR 确实更好，主要赢在**英文**（CER 0.037 → 0.008）和整图一次读对的比例；**中文两者基本持平**（0.001 vs 0.000），中英混排也持平。但代价是慢 11–26 倍、内存多 10–26 倍，而且要在 App 里塞一个 Python + PaddlePaddle 运行时。对 Kit 这种「OCR 只用来做图片搜索索引、后台跑」的场景，这点准确率差距换不来 26 倍的 CPU/电量开销。

如果哪天英文识别精度真的成为瓶颈，正确路径也不是嵌 Python，而是把同族 PP-OCR 模型导成 ONNX 用 onnxruntime 在 Swift 里跑（RapidOCR 就是这条路，模型只有 33 MB）——见文末「后续可选项」，本轮未跑完。

## 测试方法

**环境**：MacBook Air M5（10 核）/ 16 GB / macOS 27.0.1。PaddleOCR 侧 `paddlepaddle 3.3.1 + paddleocr 3.7.0`（Python 3.12 独立 venv，CPU 推理，macOS arm64 无 Metal/MPS 后端、无 mkldnn）；Apple 侧直接用仓库里的 `Kit/Core/ClipboardImageOCR.swift` 编译成命令行程序，配置与 App 完全一致：`.accurate` + `zh-Hans/zh-Hant/en-US` + `usesLanguageCorrection = true` + App 的文本归一化。

**语料**：`tools/ocr-bench/gen_corpus.py` 生成 136 张图（17 个文档 × 8 种画质）。17 个文档里中文 5、英文 4、中英混排 8；来源一半是 Pillow 渲染的文档（新闻/笔记/技术文/聊天/代码/发票/表格），一半是无头 Chrome 截的真实 HTML 页面（文章页、深色代码文档、仪表盘、设置列表、聊天）。8 种画质：clean(2x)、small(缩到 1x)、jpeg40、blur、noise、rotate2°、lowcontrast、perspective(梯形透视)。Ground truth 全部是人工写的文本，不是任何引擎的输出。

**计时**：加载模型后先跑一轮预热（不计时），再跑 3 轮计时（Paddle v5 mobile/v6 medium），每张图取 3 轮中位数。冷启动单独用全新进程测。所有引擎串行跑，不互相抢 CPU。

**指标说明**：`CER (raw order)` 是最朴素的整段字错率，会把「阅读顺序不同」和「一行被切成两行」都算成错。`CER (content)` 允许把一条 GT 行匹配到相邻最多 3 行输出（表格按单元格切分、标签与数值分行的情况），更接近「字是否认对了」。Kit 的图片搜索最关心的是 **关键词命中率**：从 GT 里抽出关键词，看识别文本里在不在。

## 速度

| 引擎 | 中位 | 平均 | P95 | 最小 | 最大 | 中位 ms/百万像素 | 相对倍数 |
|---|---|---|---|---|---|---|---|
| Apple Vision | 109.2 ms | 110.8 ms | 156.7 ms | 49.4 ms | 185.5 ms | 315 | 1.0x |
| PaddleOCR v6 medium | 2661.9 ms | 3160.2 ms | 5703.3 ms | 1193.5 ms | 7624.4 ms | 7378 | 26.2x |
| PaddleOCR v5 mobile | 1215.2 ms | 1310.4 ms | 2127.4 ms | 671.6 ms | 3544.7 ms | 3299 | 11.0x |

按图片来源看，PaddleOCR 对网页截图尤其慢（v6 medium：网页 4516 ms vs 渲染文档 2261 ms），因为截图更大、文本行更多；Vision 是 130 ms vs 95 ms。最慢的单张图是 7600 ms（Vision 同图 121 ms）。

PaddleOCR 的耗时随文本行数增长（检测后逐行做识别），而 Vision 是整图一次推理，所以「一屏代码/一屏聊天记录」这类多行截图差距会进一步拉大。

两个引擎都是 CPU 时间换出来的：实测 PaddleOCR 进程平均只跑到约 1 个核（默认 10 线程配置下，`PADDLE_PDX_CPU_NUM_THREADS` 调成 10/6/4 分别是 2164/2616/2884 ms，默认已是最优）。Vision 走的是 ANE（神经引擎），基本不吃 CPU，对笔记本续航友好。

> 说明：测 PaddleOCR 时机器上有约 2 个核被其它进程占用（Chrome/ChatGPT 等），PaddleOCR 是纯 CPU 推理，所以它的数字偏保守；Vision 在 ANE 上受影响很小。另外 PaddleOCR 连续满载跑了 30 分钟，可能已降频。这两个因素只会让 PaddleOCR 显得更慢，不影响结论方向。

## 准确率

| 引擎 | CER（raw order） | CER（content） | 整行全对率 | 关键词命中率 | 英文 WER | 整图全对率 |
|---|---|---|---|---|---|---|
| Apple Vision | 0.079 | 0.034 | 81.3% | 99.1% | 0.195 | 48.5% |
| PaddleOCR v6 medium | 0.033 | 0.018 | 89.1% | 99.9% | 0.076 | 68.4% |
| PaddleOCR v5 mobile | 0.042 | 0.029 | 79.9% | 97.7% | 0.142 | 49.3% |

分语种：

| 引擎 | 语种 | n | CER（raw） | CER（content） | 关键词命中率 |
|---|---|---|---|---|---|
| Vision | 中文 | 48 | 0.008 | 0.001 | 99.5% |
| Vision | 英文 | 48 | 0.073 | 0.037 | 98.2% |
| Vision | 混排 | 40 | 0.182 | 0.068 | 99.7% |
| PaddleOCR v6 | 中文 | 48 | 0.008 | 0.000 | 100% |
| PaddleOCR v6 | 英文 | 48 | 0.019 | 0.008 | 99.9% |
| PaddleOCR v6 | 混排 | 40 | 0.098 | 0.067 | 99.7% |
| PaddleOCR v5 mobile | 中文 | 48 | 0.019 | 0.011 | 96.5% |
| PaddleOCR v5 mobile | 英文 | 48 | 0.028 | 0.021 | 98.7% |
| PaddleOCR v5 mobile | 混排 | 40 | 0.104 | 0.073 | 97.8% |

分文档看差距集中在少数文档上（按 content CER，Vision / Paddle v6）：

| 文档 | 内容 | Vision | Paddle v6 |
|---|---|---|---|
| mix_table | 三列对齐表格 | 0.545 | 0.600 |
| web_mix_dashboard | 卡片式仪表盘 | 0.365 | 0.363 |
| web_en_small | 12.5px 小字设置列表 | 0.263 | 0.259 |
| en_code | Python 代码块 | 0.022 | 0.004 |
| web_en_docs | 深色文档页+代码 | 0.020 | 0.000 |
| 其余 12 个文档 | 新闻/笔记/聊天/发票等 | ≤0.014 | ≤0.023 |

也就是说：**普通中文、中英混排、发票、列表、聊天，两者都近乎完美**；差异主要出现在「表格/卡片这类会被切成单元格的排版」和「12.5px 小字」上。

降质条件下两者都稳：blur / jpeg40 / noise / lowcontrast / rotate2° 对两家影响都不大；perspective（透视）Vision 反而略好（0.026 vs 0.029）。

## 失败特征

* **Vision 在极小字号上会崩**：`web_en_small__small`（12.5px）Vision 输出 `...Exey pIoMssEdL sKep os anlg walsAs wels/s` 这类乱码；同图 2x 版本就读得很好。这是 Vision 唯一一次「成片乱码」的失败。
* **Vision 会漏掉/错位两栏布局的右栏**：设置列表这种「左标签 …… 右取值」，Vision 常常先读完左列再读右列，值都读到了但顺序变了（所以关键词命中率仍有 98%+，但 raw CER 被抬高）。这不是识别错误。
* **PaddleOCR 会把一整行合并成一条**：表格/设置列表它倾向把同一视觉行的多列合成一个文本框，行边界与人类直觉不同；对「按行做后续处理」的下游不友好（但字都认对了）。
* **PaddleOCR 的检测器默认把长边缩到 736px**：1.3 MP 的网页截图相当于在半分辨率上做检测框定位，小字行容易漏；这是它可调参数之一，未在本轮主测试中调整。
* **中文两者都几乎无错**：136 张里中文文档 Vision content CER 0.001、Paddle 0.000。

## 部署成本

| | Apple Vision | PaddleOCR |
|---|---|---|
| 依赖 | 系统 Vision.framework（0 字节） | Python 3.12 解释器 + paddlepaddle + paddleocr，venv 1.1 GB；模型 21 MB（v5 mobile）～132 MB（v6 medium） |
| 集成方式 | Swift 原生 API，`VNRecognizeTextRequest` | 需要 Python 运行时；macOS arm64 无 GPU/Metal 后端，纯 CPU |
| 内存 | 164 MB 峰值 | 1.6–4.3 GB 峰值 |
| 功耗 | ANE，几乎不占 CPU | 10 线程 CPU 满载（实测约 1 核持续占用） |
| 首次使用 | 系统按需下载语言资产（本机首次 13.4 s，之后 0.2 s） | 首次需下载模型；之后 init 0.4–20 s |

对一个常驻的剪贴板管理器来说，4.3 GB 峰值内存和 26 倍 CPU 开销基本是不可接受的；Kit 的 `docs/RAM-ANALYSIS.md` 里连 6 MB 的 Vision 常驻对象都在优化，量级差太远。

## 顺带发现

* Vision 的 `.fast` 档位在 macOS 27 上**不支持中文**：`supportedRecognitionLanguages()` 不含 `zh-Hans`，Kit 用 `.accurate` 是必须的，不是保守选择。（`.fast` + `en-US` 单张约 25 ms，比 `.accurate` 快 4 倍，但只能用于纯英文场景。）

## 后续可选项（未完成）

已经装好 `rapidocr 3.9.2 + onnxruntime 1.30`（就是同一族 PP-OCRv6 模型，转成 ONNX，共 33 MB），4 张图的探针结果：

* onnxruntime CPU：612–960 ms/张（比 Paddle 原生运行时快 2–3 倍，仍是 Vision 的 8 倍）
* onnxruntime CoreML EP：927–1473 ms/张，反而更慢，且首次编译模型 14.8 s、内存 2.65 GB

真正的部署形态是不带 Python 的 ONNX Runtime（C/C++ API），模型 33 MB。要验证「值不值得为了英文精度换这条路」，需要把语料全量跑一遍，再配合真实图片集（已下载：中文街景 ReCTS/ESTVQA 80 张、英文扫描件 FUNSD 40 张，在 `tools/ocr-bench/real/`）复测——这些在本次因耗时过长被中止。

## 复现

```sh
cd tools/ocr-bench
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "paddlepaddle==3.3.1" paddleocr pillow numpy
.venv/bin/python gen_corpus.py
xcrun swiftc -O -swift-version 6 -parse-as-library \
    ../../Kit/Core/ClipboardImageOCR.swift apple_ocr.swift -o apple_ocr
./run_all.sh                     # 约 50 分钟（PaddleOCR CPU 推理慢）
.venv/bin/python evaluate.py \
    --runs "Apple Vision（Kit 当前配置）=results/apple_accurate.json" \
           "PaddleOCR PP-OCRv6 medium=results/paddle_v6_medium.json" \
           "PaddleOCR PP-OCRv5 mobile=results/paddle_v5_mobile.json"
```
