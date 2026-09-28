# typesafe-bench：Kit 规则分类器 vs TypeSafe API

用同一批剪贴板文本样本，对比 Kit 生产环境的规则分类器
（`Kit/Core/ClipboardTextClassifier.swift`，本目录下原样编译）和
TypeSafe「智能判断」API（`api.typesafe.ai/v1/systemone`，模型 jev-latest）。

样本来源：`Kit/tests/ClipboardTextClassifierTests.swift` 里的全部边界案例
（16 个）+ 9 个手写刁钻案例（裸 shell 命令、终端会话、YAML、Python 推导式、
单行 C、.env、含 return 的中文散文、邮件、GFM 任务列表）。

## 结果（2026-09-28）

- 规则分类器 **19/25**：自家测试样本全对；9 个刁钻样本错了 6 个
  （全部把 code/config 误判成 text）。
- TypeSafe **22/25**：刁钻样本全对（6 个规则误判的全部翻正，置信度 1.00）；
  3 个不合 Kit 语义的地方都「情有可原」：
  - `ftp://` 判成 link（Kit 语义只认 http/https）——措辞可以修
  - 不存在的路径判成 path——TypeSafe 查不了磁盘，这是架构差异不是智力差异
  - `Use \`return () => {}\` carefully` 判成 code——但它的置信度只有 0.58，
    恰好是全场最低之一，说明它自己也不确定

## 结论

两条路线是互补的，混合方案最能扬长避短：

1. 规则先跑（离线、免费、隐私安全、确定性）：链接 scheme、磁盘路径这类
   有客观事实的可判定项。
2. 规则落在弱区时（例如 `isCode` 得分 < 3 落到 text、但文本含等号/缩进/冒号
   等「代码气味」）再问 TypeSafe，用返回的 confidence 决定采信还是保持保守。
3. 注意隐私：调 API 意味着把剪贴板文本发给第三方。Kit 是本地优先的工具，
   是否启用应做成开关（Obelisk 的 BYOK Intelligence 就是现成模式）。

## 复跑

```bash
# 0) 环境变量（首次）
export TYPESAFE_API_KEY="..."   # 已写在 ~/.zshrc

# 1) 规则侧：编译并运行（首次会拉取 swift-markdown）
echo fixture > ~/kit-bench-fixture.txt    # path 样本需要一个真实存在的文件
cd rules-cli && swift build
./.build/debug/rules-cli ../samples.json > ../rules-out.json

# 2) TypeSafe 侧（25 次调用，约 $0.0006，平均 ~1 秒/次）
cd .. && python3 typesafe_bench.py

# 3) 对比
python3 compare.py
```

## 文件

- `samples.json` — 样本 + 期望值 + 说明（想加样本往里追加即可）
- `rules-cli/` — 临时 Swift 包；`ClipboardTextClassifier.swift` 是生产文件的原样拷贝，
  `MarkdownProbe.swift` 是 `MarkdownAttributedRenderer.isMarkdown` 的原样移植，
  `ClipboardItemStub.swift` 只提供 Kind 枚举壳
- `typesafe_bench.py` — 调 API，问题措辞集中在文件顶部，方便审校
- `rules-out.json` / `typesafe-out.json` / `compare.py` — 输出与对比

本目录未被 git 追踪，不参与 App 构建；不需要时整个删掉即可。
