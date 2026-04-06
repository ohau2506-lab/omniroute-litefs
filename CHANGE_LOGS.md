# Change Logs

## [2026-04-06] fix: compose down/up + litestream S3 generation + DB verify before omniroute

### Vấn đề đã fix

#### Fix 1 — Khi leader mới lên thay: `docker compose down` trước khi start
- **Trước**: elector dùng `docker start/stop` → container cũ vẫn còn, state không clean
- **Sau**: elector dùng `docker compose stop + rm` (= down) rồi `docker compose up` mới
- Kết quả: mỗi lần leader win election, tất cả managed containers được tạo mới hoàn toàn

#### Fix 2 — Litestream tạo generation mới mỗi lần (mất dữ liệu/config)
- **Root cause**: `litestream.yml` thiếu `https://` ở endpoint → `litestream snapshots` fail
  - `2>/dev/null || echo ""` nuốt error → output rỗng → startup.sh nghĩ "không có snapshot"
  - → start fresh → tạo generation mới → dữ liệu cũ không được dùng
- **Fix A**: `litestream.yml`: endpoint `${SUPABASE_PROJECT_REF}.supabase.co/...` → `https://${SUPABASE_PROJECT_REF}.supabase.co/...`
- **Fix B**: `startup.sh`: bỏ `2>/dev/null || echo ""` → capture stderr riêng
  - Nếu `litestream snapshots` exit non-zero → **exit 1 (hard fail)**, không start fresh
  - Chỉ start fresh khi command thành công (exit 0) nhưng output rỗng (truly no data)
- **Fix C**: `litestream.yml`: xóa `path: storage` bị duplicate

#### Fix 3 — Đảm bảo S3 sync xong trước khi omniroute start
- **Trước**: `waitHealthy("litestream", 180)` chỉ check container health status
- **Sau**: `waitLitestreamReady(180)` = healthy + `docker exec` verify DB file tồn tại và non-empty
  - Nếu DB rỗng → warn nhưng tiếp tục (fresh install case)
  - Nếu DB có data → xác nhận restore thành công trước khi start omniroute

### services/elector/Dockerfile (MODIFIED)
- Thêm `docker-cli-compose` package để enable `docker compose` subcommand

### services/elector/elector.js (MODIFIED)
- Thêm constant `COMPOSE_FILE = "/workspace/docker-compose.yml"` và `ENV_FILE`
- Thêm `composeExec()` — wrapper cho `docker compose -f ... --env-file ... -p ...`
- Thêm `composeStopRemove(service, graceSec)` — stop + rm một service
- Thêm `composeDown(services[])` — stop + rm danh sách services theo thứ tự
- Thêm `composeUp(service)` — `docker compose up -d <service>`
- Thêm `waitLitestreamReady(timeoutSec)` — healthy + DB file verify
- `onBecomeLeader`: composeDown → composeUp litestream → waitLitestreamReady → composeUp omniroute/cloudflared
- `onFollowerRetire`: composeDown (stop+rm) thay vì svcStop
- `leaderHealthCheck`: composeUp thay vì svcStart (recreate, không chỉ restart)
- `shutdown`: composeDown thay vì svcStop
- `main()` init: composeDown thay vì svcStop
- Bump version string: v3 → v4

### docker-compose.yml (MODIFIED)
- Elector: thêm volume mount `${CUR_WORK_DIR:-.}:/workspace:ro`
  - Cho phép elector chạy `docker compose -f /workspace/docker-compose.yml`
  - `CUR_WORK_DIR` được set bởi detect-os.sh và ghi vào .env

### litestream/litestream.yml (MODIFIED)
- **CRITICAL FIX**: endpoint thêm `https://` prefix
- Xóa `path: storage` bị duplicate (YAML duplicate key)

### litestream/startup.sh (MODIFIED)
- Thay `2>/dev/null || echo ""` bằng capture stderr vào temp file
- Nếu `litestream snapshots` exit non-zero → exit 1 (hard fail, không start fresh)
- Bỏ `-if-replica-exists` khỏi lệnh restore (đã verify trước đó, fail rõ ràng hơn)
- Thêm cleanup `rm -f "${RESTORE_TMP}"` trong error path

## [2026-04-05] feat: multi-instance leader election + litestream restore hardening

### services/elector/ (NEW)
- **Dockerfile**: Alpine 3.19 + bash + curl + jq + docker-cli
- **elector.sh**: Leader election daemon dùng Firebase RTDB conditional PUT (If-Match ETag)
  - Unique INSTANCE_ID per container lifecycle (/proc/sys/kernel/random/uuid)
  - Docker Compose project name lowercase để match container labels chính xác
  - RTDB base/query URL separation để handle `?auth=TOKEN` trong URL
  - try_acquire_lock(): atomic compare-and-swap qua HTTP 200/412 response code
  - check_still_leader(): chịu đựng RTDB flaky tối đa 3 heartbeat trước khi demote
  - on_become_leader(): start thứ tự litestream → wait_healthy(180s) → omniroute → cloudflared
  - on_become_follower(): stop thứ tự cloudflared(10s) → omniroute(35s) → litestream(15s)
  - svc_ensure_running(): health monitor trong heartbeat loop, tự restart crashed services
  - cleanup trap: graceful shutdown — demote trước khi exit để leader mới không phải chờ TTL

### docker-compose.yml (MODIFIED)
- Thêm service `elector` với docker socket mount (/var/run/docker.sock)
- Đổi restart policy của litestream/omniroute/cloudflared → `restart: "no"`
  - Lý do: tránh race condition, elector là sole owner của start/stop
- Xóa depends_on omniroute → litestream (elector xử lý ordering)
- Thêm `INSTANCE_ID` env var cho elector
- Tăng litestream healthcheck start_period 30s → 120s
- Thêm logging config cho tất cả services (max-size: 10m)

### litestream/startup.sh (MODIFIED)
- Thay `-if-replica-exists` bằng 2-phase check:
  1. `litestream snapshots` để biết có replica không
  2. Nếu có → restore WITHOUT -if-replica-exists
  3. Nếu restore fail → **exit 1** (refuse to start với DB rỗng)
- Trước: silent fail → start với empty DB → mất data
- Sau: hard fail → elector retry → không bao giờ ghi đè data cũ

### .github/workflows/deploy.yml (MODIFIED)
- STEP 2b: Inject INSTANCE_ID = "{run_id}-{attempt}-{runner_name}"
- STEP 3: Force leader lock takeover trước deploy (DELETE RTDB lock)
  - Cho phép instance mới win election ngay, không phải chờ TTL 30s
- STEP 6: Poll RTDB confirm instance này đã là leader trước keepalive
