#!/bin/bash
# debug-test.sh — 自動化記憶體 debug 腳本
#
# 用法：
#   ./debug-test.sh /path/to/photos [duration_seconds]
#
# 範例：
#   ./debug-test.sh /Volumes/home/Photos/2014 60
#
# 流程：
#   1. Build app（incremental）
#   2. 啟動 log stream（背景截取 unified log）
#   3. 清空 tmp-debug-library，以乾淨狀態啟動 app
#   4. App 自動 add-folder，開始掃描 + 生成縮圖
#   5. 等待指定秒數後 kill app
#   6. 停止 log stream，分析記憶體

set -euo pipefail

FOLDER="${1:-}"
DURATION="${2:-60}"
APP="./build/DerivedData/Build/Products/Debug/Spectrum.app"
APP_BIN="$APP/Contents/MacOS/Spectrum"
TMP_LIBRARY="./tmp-debug-library"
LOG_DIR="./logs"
LOG_FILE="$LOG_DIR/debug-$(date +%Y%m%d-%H%M%S).log"

# ── 參數檢查 ────────────────────────────────────────────────
if [[ -z "$FOLDER" ]]; then
    echo "用法: $0 <folder-path> [duration-seconds]"
    echo "  folder-path    要 add-folder 的目錄路徑"
    echo "  duration-seconds  等待秒數 (預設 60)"
    exit 1
fi

if [[ ! -d "$FOLDER" ]]; then
    echo "錯誤：找不到目錄 $FOLDER"
    exit 1
fi

# ── Build ────────────────────────────────────────────────────
echo "==> Building..."
./build.sh 2>&1 | tail -5

if [[ ! -f "$APP_BIN" ]]; then
    echo "錯誤：找不到 app binary: $APP_BIN"
    exit 1
fi

# ── 準備目錄 ─────────────────────────────────────────────────
mkdir -p "$LOG_DIR" || true
rm -rf "$TMP_LIBRARY"
mkdir -p "$TMP_LIBRARY"

echo ""
echo "==> 測試設定"
echo "    Folder  : $FOLDER"
echo "    Library : $TMP_LIBRARY"
echo "    Duration: ${DURATION}s"
echo "    Log     : $LOG_FILE"
echo ""

# ── 啟動 app（--log-stdout 讓 log 直接寫到 stdout）──────────
echo "==> 啟動 Spectrum..."
"$APP_BIN" \
    --spectrum-library "$TMP_LIBRARY" \
    --add-folder "$FOLDER" \
    --log-stdout \
    > "$LOG_FILE" 2>&1 &
APP_PID=$!
echo "==> App PID: $APP_PID"

# ── 等待 ─────────────────────────────────────────────────────
echo "==> 等待 ${DURATION}s..."
sleep "$DURATION"

# ── 停止 app ─────────────────────────────────────────────────
echo "==> Kill app (PID $APP_PID)..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo ""
echo "==> 分析 log: $LOG_FILE"
echo ""

# ── 記憶體分析 ───────────────────────────────────────────────
LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
echo "    總 log 行數: $LINE_COUNT"
echo ""

# Scheduler pass 摘要
PASS_LINES=$(grep -E "\[scheduler\] pass [0-9]+ " "$LOG_FILE" 2>/dev/null || true)
if [[ -n "$PASS_LINES" ]]; then
    echo "── Scheduler Pass 摘要 ──────────────────────────────────"
    echo "$PASS_LINES"
    echo ""
fi

# 每 batch 的記憶體
BATCH_LINES=$(grep -E "\[scheduler\] batch " "$LOG_FILE" 2>/dev/null | head -40 || true)
if [[ -n "$BATCH_LINES" ]]; then
    echo "── Batch 記憶體（前40筆）────────────────────────────────"
    echo "$BATCH_LINES"
    echo ""
fi

# 最後 20 筆 [thumb-post]（確認修正後記憶體不再累積）
POST_LINES=$(grep "\[thumb-post\]" "$LOG_FILE" 2>/dev/null | tail -20 || true)
if [[ -n "$POST_LINES" ]]; then
    echo "── 最後 20 筆 thumb-post（post-drain 記憶體）───────────"
    echo "$POST_LINES"
    echo ""
fi

# 找出 post-drain 記憶體最大的幾筆
MAX_POST=$(grep "\[thumb-post\]" "$LOG_FILE" 2>/dev/null \
    | grep -oE "mem=[0-9]+" \
    | grep -oE "[0-9]+" \
    | sort -rn | head -5 || true)
if [[ -n "$MAX_POST" ]]; then
    echo "── post-drain 記憶體最高值（MB）───────────────────────"
    echo "$MAX_POST" | awk '{print "    " $0 " MB"}'
    echo ""
fi

# 找出 post-drain 最大跳躍（相鄰兩行差值）
echo "── post-drain 最大跳躍偵測 ─────────────────────────────"
grep "\[thumb-post\]" "$LOG_FILE" 2>/dev/null \
    | grep -oE "mem=[0-9]+" \
    | grep -oE "[0-9]+" \
    | awk 'NR>1{diff=$1-prev; if(diff<0)diff=-diff; if(diff>50) printf "  +%d MB jump at photo #%d\n", diff, NR} {prev=$1}' \
    | head -10 \
    || echo "  （無大跳躍或資料不足）"
echo ""

# [thumb-sips] 統計：sips subprocess 路徑的記憶體效率
SIPS_COUNT=$(grep -c "\[thumb-sips\]" "$LOG_FILE" 2>/dev/null || true)
SIPS_COUNT=${SIPS_COUNT:-0}
SIPS_SKIP=$(grep -c "\[thumb-sips\] skip" "$LOG_FILE" 2>/dev/null || true)
SIPS_SKIP=${SIPS_SKIP:-0}
if [[ "$SIPS_COUNT" -gt 0 ]]; then
    echo "── sips 路徑統計 ────────────────────────────────────────"
    echo "    sips 成功: $((SIPS_COUNT - SIPS_SKIP)) 張  / fallback: $SIPS_SKIP 張"
    # sips 路徑的 total 記憶體趨勢（最後10筆）
    SIPS_TOTAL=$(grep "\[thumb-sips\]" "$LOG_FILE" 2>/dev/null \
        | grep -v "skip" \
        | grep -oE "total=[0-9]+" \
        | grep -oE "[0-9]+" \
        | tail -10 || true)
    if [[ -n "$SIPS_TOTAL" ]]; then
        echo "    最後 10 筆 total mem（MB）: $(echo "$SIPS_TOTAL" | tr '\n' ' ')"
    fi
    SIPS_MEM_AVG=$(grep "\[thumb-sips\]" "$LOG_FILE" 2>/dev/null \
        | grep -v "skip" \
        | grep -oE "mem=\+[0-9-]+" \
        | grep -oE "[0-9-]+" \
        | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "n/a"}' || true)
    echo "    平均 mem 增量/張（MB）: ${SIPS_MEM_AVG:-n/a}"
    echo ""
fi

# [thumb-ql] 統計：QL fallback 路徑
QL_COUNT=$(grep -c "\[thumb-ql\]" "$LOG_FILE" 2>/dev/null || true)
QL_COUNT=${QL_COUNT:-0}
if [[ "$QL_COUNT" -gt 0 ]]; then
    QL_SKIP=$(grep -c "\[thumb-ql\] skip" "$LOG_FILE" 2>/dev/null || true)
    QL_SKIP=${QL_SKIP:-0}
    echo "── QL fallback 統計 ─────────────────────────────────────"
    echo "    QL 成功: $((QL_COUNT - QL_SKIP)) 張  / skip: $QL_SKIP 張"
    echo ""
fi

echo "==> 完成。完整 log: $LOG_FILE"
