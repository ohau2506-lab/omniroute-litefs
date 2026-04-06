#!/bin/sh
# ══════════════════════════════════════════════════════════════════════
# litestream/startup.sh
#
# 3 trường hợp:
#   A) Local DB đã tồn tại → skip restore, replicate luôn
#   B) Không có local DB + không có replica S3 → start fresh
#   C) Không có local DB + có replica S3 → restore (fail hard nếu lỗi)
#
# FIX (issue #2 — generation mới mỗi lần):
#   Trước: litestream snapshots 2>/dev/null || echo ""
#          → nếu S3 lỗi (sai endpoint/credential/network) → output rỗng
#          → startup.sh nghĩ "không có snapshot" → start fresh → generation mới
#   Sau  : capture stderr riêng, nếu command exit non-zero → FATAL exit 1
#          → không bao giờ start fresh khi S3 có lỗi
#
# FIX (issue #3 — omniroute start trước khi restore xong):
#   startup.sh là blocking: restore → exec replicate.
#   elector chờ litestream healthy (= replicate đang chạy = restore xong)
#   → omniroute chỉ được start sau waitLitestreamReady() trong elector.js
# ══════════════════════════════════════════════════════════════════════
set -e

DB_PATH="/app/data/storage.sqlite"
CONFIG_PATH="/etc/litestream.yml"

echo "[startup] ════════════════════════════════════"
echo "[startup]  Litestream Startup"
echo "[startup]  DB        : ${DB_PATH}"
echo "[startup]  Bucket    : ${LITESTREAM_BUCKET:-<not set>}"
echo "[startup]  Supabase  : ${SUPABASE_PROJECT_REF:-<not set>}"
echo "[startup] ════════════════════════════════════"

if [ ! -f "${CONFIG_PATH}" ]; then
  echo "[startup] ✖ Config không tìm thấy: ${CONFIG_PATH}"
  exit 1
fi

mkdir -p "$(dirname "${DB_PATH}")"

# ── CASE A: Local DB đã tồn tại → skip restore ───────────────────────
if [ -f "${DB_PATH}" ]; then
  DB_SIZE=$(du -sh "${DB_PATH}" 2>/dev/null | cut -f1 || echo "?")
  echo "[startup] ✅ Local DB đã tồn tại (${DB_SIZE}) — bỏ qua restore"

else
  # ── CASE B/C: Không có local DB ──────────────────────────────────
  echo "[startup] Không có local DB — kiểm tra S3 replica..."

  SNAPSHOT_STDERR_LOG="/tmp/litestream-snapshots-err.log"
  SNAPSHOT_EXIT=0
  SNAPSHOT_OUTPUT=""

  # FIX: KHÔNG dùng 2>/dev/null — capture stderr để phát hiện lỗi S3
  SNAPSHOT_OUTPUT=$(litestream snapshots \
    -config "${CONFIG_PATH}" \
    "${DB_PATH}" 2>"${SNAPSHOT_STDERR_LOG}") || SNAPSHOT_EXIT=$?

  # Log stderr nếu có (warnings hoặc errors)
  if [ -s "${SNAPSHOT_STDERR_LOG}" ]; then
    echo "[startup] ⚠ litestream snapshots stderr:"
    sed 's/^/[startup]   /' "${SNAPSHOT_STDERR_LOG}"
  fi

  # FIX: Nếu command fail → không thể xác định trạng thái S3
  # → từ chối start fresh, exit 1 để elector retry
  if [ "${SNAPSHOT_EXIT}" -ne 0 ]; then
    echo "[startup] ════════════════════════════════════"
    echo "[startup] ✖ FATAL: litestream snapshots THẤT BẠI (exit ${SNAPSHOT_EXIT})"
    echo "[startup]"
    echo "[startup] Không thể xác định trạng thái S3 — từ chối start với DB rỗng."
    echo "[startup] Nguyên nhân thường gặp:"
    echo "[startup]   1. SUPABASE_PROJECT_REF sai hoặc chưa set"
    echo "[startup]   2. LITESTREAM_ACCESS_KEY_ID / SECRET sai"
    echo "[startup]   3. Bucket '${LITESTREAM_BUCKET:-?}' chưa tạo trong Supabase Storage"
    echo "[startup]   4. Endpoint S3 không đúng (kiểm tra litestream.yml)"
    echo "[startup]   5. Network không reach được Supabase"
    echo "[startup] ════════════════════════════════════"
    exit 1
  fi

  if echo "${SNAPSHOT_OUTPUT}" | grep -q .; then
    # CASE C: Có replica → restore bắt buộc thành công
    echo "[startup] ✅ Tìm thấy replica trên S3:"
    echo "${SNAPSHOT_OUTPUT}" | head -5 | sed 's/^/[startup]   /'
    echo "[startup] Đang restore từ S3..."

    # Restore vào file tạm rồi mv về DB_PATH:
    # - Tránh lỗi "output path already exists" nếu DB xuất hiện giữa chừng
    # - Tránh replicate nhầm DB rỗng khi restore chưa hoàn tất
    RESTORE_LOG="/tmp/litestream-restore.log"
    RESTORE_TMP="/tmp/storage.restore.$$.sqlite"
    rm -f "${RESTORE_LOG}" "${RESTORE_TMP}"

    # Không dùng -if-replica-exists: ta đã biết có replica từ bước check trên.
    # Nếu bây giờ restore fail thì là lỗi thật → exit 1.
    if litestream restore \
        -config "${CONFIG_PATH}" \
        -o "${RESTORE_TMP}" \
        "${DB_PATH}" >"${RESTORE_LOG}" 2>&1; then

      if [ ! -f "${RESTORE_TMP}" ]; then
        echo "[startup] ✖ Restore báo thành công nhưng không có file tạm: ${RESTORE_TMP}"
        sed 's/^/[startup] /' "${RESTORE_LOG}" || true
        exit 1
      fi

      rm -f "${DB_PATH}"
      mv "${RESTORE_TMP}" "${DB_PATH}"

      DB_SIZE=$(du -sh "${DB_PATH}" 2>/dev/null | cut -f1 || echo "?")
      echo "[startup] ✅ Restore thành công (${DB_SIZE})"

    else
      EXIT_CODE=$?
      echo "[startup] ════════════════════════════════════"
      echo "[startup] ✖ FATAL: Restore THẤT BẠI (exit ${EXIT_CODE})"
      sed 's/^/[startup] /' "${RESTORE_LOG}" || true
      echo "[startup]"
      echo "[startup] Kiểm tra:"
      echo "[startup]   1. LITESTREAM_ACCESS_KEY_ID và SECRET có đúng không?"
      echo "[startup]   2. SUPABASE_PROJECT_REF có đúng không?"
      echo "[startup]   3. Network có reach được Supabase S3 không?"
      echo "[startup]   4. Bucket '${LITESTREAM_BUCKET:-?}' có tồn tại không?"
      echo "[startup]   5. Endpoint có đúng https:// protocol không?"
      echo "[startup] ════════════════════════════════════"
      rm -f "${RESTORE_TMP}"
      exit 1
    fi

  else
    # CASE B: Command thành công (exit 0) nhưng không có snapshot
    # → S3 kết nối OK nhưng chưa có data → an toàn để start fresh
    echo "[startup] ℹ Không tìm thấy snapshot trên S3 (fresh install) — bắt đầu với DB mới"
  fi
fi

echo "[startup] Khởi động Litestream replication..."
exec litestream replicate -config "${CONFIG_PATH}"
