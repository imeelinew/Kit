# Kit 重構、最佳化與裁剪計畫

本文件只描述現況與建議，不修改任何產品程式。範圍是整個倉庫：Swift 原始碼、測試腳本、建置設定、資源與文件。數字以本次檢視時的程式為準。應用程式本體 62 個 Swift 檔、約一萬五千行，測試 22 個檔、約六千行。依賴只有 KeyboardShortcuts、Sparkle、swift-markdown（連帶 swift-cmark），以及系統 `sqlite3`。

## 結論

Kit 的採集策略、貼上事務、WAL 圖片回收與縮圖解碼排程已經清楚，不該整包重寫。真正拖累維護與執行期的是四件事：

1. `ClipboardStore` 在主執行緒上同時做資料庫、全文索引、拼音、圖片識字、檔案巡檢、堆疊與復原
2. 記憶體視窗保留最多 1000 筆完整文字，搜尋還會再複製一份
3. 剪貼簿讀取用並行的 `Task.detached`，失敗的查詢又被畫成空列表
4. 單一 App 目標把領域、儲存與 AppKit 外觀捆在一起，測試不進 Xcode，也不進 CI

裁剪應先刪確定沒用的資源與打包項，再拆檔但不改行為，最後才動記憶體模型與執行緒邊界。

## 現況架構

資料流與 `docs/architecture/架构图.md` 一致：`KitApp` 啟動 `AppCore`，`ClipboardManager` 每 0.1 秒看一次 `NSPasteboard.changeCount`，快照交給 `ClipboardCapturePipeline`，寫入 `ClipboardStore`，調色盤由 `PaletteViewModel` 分頁查詢。貼上走 `PasteTransaction` 與 `Paster`。

目錄只是分組，不是模組。`Kit.xcodeproj` 只有一個 `Kit` 目標。`Kit/Core` 同時放領域、SQLite、視窗、主題與捲軸。`Kit/Features` 同時放 SwiftUI 與直接呼叫 `AppCore.shared` 的設定頁。沒有 `Package.swift`，測試用 `scripts/test.sh` 以 `@testable import Kit` 編 Debug App，不使用 XCTest 目標。GitHub Actions 只有 `.github/workflows/publish-appcast.yml`，不跑測試。

已值得保留、重構時不要改語意的部分：

- `ClipboardCapturePolicy` 是純函式，敏感類型與排除清單可測
- `PasteTransaction.run` 把權限、準備、目標就緒、寫入、投遞分成固定順序
- 圖片刪除走 `pending_blob_deletions`，崩潰後可重試，且 `managedBlobURL` 拒絕任意路徑
- `ImageThumbnail.DecodeCoordinator` 限制同時解碼數，列縮圖與預覽分開計成本
- `SWIFT_STRICT_CONCURRENCY = complete`，儲存與識別器已可注入目錄與閉包

## 具體發現

### 1. 儲存型別過大，主執行緒承擔寫入

`Kit/Core/ClipboardStore.swift` 約 1565 行，標成 `@MainActor`。同一型別擁有連線、十四個預編譯 statement、記憶體視窗、堆疊、單筆復原、保留期、拼音佇列、OCR 工人、檔案巡檢、縮圖預熱與 blob 刪除。

熱點：

- `insert`、`refresh`、`prune`、`clearAll`、`saveImageOCR`、`reconcileFileSource` 都在主執行緒 `sqlite3_step`
- 插入會觸發 `Kit/Core/ClipboardSQLite.swift` 的 `items_ai`。FTS5 `tokenize='trigram'` 對正文、拼音、拼音首字母各建一份索引。大段文字的索引寫入會卡住調色盤
- `clearAll` 用 `DELETE FROM items`。每一列都跑刪除觸發器，仍在主執行緒
- `publishDeferredHistoryUpdates` 直接呼叫 `load()`，連堆疊狀態一起重讀
- `openDatabase` 失敗時只 `return`。之後 `loadStmt == nil`，歷史靜默變成空的，沒有 `sqlite3_errmsg`，也沒有 `Logger`。全專案只有 `Paster` 與 `ClipboardFileAccess` 使用 `os.Logger`
- `stacks.position` 只在 `createStack` 寫入 `stacks.count`，沒有重排 API。欄位有用（排序），但不要在這次重構加拖曳排序

`Kit/Core/ClipboardSearch.swift` 的 `queryDatabase` 每次查詢都 `sqlite3_open_v2` 再開一條唯讀連線。WAL 下這是正確方向，但連線建立沒有複用。`busy_timeout` 只有 500 毫秒。查詢失敗、取消、鎖等待都回傳 `nil`。`ClipboardStore.searchAsync` 把 `nil` 收成空的 `ClipboardSearchPage`。調色盤會把「資料庫忙」畫成「沒有結果」。

關閉圖片文字搜尋時，`textPredicate` 仍可能命中檔案路徑裡的拼音欄。程式用 `validatesFileImageText` 把 `LIMIT` 綁成 `-1`，先取出全部候選再在 Swift 裡過濾。歷史變長後，短查詢會一次拉進大量列。

拼音是插入後非同步寫的，所以第一頁還要把居民列送進 `ClipboardSearch.query` 做記憶體比對。這補上索引空窗是對的，但送進去的是完整 `ClipboardItem`，不是待索引 id。

欄位投影有兩份。`ClipboardStore.itemSelection` 與 `ClipboardSearch` 的 `SELECT` 各自列欄位，`ClipboardSQLite.row` 用寫死的欄位編號。搜尋多讀第 16 欄 `rowid`。以後加欄位很容易整列變成 `nil` 並被靜默丟掉。

### 2. 記憶體：一千筆全文，加上搜尋複製

`ClipboardStore.memoryWindow` 是 1000。`items` 保存完整 `text`。`ClipboardCapturePipeline.maxTextBytes` 是 8 MiB，沒有對應的圖片位元組或像素上限。`addImage` 只做 SHA-256 與 PNG 正規化。`normalizedPNG` 用 `NSBitmapImageRep` 解出第一幀，超大截圖會在採集 actor 上放大記憶體。

`PaletteViewModel.refreshResults` 每次按鍵或 `revision` 變化都重查 `pageSize * loadedPageCount`（頁大小 160）。`searchAsync` 在第一頁且查詢非空時，把符合篩選的居民列整包傳進 `Task.detached`。列表列型別 `ClipboardTableRow.item(ClipboardItem)` 又把全文放進 `Equatable`。`resultsGeneration` 變化時 `Kit/Features/Clipboard/ClipboardView.swift` 會 `reloadData()`。比對與重載都跟著全文走。

預覽另算一次成本。`ClipboardPreviewPayload.load` 對選中文字逐個 Unicode scalar 數字數與字數。8 MiB 文字可以接受在背景做，但不該同時留在主執行緒的千筆陣列裡。

`ImageThumbnail.removeCachedImage(for:)` 名為刪一張，實作是 `rowCache.purge()` 與 `previewCache.purge()`。`deleteBlob` 與 blob 回收工人每刪一張圖就清掉全部記憶體縮圖。磁碟縮圖有按 URL 刪除，記憶體快取沒有。

### 3. 剪貼簿輪詢與並行讀取

`ClipboardManager.pollInterval` 是 0.1 秒。`Timer` 加在主 RunLoop `.common`，沒有 `tolerance`。暫停時計時器仍每秒觸發約十次，只為了更新 `changeCount`。

`poll` 為每次變化建立 `Task.detached` 呼叫 `readSnapshot`。`captureTail` 只把後續處理串成順序，讀取本身並行。`NSPasteboard` 沒有執行緒安全保證。快速連續複製時，多個背景工作會同時讀同一塊剪貼簿。處理鏈有 `changeCount` 複核，能丟掉過期快照，擋不住並行讀取本身。

0.1 秒是為了縮短「複製當下的前景 App」歸屬窗口，這是產品取捨，不是必須維持的實作。建議改成單一序列佇列讀取，主執行緒只讀 `changeCount` 與型別，把位元組複製出去後再解碼。計時器加上 tolerance。連續數秒沒有變化時把間隔放寬，一有變化再回到短間隔。不要為了省電把歸屬窗口放到接近舊的 0.5 秒而不另記前景 App。

### 4. 圖片識字與檔案巡檢

`ClipboardImageTextRecognition.recognize` 每次都 `supportedRecognitionLanguages()`，再用 `.accurate` 跑 Vision，語言含 `zh-Hans`、`zh-Hant`、`en-US`。工人在 `startImageOCRWorkerIfNeeded`，每張圖之間只讓出 25 毫秒。大量歷史回填時 CPU 會長期佔用。語言支援清單應快取。調色盤開啟或使用者正在搜尋時應降優先級，而不是取消已完成的索引。

`startFileRefreshIfNeeded` 從 `load()` 啟動後每 15 秒跑一次，沒有檔案也會醒。`refreshFileReferences` 在主執行緒把所有 `file_is_image = 1` 的列讀進陣列，再逐個做書籤與 `stat`。選中預覽的 `ClipboardPreviewPayload.load` 還會再呼叫 `refreshFileReference`。同一簽名比對在 OCR 工人裡又寫了一次。

### 5. 半成品與死資源

`ClipboardItem.customTitle` 有欄位、列表顯示、搜尋 `LIKE` 與測試往返。`ClipboardStore` 沒有重新命名方法，選單與設定也沒有寫入入口。每一列讀取與搜尋仍為它付費。凍結它：重構不要擴充，除非另案做最小重新命名。不要在沒有遷移計畫時直接刪欄。

未使用的圖示：`Kit/Assets.xcassets/lucide-history.imageset`。設定頁只用 `lucide-settings`、`lucide-keyboard`、`lucide-sun-moon`、`lucide-volume-2`、`lucide-clipboard`、`lucide-info`（`Kit/Features/Settings/SettingsTab.swift`）。原始碼沒有 `lucide-history`。

`Kit.xcodeproj/project.pbxproj` 把倉庫根目錄的 `README.md` 放進 App Resources。`AboutSettingsView` 不讀它。檔案要留在倉庫，打包項可以拿掉。

重複的二進位資源，雜湊相同：

| 檔案 | 約略大小 | 說明 |
| --- | --- | --- |
| `.github/assets/logo.png`、`.github/assets/readme-icon.png`、`docs/site/assets/icon.png` | 各 1.4 MB | 同一張圖三份 |
| `.github/assets/readme-screenshot.png`、`docs/site/assets/screenshot.png` | 各 972 KB | 同一張截圖兩份 |
| `.github/assets/app.png` | 1.1 MB | 沒有第二份，但是大圖 |

靜態站與 README 需要可獨立開啟的路徑，不必刪光。應留一份主檔，其餘改引用或縮小到實際顯示尺寸。README 圖示顯示寬度是 112。

不要刪的資源：

- `SymbolsNerdFontMono-Regular.ttf` 約 2.5 MB。`NerdSymbolsFont` 要給剪貼簿裡任意私人使用區字元做回退，無法安全子集化
- JetBrains Mono 與兩份授權文字。預覽與法規都要用
- 四個複製音效。設定頁有對應選項

### 6. 模組邊界與重複

分類器依賴渲染器。`ClipboardTextClassifier.kind(for:)` 呼叫 `MarkdownAttributedRenderer.isMarkdown`。採集路徑因此連到 swift-markdown 與整棵 AppKit 屬性字串渲染。判斷「有沒有 Markdown 結構」應留在領域層，渲染留在 `Kit/Support/MarkdownAttributedRenderer.swift`。

文字預覽有三條路，職責不同，不要合成一個套件，但可以共用一個文字視圖生命週期：

- `Kit/Support/AttributedTextPreview.swift`
- `Kit/Support/MarkdownPreview.swift` 與 `MarkdownAttributedRenderer.swift`（約 428 行）
- `Kit/Support/CodeSyntaxHighlighter.swift` 的正則詞法上色

`CodeSyntaxHighlighter` 對整段（上限 512 KiB）跑多條正則再排序。選中程式碼時這是 CPU 熱點。可先維持規則，把工作留在已取消即停的背景，避免在主執行緒呼叫 `highlight`。

過大的檔，適合拆檔而不是重寫：

| 檔案 | 約略行數 | 建議切法 |
| --- | --- | --- |
| `Kit/Core/ClipboardStore.swift` | 1565 | 連線與 CRUD、保留期、堆疊、復原、索引工人分開 |
| `Kit/Features/Clipboard/ClipboardView.swift` | 999 | 表格協調與捲動幾何分開 |
| `Kit/Features/Clipboard/ClipboardPreview.swift` | 950 | `ClipboardPreviewPayload` 與視圖分開 |
| `Kit/Core/PaletteViewModel.swift` | 942 | 搜尋分頁與選單狀態機分開 |
| `Kit/Features/Clipboard/ClipboardTableCells.swift` | 711 | 列佈局維持，標題與縮圖載入可再分 |
| `Kit/Features/PopoverMenu.swift` | 679 | 維持自訂選單，不要改成 `NSMenu` |
| `Kit/Core/ImageThumbnail.swift` | 544 | 檔案簽名快取與解碼協調器分開 |
| `Kit/Core/PalettePanel.swift` | 490 | 視窗行為維持 |
| `Kit/Features/RootPaletteView.swift` | 476 | 佈局維持 |

`Kit/Core/MenuBarController.swift` 末尾的 `CopySoundPlayer` 與選單列無關，應跟音效資源放在一起。`Kit/Core/Theme.swift`、`ThinScrollbar.swift`、`EdgeDissolve.swift` 是介面，不該繼續放在 `Core`。

`AppCore.shared` 被選單、設定、貼圖、檔案授權、觸覺、更新服務直接抓取。`PaletteViewModel` 已經接收 `AppCore`，測試也用 `AppCore(clipboardStore:)`。新的畫面依賴應沿這條建構子走，不要再增加 `shared` 呼叫點。`PaletteHaptics`、`ClipboardFileAccess.showFailure`、`UpdateService` 仍讀全域狀態。

反應式風格有三套：`PaletteViewModel` 是 `@Observable`，卻用 Combine 聽 `clipboardStore.$revision`。`AppSettings` 與 `UpdateService` 是 `ObservableObject`。不要為了統一而一次改完。新程式跟所在畫面的既有風格走，拆 `ClipboardStore` 時不要順便把 `@Published` 改掉。

`Kit/Info.plist` 的 `LSApplicationCategoryType` 是 `public.app-category.productivity`。目標建置設定又寫了 `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities`。上架類別以實際合併結果為準，兩處應收成一個來源。

沙盒是關的（`Kit/Kit.entitlements`）。剪貼簿歷史、輔助使用與檔案書籤需要這個選擇。不要把開啟沙盒列進裁剪階段。

### 7. 錯誤處理

多數儲存 API 回傳 `Bool` 或 `nil`，呼叫端無法區分鎖、磁碟滿、約束失敗與「沒有這一列」。`addImage` 寫檔失敗就返回，不通知。`CopySoundPlayer` 播放失敗只把 player 設回 `nil`。

建議的最低線：SQLite 失敗記 `sqlite3_errmsg` 與 SQL 名稱。開庫失敗要讓啟動路徑可見，而不是繼續跑一個永遠插入失敗的 store。搜尋要能表示失敗，讓列表維持上一頁，而不是清空。不需要引入新的錯誤處理框架。

### 8. 測試與建置

測試品質比目標結構好。`docs/dev/TESTING.md` 與 `scripts/test.sh` 覆蓋分類、幾何、貼上事務、儲存、設定、搜尋、調色盤、採集、日期、圖片與舊回歸。儲存測試使用暫存目錄，不啟動輪詢與 Sparkle。

缺口：

- 沒有 Xcode 測試目標。`ENABLE_TESTABILITY` 只為了腳本連結 Debug App
- 七個 runner 各自編譯，CI 不跑
- 真實輪詢、輔助使用、Sparkle、登入啟動仍靠人工，這是合理的，不該用單測假裝覆蓋
- `scripts/benchmark-palette-opening.swift` 已在，重構前後應用它看開窗，而不是只看體感

建置本身沒有明顯的多餘編譯旗標。Release 已是 whole module 與 `-O`。不要為了「整理」改 Swift 6.4、部署目標 macOS 27 或嚴格並行。

文件方面，`docs/architecture/架构图.md` 與同名 HTML、`复制流程.html`、`docs/research/raycast-clipboard-research.md` 是研究材料，不是死碼。可留在倉庫。不要在裁剪程式時一併刪除。

## 建議目標架構

仍是單一 App 目標。先按檔案邊界拆，確認測試仍綠，再考慮本機套件。不要一開始拆成多個 Swift package。

```text
App
  KitApp、ApplicationMenu、AppCore
  AppCore 只做組裝、快捷鍵、視窗與傳輸任務

Capture
  ClipboardManager、ClipboardCapturePipeline、ClipboardCapturePolicy
  主執行緒只觀察 changeCount
  一條序列佇列擁有 NSPasteboard 讀取

Domain
  ClipboardItem、Kind、Retention、Stack
  ClipboardTextClassifier
  Markdown 結構判斷的純函式，不引用渲染器

Storage
  ClipboardSQLite          結構、遷移、欄位投影
  ClipboardDatabase        連線、交易、錯誤
  ClipboardHistoryStore    插入、去重、分頁讀取、復原、保留期
  ClipboardStackStore      堆疊
  SearchIndexWorker        拼音，離開主執行緒
  ImageTextIndexWorker     OCR
  FileReferenceMonitor     簽名與書籤

Search
  ClipboardSearch          查詢規劃與 FTS
  一條長壽的唯讀連線

Transfer
  PasteTransaction、Paster、Permissions、ClipboardFileAccess

UI
  Palette 視窗、狀態、列表、預覽、選單
  Settings、MenuBar、PinnedImage
  Theme、捲軸、邊緣淡出
```

記憶體模型改成列表投影：id、種類、標題片段、時間、來源、是否有圖、檔案是否為圖。全文與圖片位元組按預覽與貼上再讀。FTS 仍可索引全文，但索引寫入不要跟列表投影的發布綁在同一次主執行緒交易裡。若要限制索引成本，正文索引用前綴上限，完整內容仍存 `items.text`。這是行為取捨，要單獨做，並用現有搜尋測試鎖住「前綴以內的命中」。

`AppCore.shared` 可以留下給 `KitApp` 與選單列。設定頁與貼圖改為接收 store、settings、updateService。這一步不改變快捷鍵與貼上順序。

## 刪除與裁剪

可以直接刪或解除打包，風險低：

- 刪除 `Kit/Assets.xcassets/lucide-history.imageset`
- 從 `project.pbxproj` 的 Resources 移除 `README.md`，倉庫檔案保留
- 行銷圖留一份主檔，另外三份 icon 與一份截圖改為引用或縮小

凍結，不在本計畫實作，也不要順便擴充：

- `customTitle` 的寫入 UI
- 堆疊拖曳重排
- 把 `PopoverMenu` 換成 `NSMenu`
- 子集化 Nerd Font
- 開啟 App Sandbox
- 把研究 HTML 與 Raycast 筆記移出倉庫

可以稍後再拆、現在不要刪的大檔：`ClipboardStore`、`ClipboardView`、`ClipboardPreview`、`PaletteViewModel`、`ImageThumbnail`。它們大，但是活的。

## 優先順序

影響是使用者可感知的流暢度、記憶體或正確性。工作量是改動面。風險是行為回歸機率。

### 高

| 項目 | 影響 | 工作量 | 風險 | 位置 |
| --- | --- | --- | --- | --- |
| 列表只留投影，全文按需讀取 | 高 | 中 | 中 | `ClipboardStore` 記憶體視窗與 `searchAsync` 居民列、列表儲存格 |
| 剪貼簿讀取改成單序列，解碼放在複製之後 | 高 | 中 | 中 | `ClipboardManager.readSnapshot` |
| 搜尋失敗不要變成空列表 | 高 | 低 | 低 | `ClipboardSearch.queryDatabase`、`ClipboardStore.searchAsync`、`PaletteViewModel.refreshResults` |
| 大文字插入與 FTS 觸發器離開主執行緒關鍵路徑 | 高 | 中 | 中 | `ClipboardStore.insert`、`ClipboardSQLite` 觸發器 |
| 刪一張圖只失效該 URL 的記憶體縮圖 | 高 | 低 | 低 | `ImageThumbnail.removeCachedImage` |
| 關閉圖片文字搜尋時不要 `LIMIT -1` 全表拉取 | 高 | 低 | 中 | `ClipboardSearch.textPredicate` 與綁定參數 |

### 中

| 項目 | 影響 | 工作量 | 風險 | 位置 |
| --- | --- | --- | --- | --- |
| 拆 `ClipboardStore`，行為不變 | 中 | 中 | 中 | 同上，先搬移 OCR、檔案巡檢、拼音工人 |
| 複用唯讀連線，記錄 `sqlite3_errmsg` | 中 | 低 | 低 | `ClipboardSearch`、`openDatabase` |
| 檔案巡檢不要在主執行緒一次載入全部圖片檔列 | 中 | 中 | 中 | `refreshFileReferences`，15 秒迴圈 |
| 圖片像素或位元組上限 | 中 | 低 | 中 | `ClipboardCapturePipeline.normalizedPNG`、`addImage` |
| OCR 語言清單快取，回填在調色盤互動時降優先級 | 中 | 低 | 低 | `ClipboardImageTextRecognition` |
| 輪詢計時器加 tolerance，空閒放寬間隔 | 中 | 低 | 中 | `ClipboardManager.start` |
| 單一欄位投影，去掉魔術編號 | 中 | 中 | 中 | `ClipboardSQLite.row`、兩處 `SELECT` |
| 分類器與 Markdown 渲染脫鉤 | 中 | 低 | 中 | `ClipboardTextClassifier.kind` |
| 減少新的 `AppCore.shared`，設定與貼圖改建構子 | 中 | 中 | 中 | 設定頁、`PinnedImageWindow`、`ClipboardFileAccess` |
| 測試進入 CI，至少跑 `scripts/test.sh` 的子集或全量 | 中 | 中 | 低 | `.github/workflows`，目前只有 appcast |

### 低

| 項目 | 影響 | 工作量 | 風險 | 位置 |
| --- | --- | --- | --- | --- |
| 刪未用圖示、停止打包 README、合併重複行銷圖 | 低 | 低 | 低 | 資產與 `project.pbxproj` |
| 類別鍵收成一處 | 低 | 低 | 低 | `Info.plist` 與建置設定 |
| `CopySoundPlayer` 移出選單列檔 | 低 | 低 | 低 | `MenuBarController.swift` |
| `Theme`、捲軸、邊緣淡出移到 UI 目錄 | 低 | 低 | 低 | `Kit/Core` |
| 統一 Observable 與 Combine | 低 | 高 | 中 | 全 App，現在不做 |
| 抽成本機 Swift package | 低 | 高 | 中 | 拆檔穩定之後才考慮 |
| 程式碼高亮改增量或真正的語法樹 | 低 | 高 | 中 | `CodeSyntaxHighlighter`，現在只保證不在主執行緒跑 |

## 分階段推出

每一階段結束都要能單獨合併。先跑 `scripts/test.sh`。有開窗與列表變更時加跑 `scripts/benchmark-palette-opening.swift`。不要把儲存拆分和記憶體模型放在同一個變更裡。

### 階段 0：基線

不改行為。記錄現有測試指令與開窗基準。確認 `openDatabase` 失敗時今天的症狀（空歷史、無日誌），避免後面把舊問題當成回歸。

### 階段 1：裁剪與可觀察性

刪 `lucide-history`。解除 README 打包。收斂 App 類別鍵。SQLite 失敗寫日誌。搜尋區分取消、失敗與零筆。刪圖時只清該 URL 的記憶體縮圖。

這個階段不改結構描述，也不改索引內容。搜尋測試要新增「鎖等待或準備失敗時保留上一頁」這類案例。現有零筆查詢測試保持不變。

### 階段 2：拆檔，行為凍結

把 OCR 工人、檔案巡檢、拼音佇列、堆疊、保留期從 `ClipboardStore.swift` 搬到同目標的新檔。公開方法簽名先留在原型別上轉呼叫。`ClipboardPreviewPayload` 移出視圖檔。`CopySoundPlayer` 移出選單列。

驗收是 diff 以搬移為主，`scripts/test.sh` 全綠。不要在此階段改 SQL。

### 階段 3：執行緒與查詢

剪貼簿讀取序列化。計時器加 tolerance。唯讀連線複用。關閉圖片文字搜尋時用分頁條件，不再 `LIMIT -1`。檔案巡檢的列舉離開主執行緒，沒有圖片檔時不要週期醒來。OCR 快取語言清單。

採集、去重、檔案生命週期與 OCR 測試是這一階段的閘門。人工再看一次快速連續複製是否仍歸到正確的來源 App。

### 階段 4：記憶體模型與索引寫入

引入列表投影。居民比對只帶尚未寫入拼音的 id。全文插入後，FTS 與拼音在背景交易提交，列表先顯示投影。加上圖片像素或位元組上限，超過則拒絕或縮小後再存，並在測試寫明選擇哪一種。

這是唯一會改變搜尋延遲與超大圖片行為的階段。用 `tests/SearchSemanticsTests.swift`、`tests/ClipboardStoreIntegrationTests.swift`、`tests/ImageInfrastructureTests.swift` 鎖定。另準備一筆接近 8 MiB 的文字與一張超大圖，確認主執行緒不再同步做 trigram 與全圖解碼。

### 階段 5：依賴方向

`ClipboardTextClassifier` 不再呼叫渲染器。設定頁、貼圖、檔案對話框改為接收依賴。`AppCore.shared` 的既有呼叫可以留到下一個觸碰該檔案時再換，不要全庫機械替換。

### 階段 6：測試進 CI

在 macOS runner 上跑現有腳本。若 runner 沒有專案要求的 Xcode 27，先把工作流程寫成可手動觸發，並在文件註明機器需求。不要為了 CI 重寫一套 XCTest，除非腳本編譯成本已經高到無法接受。抽 Swift package 放在 CI 穩定之後。

## 不做的事

- 不把 SQLite 換成 SwiftData 或另一個封裝。現有 C API 與測試已經貼著真實結構
- 不把 FTS trigram 換成空白分詞。中文與無空白片段需要它。要減的是主執行緒寫入與索引範圍，不是演算法品牌
- 不重寫 `PopoverMenu`、貼圖視窗與解碼協調器。它們大，但邊界清楚
- 不在裁剪中刪除拼音、OCR 或檔案書籤。那是功能，不是重複實作
- 不開啟沙盒，不改部署目標，不放寬嚴格並行
