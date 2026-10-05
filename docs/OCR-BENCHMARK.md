# 图片 OCR 对比测试：Apple Vision vs PaddleOCR

测试时间 2026-10-04/05，测试代码在 `tools/ocr-bench/`（该目录在 .gitignore 里），原始数据在该目录的 `results/`。

> **修订说明（重要）**：第一版报告只测了 `PaddleOCR()` 的**默认模型 PP-OCRv6 medium（139 MB）**，得出「慢 26 倍、不要换」的结论。实际上 PP-OCRv6 有 tiny / small / medium 三档，最常用的轻量档只有 6.6 MB，速度只比 Vision 慢 1.8 倍，准确率和 medium 几乎一样。下面是以轻量档为主的修订版结论。

## 一、PP-OCRv6 的三档模型

官方只有三档（HuggingFace `PaddlePaddle/PP-OCRv6_*`，无 server/mobile/int8 变体）：

| 档位 | det | rec | 合计 | PaddleOCR 默认选择 |
|---|---|---|---|---|
| tiny | 2.0 MB | 4.6 MB | **6.6 MB** | 否 |
| small | 10.0 MB | 21.4 MB | **31.4 MB** | 否（RapidOCR 默认用它） |
| medium | 62.3 MB | 76.8 MB | **139 MB** | **是**（`PaddleOCR()` 不给参数时） |

我第一轮用的就是 medium —— 不是用错，而是 `PaddleOCR()` 在 `lang='ch'` 下的默认档（源码 `paddleocr/_pipelines/ocr.py: _get_ocr_model_names`）。但对端侧来说，tiny/small 才是相关档位。

## 二、结论

**准确率上 PaddleOCR 明显更好，速度上 Vision 更好；换不换是个权衡，不再是碾压。**

| 方案 | 模型大小 | 单张中位 | 相对 Vision | 峰值内存 | 内容 CER | 中文 CER | 英文 CER | 关键词命中 | 整图全对率 |
|---|---|---|---|---|---|---|---|---|---|
| **Apple Vision**（Kit 当前配置） | 0（系统） | **109 ms** | 1.0x | **164 MB** | 0.034 | **0.001** | 0.037 | 99.1% | 48.5% |
| **PP-OCRv6 tiny**（Paddle 运行时） | 6.6 MB | 200 ms | 1.8x | 1001 MB | **0.018** | 0.003 | **0.007** | **99.9%** | 58.1% |
| PP-OCRv6 small（ONNX Runtime） | 31 MB | 324 ms | 3.0x | 1245 MB | **0.017** | 0.003 | **0.006** | **99.9%** | 68.4% |
| PP-OCRv6 small（Paddle 运行时） | 31 MB | 615 ms | 5.6x | 1535 MB | 0.019 | 0.003 | 0.007 | **99.9%** | 66.9% |
| PP-OCRv6 medium（Paddle 默认） | 139 MB | 2662 ms | 24x | 4269 MB | 0.018 | 0.000 | 0.008 | **99.9%** | 68.4% |

要点：

1. **三档模型的准确率几乎一样**（内容 CER 0.017–0.019），tiny 已经吃掉了 PaddleOCR 的全部准确率优势。选大模型只买到慢。
2. **tiny 只比 Vision 慢 1.8 倍**（200 ms vs 109 ms），不是 24 倍。
3. **同一份模型，ONNX Runtime 比 Paddle 自己的运行时快约 2 倍**（small：324 ms vs 615 ms），冷启动也从 19 s 降到 0.7 s。要走这条路应该用 ONNX Runtime，而不是嵌 paddlepaddle。
4. **内存仍是硬伤**：任何 PaddleOCR 方案峰值都 ≥1 GB（模型只有 6.6 MB，其余是 Paddle 运行时 + 推理 arena），Vision 是 164 MB。对一个常驻剪贴板管理器差别很大。
5. **准确率差异集中在这几处**：
   * 英文长句、代码标识符、数字/型号：PaddleOCR 明显更准（英文 CER 0.007 vs Vision 0.037；`en_code` 0.004 vs 0.022）。
   * 中文：Vision 略好（0.001 vs 0.003），两者都是「几乎不错」的量级。
   * Vision 唯一成片崩的场景：12.5 px 的小字设置列表（会输出乱码），同图 2x 版本正常。
6. **搜索场景（Kit 的真实用途）差距很小**：关键词命中率 99.1% vs 99.9%，两者都能搜到；差的是「整图一次全对」的比例（48.5% vs 58–68%）。

**建议**：

* 维持现状（Vision）依然合理：2 倍速度、6 倍内存优势、零依赖、不占 CPU（走 ANE，对续航友好）。OCR 在 Kit 里只用于搜索索引，99.1% 的关键词命中已经够用。
* 如果「英文/代码截图搜不到」成为真实用户抱怨，再考虑 PP-OCRv6 **tiny + ONNX Runtime**（不要用 medium、不要嵌 paddlepaddle）：代价是每张 +100 ms（后台跑无所谓）、常驻内存 +1 GB、需要把 onnxruntime 静态链接进 App 并打包 31 MB 模型。
* 决策的关键变量是**内存**，不是速度。建议先在 App 里实测 onnxruntime CPU 的常驻内存，如果能把 1 GB 压到 200 MB 以内，这个方案才值得认真考虑。

## 三、测试方法

**环境**：MacBook Air M5（10 核）/ 16 GB / macOS 27.0.1。PaddleOCR 侧 `paddlepaddle 3.3.1 + paddleocr 3.7.0`（Python 3.12 独立 venv，纯 CPU —— macOS arm64 无 Metal/MPS 后端、wheel 里也没有 mkldnn）；ONNX 侧 `rapidocr 3.9.2 + onnxruntime 1.30.0`（同为 PP-OCRv6 small 的 ONNX 版）；Apple 侧直接把仓库里的 `Kit/Core/ClipboardImageOCR.swift` 编译成命令行程序，配置与 App 完全一致：`.accurate` + `zh-Hans/zh-Hant/en-US` + `usesLanguageCorrection = true` + App 的文本归一化。

**语料**：`tools/ocr-bench/gen_corpus.py` 生成 136 张图（17 个文档 × 8 种画质）。文档：中文 5、英文 4、中英混排 8；来源一半是 Pillow 渲染的文档（新闻/笔记/技术文/聊天/代码/发票/表格），一半是无头 Chrome 截的真实 HTML 页面（文章页、深色代码文档、仪表盘、设置列表、聊天）。画质：clean(2x)、small(缩到 1x)、jpeg40、blur、noise、rotate2°、lowcontrast、perspective(梯形透视)。Ground truth 全部人工撰写，不是任何引擎的输出。

**计时**：加载模型后先跑一轮预热（不计时），再跑 2–3 轮计时，每张图取中位数。所有引擎串行执行，不互相抢 CPU。

**同机同条件校准**（8 张子集、同一小时内跑完，用于排除机器状态差异）：

| 引擎 | 中位 | 相对 Vision | 峰值内存 |
|---|---|---|---|
| Apple Vision | 63 ms | 1.0x | 127 MB |
| PP-OCRv6 tiny | 183 ms | 2.9x | 1002 MB |
| PP-OCRv6 small | 560 ms | 8.9x | 1209 MB |
| PP-OCRv6 medium | 1619 ms | 25.6x | 2663 MB |
| PP-OCRv5 mobile | 992 ms | 15.7x | 1124 MB |

校准结果和全量测试一致（medium ≈25x），说明第一轮的 24–26 倍不是机器负载造成的假象。子集与全量的倍数差异来自图片尺寸分布不同（子集是 8 张混合图，全量含更大的网页截图）。

**指标说明**：

* `CER (raw order)`：最朴素的整段字错率，会把「阅读顺序不同」「一行被切成两行」也算成错，用于看下游按行处理的友好度。
* `CER (content)`：允许把一条 GT 行匹配到相邻最多 3 行输出（表格单元格、标签与数值分行），更接近「字有没有认对」。**上表用的是这个。**
* `关键词命中率`：从 GT 抽关键词，看识别文本里在不在 —— Kit 图片搜索的真实指标。

## 四、补充数据

**速度按图片来源**（Paddle 对多行、大尺寸截图更吃亏）：

| 引擎 | 网页截图（1.0–1.4 MP） | 渲染文档 |
|---|---|---|
| Apple Vision | 130 ms | 95 ms |
| PP-OCRv6 tiny | 232 ms | 178 ms |
| PP-OCRv6 medium | 4516 ms | 2261 ms |

**耗时随文本行数增长**：PaddleOCR 是「检测 → 逐行识别」，Vision 是整图一次推理，所以聊天记录/代码这类多行截图差距会拉大。PaddleOCR 进程实测平均只吃到约 1 个核（默认 10 线程配置下，`PADDLE_PDX_CPU_NUM_THREADS` 设成 10/6/4 分别是 2164/2616/2884 ms，默认已最优）。

**分文档看差距**（内容 CER，Vision / PP-OCRv6 tiny）：

| 文档 | 内容 | Vision | tiny |
|---|---|---|---|
| mix_table | 三列对齐表格 | 0.545 | 0.600 |
| web_mix_dashboard | 卡片式仪表盘 | 0.365 | 0.363 |
| web_en_small | 12.5px 小字设置列表 | 0.263 | 0.259 |
| en_code | Python 代码块 | 0.022 | 0.004 |
| en_news / en_list / en_invoice | 新闻/清单/发票 | 0.004 / 0.005 / 0.003 | 0.000 / 0.000 / 0.000 |
| zh_* / mix_*（除上表） | 中文与中英混排 | ≤0.014 | ≤0.023 |

即：普通中文、混排、发票、列表、聊天两者都近乎完美；差异集中在「表格/卡片这类会被切成单元格的排版」和「12.5 px 小字」。

**顺带发现**：Vision 的 `.fast` 档位在 macOS 27 上 `supportedRecognitionLanguages()` 不含 `zh-Hans`，**不支持中文** —— Kit 用 `.accurate` 是必须的，不是保守选择。（`.fast` + `en-US` 单张约 25 ms，比 `.accurate` 快约 4 倍，但只能用于纯英文场景。）

**部署成本**：

| | Apple Vision | PaddleOCR | ONNX Runtime |
|---|---|---|---|
| 依赖 | 系统 Vision.framework | Python 3.12 + paddlepaddle + paddleocr，venv 1.1 GB | onnxruntime（C/C++ 可静态链接）+ 31 MB 模型 |
| 内存 | 164 MB | 1.0–4.3 GB | 1.2 GB（Python 进程实测） |
| 功耗 | ANE，几乎不占 CPU | CPU 满载（实测 ~1 核） | CPU |
| 首次使用 | 系统按需下载语言资产（本机首次 13.4 s，之后 0.2 s） | 下载模型 + init 10–20 s | init 0.14 s，冷启动 0.7 s |

## 五、复现

```sh
cd tools/ocr-bench
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "paddlepaddle==3.3.1" paddleocr rapidocr onnxruntime pillow numpy
.venv/bin/python gen_corpus.py
xcrun swiftc -O -swift-version 6 -parse-as-library \
    ../../Kit/Core/ClipboardImageOCR.swift apple_ocr.swift -o apple_ocr

# Apple Vision（App 同配置）
./apple_ocr corpus/manifest.json --repeat 3 --out results/apple_accurate.json
# PP-OCRv6 三档（tiny 约 3 分钟，small 约 7 分钟，medium 约 30 分钟）
.venv/bin/python paddle_ocr.py corpus/manifest.json --config v6_tiny   --repeat 3 --out results/paddle_v6_tiny.json
.venv/bin/python paddle_ocr.py corpus/manifest.json --config v6_small  --repeat 3 --out results/paddle_v6_small.json
.venv/bin/python paddle_ocr.py corpus/manifest.json --config v6_medium --repeat 3 --out results/paddle_v6_medium.json
# 同族模型的 ONNX Runtime 形态（PP-OCRv6 small）
.venv/bin/python onnx_ocr.py corpus/manifest.json --ep cpu --repeat 2 --out results/onnx_cpu.json

.venv/bin/python evaluate.py --runs \
  "Apple Vision=results/apple_accurate.json" \
  "PP-OCRv6 tiny=results/paddle_v6_tiny.json" \
  "PP-OCRv6 small (ONNX)=results/onnx_cpu.json" \
  "PP-OCRv6 small (Paddle)=results/paddle_v6_small.json" \
  "PP-OCRv6 medium=results/paddle_v6_medium.json"
```
