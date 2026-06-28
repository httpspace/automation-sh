# webops Laravel 排程查找 UX 優化 — 設計

日期：2026-06-28
範圍：`webops/lib/tui.sh`、`webops/laravel-svc.sh`

## 背景與問題

`laravel-svc.sh` 管理多網域的 Laravel queue/scheduler（Supervisor）。當已設定的網域變多後，使用者反映「不方便查找」，痛點有二：

1. **選單捲動找網域**：restart / logs / view / disable 與 enable 的 picker 都用 `tui_menu`（whiptail `--menu`，一次只顯示 12 列）。網域一多就得用方向鍵捲，難定位到想要的那一個。
2. **status / list 文字牆**：`status` 直接把 `supervisorctl status | grep` 的原始行倒進捲動框，未排序、看不出每個網域整體健康；網域一多就是一面牆，看不出誰在跑、誰掛了。

目標：在**不新增任何套件、不改 Supervisor conf 命名/格式**的前提下，讓「找特定網域」與「一眼看出整體健康」都順手，且**篩選流程穩定**（邊界完整、`set -e -o pipefail` 安全）。

## 決策

- 篩選機制：**純 whiptail 關鍵字篩選**（不引入 fzf，零新依賴，與現有 webops 一致）。
- 觸發門檻：項目數 **> 12**（等於 whiptail 可視列數）才啟動關鍵字篩選；≤ 12 直接出選單，不增加摩擦。
- `list` 選單項：**保留**為「快速純清單（不呼叫 supervisorctl）」，標示更新；`status` 升級為健康總覽。零功能回歸。

## Part A — 可篩選 picker：`tui_pick_filtered`

在 `lib/tui.sh` 新增 helper，介面與 `tui_menu` 相同（drop-in 替換）：

```
tui_pick_filtered <prompt> <key1> <label1> [<key2> <label2> ...]
```

行為：
- 令 `total` = 項目對數（`$#/2`）。`total <= TUI_FILTER_THRESHOLD`（預設 12）→ 直接 `tui_menu`，回傳其結果。
- 否則進入篩選迴圈：
  1. `tui_input` 詢問關鍵字（提示含「大小寫不分；留空＝全部，共 N 站」）。取消/Esc → `return 1`。
  2. 逐對比對：**key 以 `__` 開頭者為「釘選」，永遠顯示**（保住 `__all__` / `__manual__` 等控制項）；其餘以 `label` 或 `key` 做**大小寫不敏感、字面子字串**比對（關鍵字內的 `.`、`*` 等不被當萬用字元）。
  3. 篩到 0 筆（非釘選）→ `tui_msg` 提示找不到，回到 1. 重問。
  4. 篩到 ≥1 筆 → 在選單頂端插入控制項 `__refilter__`「🔍 重新輸入關鍵字（目前『kw』→ matched/total）」，呼叫 `tui_menu`。
  5. 選到 `__refilter__` → 帶入目前關鍵字回到 1. 重問；否則 echo 選中的 key 並 `return 0`。取消 → `return 1`。

接線（把 `tui_menu` picker 換成 `tui_pick_filtered`）：
- `laravel-svc.sh`：restart（含 `__all__`）、logs、view、disable 四個動作的服務 picker。
- `pick_laravel_domain()`（enable 流程，含 `__manual__` 逃生口）。

`__all__` / `__manual__` 因釘選規則在篩選後仍在；既有後續判斷（`SEL == __all__` / `__manual__`）不變。

## Part B — `status` 健康總覽

改寫 `status` 動作：
- 抓一次 `supervisorctl status`（**必須 `|| true`**：supervisorctl 在有停止程式時回非零碼，否則 `set -e` 會中止）。
- 依 `*-sched.conf` 取得的 short-name **排序**，逐網域解析：
  - queue：匹配 `^<short>-queue:` 的行數為 `qtotal`，其中 RUNNING 為 `qrun`。
  - sched：匹配 `^<short>-sched[[:space:]]` 是否 RUNNING。
  - 標記：queue 全跑且 sched 跑 → `✓`；queue 全停且 sched 停 → `✗`；其餘 → `⚠`。
- 頂端摘要行：`共 N 站 ｜ ✓ 全綠 X ｜ ⚠/✗ 異常 Y：<逐一列出異常網域>`，讓問題站一眼可見。
- 仍用 `tui_scroll` 顯示。

範例：
```
共 37 站 ｜ ✓ 全綠 34 ｜ 異常 3：shop-staging.example.com, api.foo.example.com, bar.example.com

✓ api.shop.example.com      queue 3/3 RUNNING    sched RUNNING
⚠ api.foo.example.com       queue 0/2 STOPPED    sched RUNNING
✗ bar.example.com           queue 0/1 STOPPED    sched STOPPED
...
```

`list` 動作維持純網域清單（標示為「快速清單」），不呼叫 supervisorctl。

## 不更動

- 不新增套件、不動 `.env` / config、不動 Supervisor conf 命名與內容、不動 enable 寫檔與參數流程。
- 其他 webops 腳本不動（`tui_pick_filtered` 為通用 helper，未來 site-mgr / domain-mgr 可沿用，但本次不接線）。

## 穩定性與驗證

`tui_pick_filtered` 在 `set -e -o pipefail` 下需通過的邊界（以隔離測試 stub 掉 whiptail 驗證篩選核心）：
- 空關鍵字 → 顯示全部（非釘選全列）。
- 關鍵字含 `.` / `*` / `[` → 視為字面字元，不誤判。
- 大小寫不分。
- 釘選 `__` 項在任何關鍵字下都保留。
- 0 筆 → 提示重問，不崩、不無限迴圈（取消即 `return 1`）。
- `total <= 12` → 跳過篩選直接出選單。

`status` 解析：以模擬的 `supervisorctl status` 文字驗證 qrun/qtotal、sched 狀態、標記與摘要正確；確認 short-name 字首不誤匹配（`a` vs `ab`，靠 `-queue:` / `-sched ` 後綴錨定）。

整體：`bash -n` 語法檢查；`shellcheck` 無新增嚴重告警。實機上以多網域進 restart picker 打關鍵字、看 status 總覽確認。

文件範例一律使用 `example.com`（public repo 規範）。
