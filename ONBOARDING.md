# Hướng dẫn Onboarding — Dự án Arkon

Chào mừng bạn gia nhập dự án **Arkon**. Tài liệu này giúp bạn nắm nhanh kiến trúc hệ thống, cơ chế chống "bịa thông tin" (hallucination) và quy trình deploy.

---

## 1. Tổng quan dự án

Arkon là hệ thống backend viết bằng **Python/FastAPI**, sử dụng:

| Thành phần | Vai trò |
|---|---|
| **PostgreSQL + pgvector** | Lưu dữ liệu quan hệ + vector embedding để tìm kiếm ngữ nghĩa |
| **Redis** | Cache, hàng đợi (queue), session |
| **MinIO** | Lưu trữ file/object (thay thế S3, self-hosted) |
| **Docker / Docker Compose** | Đóng gói và chạy toàn bộ stack |

> Nếu bạn mới join, việc đầu tiên nên làm là dựng môi trường local bằng Docker Compose (xem mục Deploy bên dưới) để chạy thử toàn bộ stack trên máy mình.

---

## 2. Cơ chế chống "bịa thông tin" (Anti-Hallucination)

Arkon không để AI tự do trả lời theo trí nhớ của model. Thay vào đó, hệ thống áp dụng kiến trúc **RAG (Retrieval-Augmented Generation)**: mọi câu trả lời đều phải bắt nguồn từ dữ liệu thật đã được nạp vào hệ thống (context), thay vì để mô hình "đoán" hoặc "bịa" dựa trên kiến thức chung.

### Quy trình xử lý một câu hỏi

```
Câu hỏi người dùng
        │
        ▼
1. Embedding câu hỏi (chuyển thành vector)
        │
        ▼
2. So sánh độ tương đồng (cosine similarity / L2)
   với các vector context đã lưu trong pgvector
        │
        ▼
3. Lọc theo ngưỡng (threshold) similarity
        │
        ├── Có context đủ tương đồng ──► 4a. Đưa context vào prompt,
        │                                    yêu cầu model CHỈ trả lời
        │                                    dựa trên context đó
        │
        └── Không có context đủ tương đồng ──► 4b. Trả lời "không tìm thấy
                                                     thông tin liên quan"
                                                     thay vì tự bịa
```

### Các điểm kỹ thuật cần nhớ

- **Embedding**: mỗi tài liệu/đoạn văn bản nạp vào hệ thống được chuyển thành vector và lưu trong PostgreSQL nhờ extension `pgvector`.
- **Similarity search**: khi có câu hỏi mới, hệ thống embed câu hỏi rồi dùng truy vấn vector (`<->` hoặc `<=>` trong pgvector) để tìm các đoạn context gần nhất.
- **Ngưỡng similarity (threshold)**: đây là phần quan trọng nhất để tránh bịa — nếu điểm tương đồng cao nhất vẫn thấp hơn ngưỡng cấu hình, hệ thống **không** đưa context "gượng ép" vào, mà trả lời rõ ràng là không có dữ liệu phù hợp.
- **System prompt ràng buộc**: prompt gửi cho model luôn có chỉ dẫn dạng "chỉ được trả lời dựa trên context được cung cấp, nếu context không đủ thông tin thì nói rõ là không biết, không được suy diễn thêm".
- **Trích dẫn nguồn (nếu áp dụng)**: câu trả lời nên gắn kèm nguồn context đã dùng, giúp người dùng verify lại thay vì tin mù quáng vào output.

> Khi bạn thêm tính năng mới liên quan đến AI trả lời, hãy luôn tuân theo nguyên tắc: **retrieve trước, generate sau, và không generate nếu retrieve không đủ tin cậy.**

---

## 3. Chạy dự án (local)

**Toàn bộ hướng dẫn chạy dự án ở môi trường local nằm trong file [`CHAY-DU-AN.md`](./CHAY-DU-AN.md).**

Quy tắc chung (áp dụng tương tự như với `deploy.md`):

- Trước khi chạy dự án lần đầu (hoặc sau khi pull code mới), **luôn mở `CHAY-DU-AN.md` trước** — không tự nhớ lệnh theo trí nhớ, vì cấu hình môi trường, biến `.env`, thứ tự khởi động service (Postgres/pgvector, Redis, MinIO...) có thể đã thay đổi.
- Có 2 cách dùng file này:
  1. **Đọc trực tiếp** và copy từng lệnh ra terminal để chạy tuần tự (ví dụ: dựng container bằng Docker Compose, chạy migration, tạo extension `pgvector`, seed dữ liệu mẫu...).
  2. **Dùng AI** (Claude, ChatGPT...): dán nội dung `CHAY-DU-AN.md` vào, mô tả tình huống của bạn (ví dụ: "máy mình chưa có Docker", "chỉ cần chạy lại service API, các service khác đã chạy sẵn"...), nhờ AI trích ra đúng các lệnh cần chạy theo thứ tự, sau đó copy lệnh AI đưa ra để chạy.
- Nếu gặp lỗi khi chạy dự án mà chưa có trong `CHAY-DU-AN.md` (ví dụ lỗi kết nối do port bị chiếm, thiếu biến môi trường...), hãy bổ sung lại cách xử lý vào file đó sau khi fix xong, để người sau không phải debug lại từ đầu.
- Lưu ý: `CHAY-DU-AN.md` dùng để **chạy dự án ở môi trường local/dev**; còn `deploy.md` dùng để **deploy lên staging/production**. Hai file phục vụ hai mục đích khác nhau, không dùng lẫn lộn.

---

## 4. Deploy

**Toàn bộ hướng dẫn deploy nằm trong file [`deploy.md`](./deploy.md).**

Quy tắc chung:

- Mỗi lần cần deploy (local, staging, production...), **luôn mở `deploy.md` trước** — không tự nhớ lệnh theo trí nhớ, vì cấu hình/thứ tự bước có thể đã thay đổi.
- Có 2 cách dùng file này:
  1. **Đọc trực tiếp** và copy từng lệnh ra terminal để chạy tuần tự.
  2. **Dùng AI** (Claude, ChatGPT...): dán nội dung `deploy.md` vào, nhờ AI tóm tắt lại đúng các câu lệnh cần chạy theo đúng thứ tự cho tình huống cụ thể của bạn (ví dụ: "chỉ rebuild container Postgres", "teardown toàn bộ rồi build lại từ đầu"...), sau đó copy lệnh AI đưa ra để chạy.
- Nếu trong lúc deploy gặp lỗi không có trong `deploy.md`, hãy bổ sung lại vào file đó sau khi xử lý xong, để người sau không phải debug lại từ đầu.

---

## 5. Ghi chú cho người mới

- Đọc kỹ mục 2 trước khi động vào bất kỳ logic liên quan đến truy vấn AI/RAG.
- Không hardcode câu trả lời hay bỏ qua bước kiểm tra threshold similarity — đây là lớp bảo vệ chính chống bịa thông tin.
- Mọi thắc mắc về pipeline embedding/similarity, hỏi lại người phụ trách phần AI/RAG của dự án trước khi thay đổi.
