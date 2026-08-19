# Hướng dẫn chạy Arkon (Windows) — 4 Terminal

> Áp dụng cho môi trường dev local trên Windows. Thư mục dự án: `D:\Storm12\Arkon\arkon`.
> Toàn bộ lệnh backend phải chạy **sau khi đã bật môi trường ảo `.venv`** (xem Bước 1).

---

## 0. Điều kiện tiên quyết (chạy 1 lần)

Cần 3 dịch vụ nền chạy trước: **PostgreSQL (có pgvector)**, **Redis**, **MinIO**.
Nếu bạn đã cài sẵn hoặc đang chạy bằng Docker thì bỏ qua phần này — chỉ cần đảm bảo chúng đang bật.

Kiểm tra nhanh (nếu dùng Docker):

```powershell
docker ps
```

Phải thấy các container postgres / redis / minio ở trạng thái `Up`. Nếu chưa có, xem `docs/HOW_TO_RUN.md` mục "Infrastructure" để tạo.

> Lưu ý cổng: theo `.env` của bạn, Postgres đang ở `localhost:5433` (không phải 5432 mặc định). Redis `6379`, MinIO `9000/9001`.

Cài dependencies (chỉ chạy lần đầu, hoặc khi đổi package):

```powershell
# Trong thư mục dự án, sau khi đã bật .venv
pip install -e ".[dev]"

cd frontend
npm install
cd ..
```

---

## 1. Mở môi trường ảo (venv) — làm ở MỌI terminal backend

Mỗi terminal chạy backend (Terminal 1, 2, 3) đều phải bật `.venv` **trước** khi chạy lệnh.

**PowerShell:**

```powershell
cd D:\Storm12\Arkon\arkon
.\.venv\Scripts\Activate.ps1
```

**Command Prompt (cmd):**

```cmd
cd /d D:\Storm12\Arkon\arkon
.venv\Scripts\activate.bat
```

Khi bật thành công, đầu dòng lệnh sẽ có tiền tố `(.venv)`.

> Nếu PowerShell báo lỗi "running scripts is disabled", chạy 1 lần:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`
> rồi mở lại terminal và thử `Activate.ps1` lại.

> Nếu chưa từng tạo venv: `python -m venv .venv` rồi bật lại như trên.

Terminal 4 (Frontend) **không cần** venv — nó chạy Node/npm.

---

## 2. Bốn Terminal

Mở 4 cửa sổ terminal riêng. Mỗi terminal giữ một tiến trình chạy liên tục (đừng đóng).

### Terminal 1 — API Server (FastAPI)

```powershell
cd D:\Storm12\Arkon\arkon
.\.venv\Scripts\Activate.ps1
uvicorn app.main:app --host 0.0.0.0 --port 5055 --reload
```

- API: http://localhost:5055
- Swagger docs: http://localhost:5055/docs
- Lần chạy đầu sẽ tự tạo bucket MinIO và seed tài khoản admin mặc định (`admin@arkon.local`).

### Terminal 2 — Wiki Worker (xử lý ingest tài liệu → wiki)

```powershell
cd D:\Storm12\Arkon\arkon
.\.venv\Scripts\Activate.ps1
python -m arq app.worker.WorkerSettings
```

Đây là tiến trình chạy pipeline MRP (upload tài liệu, sinh wiki). Log ingest hiện ở đây.

### Terminal 3 — Skills Worker (xử lý skills)

```powershell
cd D:\Storm12\Arkon\arkon
.\.venv\Scripts\Activate.ps1
python -m arq app.worker.SkillWorkerSettings
```

### Terminal 4 — Frontend (Next.js) — KHÔNG cần venv

```powershell
cd D:\Storm12\Arkon\arkon\frontend
npm run dev
```

- Giao diện: http://localhost:3000

---

## 3. Đăng nhập

Mở http://localhost:3000 → đăng nhập bằng tài khoản admin trong `.env.local`
(`DEFAULT_ADMIN_EMAIL` / `DEFAULT_ADMIN_PASSWORD`, mặc định `admin@arkon.local`).

Sau khi đăng nhập, vào **Settings** cấu hình AI provider (Embedding model + API key, LLM).

---

## 4. Ghi chú quan trọng

**Thứ tự khởi động:** bật 3 dịch vụ nền (Bước 0) → Terminal 1, 2, 3 → Terminal 4.

**Sau khi sửa code backend:** `uvicorn` có `--reload` nên tự nạp lại. Nhưng **2 worker (Terminal 2, 3) KHÔNG tự reload** — sửa code liên quan tới ingest/worker phải `Ctrl + C` dừng rồi chạy lại lệnh của terminal đó, nếu không nó vẫn chạy code cũ.

**Dừng dự án:** bấm `Ctrl + C` ở từng terminal.

**Migration DB (khi đổi model / kéo code mới có migration):**

```powershell
cd D:\Storm12\Arkon\arkon
.\.venv\Scripts\Activate.ps1
alembic upgrade head
```

---

## 5. Bảng cổng nhanh

| Thành phần        | URL / Cổng                  |
|-------------------|-----------------------------|
| Frontend          | http://localhost:3000       |
| API               | http://localhost:5055       |
| API Docs (Swagger)| http://localhost:5055/docs  |
| PostgreSQL        | localhost:5433              |
| Redis             | localhost:6379              |
| MinIO API/Console | localhost:9000 / 9001       |
