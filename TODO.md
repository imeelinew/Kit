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
