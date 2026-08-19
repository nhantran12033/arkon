# Kết nối Claude Desktop với Arkon qua MCP (dùng token)

> Hướng dẫn cho Windows. Cách này dùng **token MCP** của Arkon (header `Authorization: Bearer`),
> phù hợp khi bạn muốn cấu hình tay bằng file config thay vì luồng đăng nhập OAuth.

---

## Bước 1 — Lấy token MCP từ Arkon

1. Đăng nhập web Arkon (http://localhost:3000).
2. Vào trang **Profile**.
3. Ở thẻ **MCP Token**, bấm **Generate**.
4. **Copy token ngay** — token dạng `ark_xxxxxxxxxxxxxxxxxxxx` và **chỉ hiện một lần**. Nếu mất phải Generate lại (token cũ sẽ bị vô hiệu).

> Token gắn với chính tài khoản của bạn → Claude sẽ chỉ thấy đúng phần kiến thức mà quyền của bạn cho phép.
> Nếu cần token cho người khác, admin vào **Employees → nhân viên → Generate token**.

---

## Bước 2 — Cài Node.js (nếu chưa có)

Cầu nối `mcp-remote` chạy bằng `npx` (đi kèm Node.js). Kiểm tra:

```powershell
node -v
npx -v
```

Nếu báo lỗi "not recognized", tải và cài Node.js LTS tại https://nodejs.org rồi mở lại terminal.

---

## Bước 3 — Mở file cấu hình của Claude Desktop

Trên Windows, file ở:

```
%APPDATA%\Claude\claude_desktop_config.json
```

Cách mở nhanh: nhấn `Win + R`, dán dòng sau rồi Enter:

```
%APPDATA%\Claude
```

Mở `claude_desktop_config.json` bằng Notepad (nếu chưa có thì tạo mới file này).

> Bạn cũng có thể vào Claude Desktop → **Settings → Developer → Edit Config** để mở đúng file.

---

## Bước 4 — Dán cấu hình Arkon

Dán nội dung sau. **Thay `ark_...` bằng token bạn vừa copy ở Bước 1.**

```json
{
  "mcpServers": {
    "arkon": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "http://localhost:5055/mcp",
        "--header",
        "Authorization:${AUTH_HEADER}"
      ],
      "env": {
        "AUTH_HEADER": "Bearer ark_xxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

### ⚠️ Vì sao viết lạ vậy (quan trọng cho Windows)

Claude Desktop trên Windows có lỗi **không escape đúng khoảng trắng trong args**. Nếu bạn viết thẳng
`"Authorization: Bearer ark_..."` trong phần `args`, header sẽ bị hỏng và kết nối thất bại.

Cách vòng ở trên xử lý việc đó: bỏ khoảng trắng sau dấu hai chấm (`Authorization:${AUTH_HEADER}`),
và đặt phần có khoảng trắng (`Bearer <token>`) vào biến môi trường `AUTH_HEADER`. Nhớ giữ nguyên chữ
`Bearer ` (có một khoảng trắng) trước token trong phần `env`.

> Nếu đã có sẵn `mcpServers` khác trong file, chỉ cần thêm khối `"arkon": {...}` vào bên trong, đừng tạo hai khối `mcpServers`.

Lưu file lại.

---

## Bước 5 — Khởi động lại Claude Desktop

**Thoát hẳn** Claude Desktop (không chỉ đóng cửa sổ — vào khay hệ thống, chuột phải → Quit) rồi mở lại.
Config chỉ được nạp khi khởi động.

---

## Bước 6 — Kiểm tra

Trong Claude Desktop, mở phần công cụ (icon MCP / "Search and tools"). Bạn phải thấy server **arkon**
với các công cụ như `search_wiki`, `read_wiki_page`, `list_wiki_pages`, `read_wiki_index`...

Thử hỏi một câu liên quan tới tài liệu đã nạp, ví dụ:

> "Search Arkon: Business Analyst có những cấp bậc nào?"

Claude sẽ gọi `search_wiki` sang Arkon và trả lời kèm nguồn.

### (Tùy chọn) Ép Claude luôn ưu tiên Arkon

Vào **Settings → Profile → Custom Instructions** (hoặc Project Instructions), thêm:

```
Khi câu hỏi liên quan tới người, phòng ban, chính sách, quy trình hay dự án nội bộ,
luôn tìm trong Arkon trước bằng công cụ search_wiki rồi mới dùng kiến thức chung.
```

---

## Xử lý sự cố

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| Không thấy server arkon | Sai cú pháp JSON (thiếu dấu phẩy/ngoặc). Kiểm tra lại file. Chưa Quit hẳn rồi mở lại. |
| Server có nhưng 0 công cụ / "Authentication required" | Token sai hoặc header hỏng. Kiểm tra `AUTH_HEADER` đúng dạng `Bearer ark_...` (có khoảng trắng sau Bearer). Token có thể đã bị revoke → Generate lại. |
| "Invalid or inactive MCP token" | Token bị thu hồi hoặc tài khoản bị tắt (`is_active`). Tạo token mới, kiểm tra tài khoản còn active. |
| Kết nối timeout | Arkon (Terminal API, cổng 5055) chưa chạy. Bật server trước. |
| Đổi máy / Arkon chạy ở máy khác | Thay `http://localhost:5055/mcp` bằng địa chỉ thật của server, ví dụ `https://arkon.congty.com/mcp`. `localhost` chỉ đúng khi Claude Desktop và Arkon ở cùng máy. |

---

## Ghi chú bảo mật

- Token = danh tính của bạn. Ai có token đều truy cập được đúng phạm vi quyền của bạn. Đừng chia sẻ.
- Thu hồi bất cứ lúc nào: trang **Profile → MCP Token → Revoke** (Claude Desktop sẽ mất kết nối ngay).
- Token nằm ngay trong file `claude_desktop_config.json` dưới dạng chữ thường — giữ máy tính an toàn.
