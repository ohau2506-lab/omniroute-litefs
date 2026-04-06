# User-Facing Change Logs

## [2026-04-06] Sửa lỗi mất cấu hình mỗi lần deploy + khởi động sạch hơn

### Vấn đề đã giải quyết

**Cấu hình bị mất sau mỗi lần deploy:**
Mỗi lần deploy, hệ thống tạo ra một "generation" mới trên S3 thay vì
dùng lại data cũ. Nguyên nhân: URL kết nối S3 bị thiếu phần `https://`
khiến kiểm tra S3 thất bại âm thầm, hệ thống tưởng không có data cũ
và khởi động từ đầu. Nay đã được sửa — data và cấu hình được giữ nguyên
sau mỗi lần deploy.

**App khởi động trước khi dữ liệu tải xong từ S3:**
Trước đây có thể xảy ra trường hợp OmniRoute bắt đầu nhận traffic
khi database chưa được restore hoàn toàn từ S3. Nay: hệ thống chờ
xác nhận database đã sẵn sàng trước khi cho phép traffic vào.

**Khởi động cleaner khi chuyển leader:**
Khi instance mới lên thay vị trí leader, tất cả containers được dọn dẹp
và tạo mới hoàn toàn thay vì chỉ restart. Giảm nguy cơ chạy với
config cũ hoặc state bị lỗi.

### Không cần thay đổi gì từ phía người dùng
Toàn bộ quá trình là tự động. Cấu hình hiện tại không thay đổi.

---

## [2026-04-05] Hỗ trợ chạy nhiều instance đồng thời + khắc phục mất dữ liệu

### Vấn đề đã giải quyết

**Mất cấu hình khi chuyển sang Linux runner:**
Trước đây, nếu kết nối S3 lỗi (sai credentials, network chậm), hệ thống vẫn start
với database rỗng và ghi đè lên data cũ. Nay: hệ thống **từ chối khởi động**
và báo lỗi rõ ràng thay vì âm thầm mất data.

**Không thể chạy nhiều instance đồng thời:**
Chạy 2 instance cùng lúc trước đây sẽ khiến cả 2 ghi lên S3 và corrupt backup.
Nay: hệ thống tự động bầu chọn 1 instance làm **Leader** duy nhất xử lý traffic
và ghi database. Các instance còn lại đứng chờ (Follower) và tự động lên làm
Leader khi instance chính gặp sự cố.

### Cách hoạt động

- **Leader**: chạy đầy đủ — OmniRoute + Litestream backup + Cloudflare Tunnel
- **Follower**: tắt tất cả services — Cloudflare tự động redirect traffic sang Leader
- **Failover**: Leader chết → Follower lên thay trong vòng ~60 giây

### Không cần thay đổi gì từ phía người dùng
Toàn bộ quá trình là tự động. Cấu hình hiện tại không thay đổi.
