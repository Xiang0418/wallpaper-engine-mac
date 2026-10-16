Open Wallpaper Engine（修補版）
=========

[English](README.md) | **繁體中文** | [日本語](README.ja.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

基於 [Open Wallpaper Engine](https://github.com/MrWindDog/wallpaper-engine-mac) 的修補分支，為 macOS 加入場景桌布渲染與網頁桌布修復。

> **注意：** 本專案與 Steam 上的商業版 Wallpaper Engine 無關。這是一個開源的 macOS 應用程式，可顯示來自 Wallpaper Engine Steam 創意工坊的桌布素材。

## 相關專案

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — 基於 [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) 的 PyQt6 圖形介面，Steam 工作坊整合與 UI 設計移植自本 macOS 版本。

## 致謝

本專案建立於以下貢獻者的成果之上：

- **[MrWindDog](https://github.com/MrWindDog)** — 上游 [wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac) 分支的維護者，新增功能與 UI 優化
- **[Haren Chen](https://github.com/haren724)** — [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac) 原作者，建構核心架構（SwiftUI、影片桌布播放、匯入系統、播放清單 UI）
- **[1ris_W](https://github.com/Erica-Iris)** — 中文 i18n 翻譯
- **[Klaus Zhu](https://github.com/klauszhu1105)** — 應用程式圖示
- **[Chen Chia Yang](https://github.com/Unayung)** — 場景桌布渲染、網頁桌布修復、Steam 創意工坊整合、多螢幕支援、Zip 匯入

採用 [GPL-3.0](LICENSE) 授權，與原始專案相同。

## 0.8.0 新功能

### 多螢幕支援
為每個連接的螢幕指定不同的桌布，並可個別啟用或停用。
- **顯示器設定面板** — 以視覺化佈局顯示所有連接的螢幕，點擊選取
- **個別螢幕桌布** — 每個螢幕可獨立顯示不同的桌布
- **啟用/停用切換** — 可針對每個螢幕開啟或關閉桌布
- **自動偵測** — 新連接的螢幕會自動偵測並啟用

### 多桌面支援
桌布現在可在所有 macOS 桌面（空間）上顯示並持續播放，切換桌面時不會中斷。

### 最近使用的桌布選單
可從狀態列選單快速切換桌布。最近使用的 10 個桌布可一鍵存取。

### 播放設定 — 已修復
效能播放設定（切換應用程式時暫停/靜音/停止）現在對所有桌布類型均可正常運作。

### Steam 創意工坊瀏覽器
直接在應用程式內瀏覽、搜尋及下載 Steam 創意工坊的桌布。
- **搜尋與篩選** — 依名稱搜尋，依內容分級（Everyone/Questionable/Mature）、類型（Scene/Video/Web）及風格標籤篩選
- **排序選項** — 熱門趨勢、最新發布、最受歡迎、最多訂閱
- **steamcmd 整合** — 自動偵測 steamcmd（Homebrew 或自訂路徑），未安裝時提供安裝指引
- **Steam 登入** — 支援密碼、Steam Guard 及快取 Session 驗證
- **下載進度顯示** — 即時狀態更新（驗證中、下載百分比、驗證、複製中）
- **安全預設** — 內容分級預設為「Everyone」，過濾成人內容

### Zip 匯入
直接匯入 `.zip` 桌布套件，無需手動解壓縮。支援 檔案 > 匯入 及拖放操作。

### 多選與批次取消訂閱
Cmd+點擊選取多個桌布，右鍵選擇批次取消訂閱。

### 桌布儲存隔離
桌布現在儲存在 `~/Documents/Open Wallpaper Engine/`，不再使用原始 Documents 目錄，避免克隆專案時出現「error」桌布。

## 修補內容

### 網頁桌布 — 修復灰色/空白渲染
基於 WebGL 的桌布因 `WKWebView` 阻擋本地檔案存取而顯示為灰色方塊。

**修復：** 在 WKWebView 設定中啟用 `allowFileAccessFromFileURLs` 和 `allowUniversalAccessFromFileURLs`，允許 WebGL 著色器載入本地紋理檔案。

### 場景桌布 — 從零開始實作
場景桌布（Steam 創意工坊最常見的類型）原本完全未實作——僅顯示「Hello, World!」。

**新實作包括：**
- **PKG 解析器** — 讀取 Wallpaper Engine 的 PKGV 封存格式，提取 scene.json、模型、材質和紋理
- **TEX 解析器** — 讀取 TEXV0005 紋理容器，從 TEXI/TEXB 區段提取嵌入的 JPEG/PNG 圖片
- **Scene JSON 解碼器** — 解析 scene.json，靈活處理多態欄位（值可為純類型或 `{"script":..,"value":..}` 物件）
- **SpriteKit 渲染器** — 將場景圖層渲染為 SKSpriteNode，正確處理定位、尺寸、透明度、色彩調整和混合模式
- **預覽回退** — 無法提取紋理時回退至 preview.jpg/png/gif
- **紋理與圖層支援** — 支援 LZ4、RGBA8888、R8/RG88、DXT1/3/5、父子變換與可見性、套件字型，以及指定桌布的透明度、旋轉、圓角外框效果。詳見 [第二階段測試與範圍](tests/README.md#phase-two-rendering)。

### 匯入 — 修復資料夾匯入
匯入面板現在可正確處理單一桌布資料夾和包含多個桌布的父目錄。

## 目前限制

- **紋理範圍** — 解碼第一張圖片及最高解析度 mip；動畫紋理序列及其他像素格式尚未支援。
- **粒子效果** — 已支援桌布 3799672625 的滑鼠 rope 拖尾（生成、速度、壽命與尺寸變化）；其他粒子系統尚未完整支援。
- **動態與互動** — 已接入此桌布的 SceneScript、時鐘、24 個啟動器及套件音樂頻譜。支援範圍與驗證方式見 [第三階段](tests/README.md#phase-three-runtime-and-integration)。
- **其他播放器整合** — 在「設定 → 一般」啟用播放中歌曲封面與外部音訊頻譜；支援提供控制中心資訊的播放器（如 Chrome / YouTube）。音訊需要系統錄製權限，封面使用可能受 macOS 更新影響的私有介面。[設定與限制](tests/README.md#external-players-artwork-and-system-audio-spectrum)。
- **著色器效果** — 已移植桌布 3799672625 使用的部分效果；任意 GLSL、泛光及模糊尚未支援，未支援效果會記錄於日誌。
- **相機視差** — 滑鼠追蹤相機移動未實作。
- **動畫場景** — 精靈動畫和基於時間軸的物件動畫不支援。
- **圖片容器** — 從 mip 資料區讀取 JPEG/PNG；損壞或不支援的主背景仍使用預覽備援。

## 支援的桌布類型

| 類型 | 狀態 |
|------|------|
| 影片 (.mp4, .webm) | 正常運作（原始） |
| 網頁 (HTML/WebGL) | 正常運作（已修補） |
| 場景（靜態圖片） | 正常運作（新功能） |
| 場景（粒子） | 指定桌布的 rope 拖尾 |
| 場景（DXT 紋理） | DXT1/3/5 軟體解碼 |
| 應用程式 | 不支援 |

## 從原始碼建置

### 前置需求
- macOS >= 13.0
- Xcode >= 14.4
- Xcode Command Line Tools

### 步驟
```sh
git clone https://github.com/unayung/wallpaper-engine-mac
cd wallpaper-engine-mac
open "Open Wallpaper Engine.xcodeproj"
```

在 Xcode 中，將簽署憑證更改為您自己的或選擇「Sign to Run Locally」，然後按 `Cmd + R` 建置並執行。

## 使用方式

### 從 Steam 創意工坊瀏覽與下載

1. 安裝 steamcmd（`brew install steamcmd`）或指向現有的二進位檔
2. 切換到 **Workshop** 分頁，使用 Steam 帳號登入（必須擁有 Wallpaper Engine）
3. 出現提示時輸入 [Steam Web API 金鑰](https://steamcommunity.com/dev/apikey)
4. 搜尋、篩選，然後點擊 **Download** 下載桌布

### 從本地檔案匯入

- **資料夾：** 檔案 > 從資料夾匯入——選擇包含 `project.json` 的桌布資料夾
- **Zip：** 檔案 > 匯入 或拖放包含桌布套件的 `.zip` 檔案
- **手動：** 直接將桌布資料夾複製到 `~/Documents/Open Wallpaper Engine/`

## 變更的檔案（相對上游）

**修改：**
- `WebWallpaperView.swift` — WKWebView 檔案存取設定
- `WallpaperView.swift` — 場景桌布分派
- `SceneWallpaperView.swift` — 改寫為 SpriteKit NSViewRepresentable
- `ImportPanels.swift` — 資料夾匯入邏輯修復

**新增：**
- `Services/SceneParsers/PKGParser.swift` — PKGV 封存解析器
- `Services/SceneParsers/TEXParser.swift` — TEXV 紋理解析器
- `Services/SceneParsers/SceneModels.swift` — Scene JSON 資料模型
- `Services/SceneWallpaperViewModel.swift` — 場景載入與 SpriteKit 渲染
- `Services/SteamCmdService.swift` — steamcmd 偵測、登入與創意工坊下載
- `Services/WorkshopAPIService.swift` — Steam Web API 客戶端
- `Services/WorkshopViewModel.swift` — 創意工坊瀏覽器狀態管理
- `Services/WallpaperDirectory.swift` — 集中式桌布儲存路徑
- `Services/ZipImporter.swift` — Zip 檔案解壓與匯入
- `ContentView/Components/WorkshopView.swift` — 創意工坊瀏覽器 UI

### Steam 訂閱與 Windows 共用

桌布搜尋結果的卡片可直接按「訂閱」。第一次或登入過期時會開啟 Steam 官方登入視窗，
登入後關閉視窗，再按一次「訂閱」即可；之後可以直接訂閱，成功後顯示「已訂閱」。
Windows 使用相同 Steam 帳號，即可共用訂閱清單。

「下載」透過 SteamCMD 將桌布下載到 Mac。Steam 網頁與 SteamCMD 是分開的登入工作階段，
請使用相同帳號。訂閱不代表已下載到 Mac，也不會同步播放設定或自動下載全部訂閱。
訂閱按鈕只訂閱所選桌布，不會切換成取消訂閱，也不會自動訂閱相依項目。

### Workshop 篩選

搜尋介面左側可設定內容分級、桌布類型、分類、25 種解析度，以及功能特性與題材。
解析度包含 4K、超寬、直式、雙／三螢幕及動態解析度。
題材與功能可勾選為必要條件，或按旁邊的減號排除，例如排除動漫或 HDR。
所有勾選條件必須同時符合；分級、類型、分類及解析度各選一項或「不限」。
「清除全部」移除所有條件，「重設」恢復預設的普遍級篩選。

### 原版共用場景素材

在「設定 → 一般 → Wallpaper Engine 共用素材」匯入原版 `assets` 資料夾，或選擇包含 `assets` 的 Wallpaper Engine 安裝目錄。程式會驗證 `materials`、`shaders` 非空並複製到 `~/Library/Application Support/Open Wallpaper Engine/EngineAssets/`，成功後自動重新載入正在播放的場景。原始資料夾不會被修改。

也可以先在創意工坊分頁登入 Steam，再按「從 Steam 下載／更新」。這會透過 SteamCMD 的 `download_depot 431960 431961` 取得原版內容 depot（需要帳號擁有 Wallpaper Engine），收到對應 depot 的完成訊息並驗證素材後才匯入。此流程不使用會連帶排程 Workshop 更新的 `app_update`。depot 仍包含原版程式內容，請預留 depot 及素材副本的空間。Steam 未回報百分比時顯示不定進度條與內容套件的檔案數、容量，不推估虛假的完成比例。下載失敗或匯入失敗會保留原本可用的素材。

場景讀取優先順序是：桌布 PKG → 桌布資料夾 → 共用素材 → 已實作的替代素材。支援 Windows 路徑分隔符及大小寫差異；桌布自己的素材優先於共用素材。設定頁的「場景素材診斷」列出播放中場景的缺檔、解析失敗、尚未支援的效果及近似替代素材。原版 shader 並不會因為下載素材而自動執行；一般粒子仍有相容性限制，目前執行中的粒子支援主要是 rope 軌跡。

每次成功匯入會建立獨立素材快照並原子切換索引，舊快照保留讓既有場景安全結束讀取。若要清理舊快照，先退出程式，保留 `active.json` 中 `snapshot` 指定的 UUID 資料夾與 `steam-install`，其餘舊 UUID 資料夾可移除。共用原版素材不包含在本專案發行內容中。

### 場景動畫貼圖與粒子

一般圖層現在可以播放 TEX 內嵌的 MP4 動畫，並套用白色去背（colorkey）與基本 shake 方向遮罩；暫停、睡眠與切換桌布會同步停止播放器。

已加入螢火蟲、跟隨尾光與櫻花貼圖粒子的 2D 模擬，以及此桌布的三種音頻樣式：上下捲動圓角長條、`Simple_Audio_Bars` 底部長條、三色漸層頻譜曲線與魚眼變形（對應的色彩、數量、間距、透明度、振幅與靈敏度可即時調整）。粒子的湍流、序列映射與拖尾不保證與原版 3D 運動相同，會保留近似實作診斷；未移植的其他 shader 變體仍會標示未支援。這些音頻圖層可直接生成，不需要讀取完整畫面緩衝；一般的畫面緩衝效果仍未支援。

`_rt_FullFrameBuffer` 是執行期畫面緩衝，現在列為尚未支援的渲染資源，不會誤報缺少可下載的素材檔案。

### 純系統音訊擷取

外部音訊頻譜使用 Core Audio Process Tap（macOS 14.2 以上），不建立螢幕擷取串流、不擷取麥克風，也不儲存音訊。macOS 可能要求系統音訊錄製授權；不支援或授權失敗時只顯示錯誤，不會退回螢幕擷取。原有桌布音樂仍使用本機分析並與外部音訊混合。

設定中的「正在聆聽其他 App（僅音訊）」表示音訊裝置已啟動；「已收到系統音訊（僅音訊）」表示本次連線已實際收到非靜音訊號。後者不是當下音量指示，停止播放時頻譜仍會歸零。

### 鎖定畫面跟隨影片桌布（實驗）

macOS 26 可在「設定 → 一般 → 鎖定畫面」啟用，預設自動跟隨 macOS 主螢幕，也可以指定固定螢幕。插拔或更換主螢幕後等待顯示設定穩定再同步。該螢幕切換影片桌布後，程式會在背景使用 VideoToolbox 轉成靜音 HEVC Main10 航拍影片；短片重複至至少三分鐘。快速切換會取消舊工作，鎖定期間完成的轉檔會等解鎖後套用。場景桌布會獨立錄製 15 秒、30 fps 動畫，錄製時關閉可辨識的時間／日期／星期開關，原桌面設定不變。錄好的動畫再重複至至少三分鐘；網頁桌布保留上次影片。場景設定改動會重新錄製，內容與設定相同時使用快取。鎖定時播放的是錄製片段，不是即時互動場景。退出程式後保留已套用影片。

首次使用前，請在系統設定下載並選取一個 Apple 航拍桌布，螢幕保護程式設為「自動」。目前首次設定僅接受一個已下載的航拍影片，以免選錯檔案；多個下載會顯示錯誤並保留原狀。程式不會自動改選系統桌布，也不更改密碼、鎖定及螢幕關閉設定。播放時間仍受系統控制，不保證永久循環。

原始影片、桌布設定與 SHA-256 記錄保留於 `~/Library/Application Support/Open Wallpaper Engine/LockScreenSync/`。關閉功能會還原首次備份的影片與整份桌布設定，因此也會回復備份後在系統設定做的桌布變更。若航拍影片被系統或其他程式改動，會停止覆寫並顯示錯誤。啟用或還原失敗期間，程式會保護 Aerial 設定，暫停原本的選單列底圖調整。

此功能利用已下載的系統 Aerial 影片，並非 Apple 公開的自訂鎖定桌布 API；系統更新後可能需要重新驗證。原生編碼方式參考 [macos-custom-video-wallpaper-fix](https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix)，使用 Main10 與 temporal sublayers 避免 Aerial 縮圖條紋。

鎖定場景的快取依桌布、設定與螢幕比例保存：解析度不同但比例相同會重用錄製內容，換回已使用的比例也會沿用。另保存已轉成 Aerial 格式的影片並校驗，快取命中時不重新轉檔。影片背景維持等比例填滿，音頻元件依可見範圍重新排版，避免被系統裁切。新影片完成前保留原影片。全新螢幕首次使用仍須在 macOS 為該螢幕選取航拍背景及「自動」螢幕保護程式；此處的自動跟隨負責選擇來源與產生影片，不會改寫系統未公開的顯示器桌布設定。

啟用鎖定同步時，創意工坊下載成功並匯入後，會依目前跟隨螢幕的比例依序預備影片快取，不會切換鎖定桌布。場景先錄製、影片直接轉檔；切換桌布優先於下載預備。偵測新比例時只準備目前使用的桌布，舊比例重用快取。未完成的下載預備佇列不跨程式重啟保留，之後選用桌布時仍會補製。

準備鎖定影片時，主視窗與一般設定顯示桌布名稱及處理階段。場景錄製進度依已完成影格計算（15 秒片段），轉檔與套用階段顯示不定進度，完成後收起。

鎖定場景錄製使用獨立背景序列佇列，場景載入、繪製、GPU 等待和影格寫入不在主執行緒執行。主執行緒僅讀取共用媒體狀態及更新提示；切換桌布時取消舊錄製。

桌面切換場景時，會在背景準備素材、圖片、節點及音訊，完成後才替換舊場景；影片則等待新播放器就緒。載入期間顯示提示並保留原桌布，失敗保留原狀，連續切換以最後一次選擇為準。網頁桌布仍使用原有 WebKit 載入流程。

### Workshop preset 桌布

支援只有 `dependency` 與 `preset` 的 Workshop 預設組態。首次套用時會使用
已登入的 SteamCMD 下載缺少的原始桌布，依序合併設定與附帶素材，並支援巢狀依賴。
原始 `project.json` 保持不變；播放內容存於該桌布資料夾內的 `.preset-runtime`。
音量與個人設定仍以 preset 為單位儲存。下載失敗或依賴循環時會顯示原因，保留目前桌布。
Scene 材質的自訂圖片綁定可讀取 preset 附帶的圖片與 GIF 動畫。
