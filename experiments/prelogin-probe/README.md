# 登入前循環影片最小驗證

獨立於正式 App。使用 Apple PreLoginAgents 的 LoginWindow session 機制，
測試桌面層級的無聲循環影片是否能出現在登出後的登入介面。**視窗建立成功不等於圖片可見。**

## 測試行為

- 每個螢幕左右各 10% 寬、中央 70% 高的區域播放 3 秒 H.264 藍綠色移動圓點影片，使用 AVQueuePlayer + AVPlayerLooper 循環，強制靜音。
- 中央 80% 與上下邊緣沒有測試視窗；不搶焦點、不接收輸入、沒有選單。
- 安裝的登入前版本使用 desktopWindow；本機 preview / lock-test 已改為 floating，僅驗證一般桌面可見性。
- 登入前執行最多 90 秒，KeepAlive 關閉；安裝一小時後不再顯示。
- 到期不會自行移除安裝檔；請在測試後移除。
- 只讀取 App 內建的測試影片，不讀使用者桌布、Steam、網頁或外部圖片，不改系統桌布或登入設定。
- 可用 --lock-test 在登入中測試 90 秒；不涵蓋 FileVault 解鎖畫面或完整動態桌布相容性。

## 建置與安裝

在專案根目錄執行：

```sh
bash experiments/prelogin-probe/build.sh
build/prelogin-probe/WallpaperLoginProbe.app/Contents/MacOS/WallpaperLoginProbe --preview
sudo bash experiments/prelogin-probe/install.sh
```

預覽 8 秒後退出。安裝需要管理員權限；若管理員程序不能讀取 Documents，
把 `experiments/prelogin-probe/install.sh` 與 `build/prelogin-probe/WallpaperLoginProbe.app`
保持相對目錄結構複製至私人暫存目錄，再從該目錄執行安裝。

## 實際驗證

1. 儲存工作，在安裝後一小時內手動選 Apple 選單 → 登出。
2. 在前 90 秒觀察左右是否出現持續移動的藍綠色圓點，觀察至少 10 秒確認跨越多次循環。
3. 確認帳號、密碼欄位、登入按鈕都清楚可見且可正常操作。
4. 登入後讀取本程式日誌，區分未啟動、啟動但被遮住、以及真正顯示成功。

```sh
/usr/bin/log show --last 20m --style compact --predicate 'subsystem == "org.openwallpaperengine.prelogin-probe"'
```

日誌 `preview=false` 才是登入前測試。`Video sample` 的 `time`、`loops`、`ready` 分別記錄播放時間、循環次數及影格是否就緒。`Submitted desktop-level windows` 只證明提交視窗，
必須由實際畫面確認可見性。若圖片擋住任何控制項，等 90 秒自動退出，登入後移除。

## 移除（登入回來後）

```sh
sudo rm -f /Library/LaunchAgents/org.openwallpaperengine.prelogin-probe.plist
sudo rm -rf /Library/PrivilegedHelperTools/WallpaperLoginProbe.app
```

也可執行 `sudo bash experiments/prelogin-probe/uninstall.sh`。僅移除本實驗的兩個固定路徑。

## 已知驗證結果（2026-10-12 更正）

- 靜態圖片版：使用者澄清先前只看到原本的角色桌布，沒有測試圓點；先前「成功」判定撤回。
- 影片版：日誌證明解碼與循環正常，包括登入前 session，但不證明視窗可見。
- 一般桌面：本機版本改為 floating 並明確設定 AVPlayerLayer 尺寸後，截圖確認兩側圓點可見。
- 鎖定畫面：使用者確認圓點消失；目前方案未達成鎖定顯示。
- 登出畫面：使用者未看到測試影片；目前方案未達成。

## 參考

- https://developer.apple.com/library/archive/samplecode/PreLoginAgents/Listings/Read_Me_About_PreLoginAgents_txt.html
- https://developer.apple.com/forums/thread/775067
