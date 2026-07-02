# Nhật Ký Thực Hành & Tài Liệu Lab Day 26 — MCP/A2A & Agentic Routing

Tài liệu này ghi lại toàn bộ các bước thiết lập, thay đổi mã nguồn, lý do kỹ thuật đằng sau mỗi quyết định, cấu trúc hệ thống multi-agent, và các bước chạy thực tế để hoàn thành bài lab Day 26.

---

## 1. Tổng Quan Kiến Trúc Hệ Thống

Hệ thống bao gồm một **Orchestrator Agent** (đóng vai trò điều phối chính) giao tiếp với các thành phần chuyên biệt thông qua hai giao thức:
- **Model Context Protocol (MCP)**: Chuẩn hóa giao tiếp giữa Agent và các Tools chạy dưới dạng tiến trình con (stdio transport).
- **Agent-to-Agent (A2A)**: Chuẩn hóa giao tiếp giữa các Agents như các microservices độc lập chạy trên các cổng mạng khác nhau.

```
                  ┌─────────────────────────────────┐
                  │       ORCHESTRATOR AGENT        │
                  │  (ADK - http://localhost:8000)  │
                  └────────┬───────────────┬────────┘
                           │               │
                 A2A (HTTP)│               │MCP (stdio)
                           ▼               ▼
        ┌────────────────────────────────────┐  ┌──────────────────────┐
        │        SPECIALIST SERVERS          │  │  MCP TOOLS SERVER    │
        │ - search_agent    (Port 8001)      │  │  (research_tools)    │
        │ - database_agent  (Port 8002)      │  │                      │
        │ - synthesis_agent (Port 8003)      │  │ - search_documents   │
        └────────────────────────────────────┘  │ - sql_query          │
                                                │ - summarize_text     │
                                                │ - count_words [NEW]  │
                                                └──────────────────────┘
```

---

## 2. Các Bước Thực Hiện & Mã Nguồn Tích Hợp

### Bước 1: Mở rộng MCP Server với Tool `count_words` (Bài tập 1.2)
- **Mục đích**: Bổ sung thêm tính năng đếm từ trong văn bản cho MCP server, giúp orchestrator có thể gọi trực tiếp thông qua stdio transport.
- **Tập tin sửa đổi**: [research_tools_server.py](file:///Users/minhhai/workspace/ai/VinUni/Assignment/Day26-Track02-2A202600713-DangMinhHai/mcp_server/research_tools_server.py)
- **Mã nguồn tích hợp**:
  1. Thêm mô tả tool vào danh sách `all_tools` ở `@app.list_tools()`:
     ```python
     Tool(
         name="count_words",
         description="Đếm số lượng từ trong một văn bản.",
         inputSchema={
             "type": "object",
             "properties": {
                 "text": {"type": "string", "description": "Văn bản cần đếm từ"},
             },
             "required": ["text"],
         },
     )
     ```
  2. Thêm xử lý thực thi trong `@app.call_tool()`:
     ```python
     if name == "count_words":
         words_count = len(arguments["text"].split())
         return [TextContent(type="text", text=str(words_count))]
     ```
  3. Cho phép Orchestrator gọi tool bằng cách cập nhật chính sách bảo mật trong [policy.json](file:///Users/minhhai/workspace/ai/VinUni/Assignment/Day26-Track02-2A202600713-DangMinhHai/lab_utils/governance/policy.json):
     ```json
     "count_words": {
       "allowed": true,
       "data_classification": "internal"
     }
     ```

### Bước 2: Tích hợp Fallback Chain cho Semantic Router (Bài tập 3.1)
- **Mục đích**: Khi router chính không tìm thấy agent phù hợp (độ tương đồng dưới ngưỡng `threshold`), hệ thống sẽ đi dọc theo chuỗi fallback để chọn ra agent hoạt động đầu tiên, đảm bảo người dùng không bị kẹt.
- **Tập tin sửa đổi**: [semantic_router.py](file:///Users/minhhai/workspace/ai/VinUni/Assignment/Day26-Track02-2A202600713-DangMinhHai/lab_utils/semantic_router.py)
- **Mã nguồn tích hợp**:
  ```python
  def route_with_chain(self, request: str, chain: list[str]) -> str:
      """Thử route chính; nếu điểm < ngưỡng, đi theo chuỗi fallback."""
      candidates = self.route(request, top_k=1)
      if candidates and candidates[0][1] >= self.threshold:
          return candidates[0][0]

      import httpx
      agent_ports = {
          "search_agent": 8001,
          "database_agent": 8002,
          "synthesis_agent": 8003
      }
      for agent_name in chain:
          if agent_name == "orchestrator":
              return "orchestrator"
          port = agent_ports.get(agent_name)
          if port:
              try:
                  # Ping nhanh tới endpoint agent-card của agent để kiểm tra sức khỏe
                  r = httpx.get(f"http://localhost:{port}/.well-known/agent-card.json", timeout=0.1)
                  if r.status_code == 200:
                      return agent_name
              except Exception:
                  pass
      return "orchestrator"
  ```

### Bước 3: Áp Dụng Chính Sách Governance Chặn Từ Khóa `password` (Bài tập 5.2)
- **Mục đích**: Ngăn chặn rò rỉ hoặc tìm kiếm thông tin tài khoản nhạy cảm (`password`) từ kho tài liệu.
- **Tập tin sửa đổi**: [guard.py](file:///Users/minhhai/workspace/ai/VinUni/Assignment/Day26-Track02-2A202600713-DangMinhHai/lab_utils/governance/guard.py)
- **Mã nguồn tích hợp**:
  ```python
  if tool_name == "search_documents":
      query = str(arguments.get("query", ""))
      # ... check max_query_length ...
      if "password" in query.lower():
          decision = GovernanceDecision(
              verdict=GovernanceVerdict.DENY,
              reason="Truy vấn chứa từ khóa nhạy cảm bị cấm ('password')",
              actor_id=actor_id,
              connection_type=ConnectionType.MCP,
              resource=f"mcp:research-tools/{tool_name}",
          )
          self._log(decision, "mcp_tool_call", query, trace_id)
          return decision
  ```

---

## 3. Screenshot ADK Web UI (Bằng chứng nộp bài)

Ảnh chụp từ **ADK Web** tại `http://localhost:8000` — bổ sung cho kết quả đã verify trong `day26_mcp_a2a_lab.ipynb` (cell 33, **5/5 ĐẠT**).

| Prompt | File | Nội dung quan sát |
|--------|------|-------------------|
| **W1** | [screenshots/adk_web_W1.png](screenshots/adk_web_W1.png) | Session `7f8a96cf-8f3f-43a0-80b9-d2e54ca00f40`: A2A `transfer_to_agent("search_agent")`, luồng `orchestrator -> search_agent`, và kết quả tìm kiếm multi-agent orchestration. |
| **W2** | [screenshots/adk_web_W2.png](screenshots/adk_web_W2.png) | Session `1635a33b-bb6a-4be3-a242-d47ad01d0486`: MCP `search_documents("MCP")`, `sql_query("SELECT * FROM agent_metrics")`, `summarize_text`, và tóm tắt ngắn từ dữ liệu agent metrics. |
| **W5** | [screenshots/adk_web_W5.png](screenshots/adk_web_W5.png) | Session `246e1fd2-73e2-4154-a436-3504a7c67da6`: prompt `DROP TABLE agent_metrics` bị chặn theo read-only policy; ADK Web trả lời không có quyền ghi/DDL và chỉ được thực hiện truy vấn SQL chỉ đọc. Verify guard trực tiếp: `deny Chỉ cho phép SELECT (read-only)`. |

### Cách chụp lại (nếu cần)

```bash
# Khởi động stack (nếu chưa chạy)
bash scripts/start_capstone.sh

# Chụp tự động W1, W2, W5
bash scripts/capture_adk_screenshots.sh
```

> **Lưu ý quota Gemini:** Free tier giới hạn request theo phút/ngày cho từng model. Nếu gặp `429 RESOURCE_EXHAUSTED` trên ADK Web, đợi quota reset hoặc dùng session đã chạy thành công nêu trong bảng trên.

---

## 4. Hành Động Yêu Cầu Học Viên Xử Lý

> [!IMPORTANT]
> **Điền GOOGLE_API_KEY**:
> Do các mô hình Gemini chạy trong bài lab yêu cầu khóa API, bạn cần điền khóa API của bạn vào file `.env` ở thư mục gốc của lab.
>
> 1. Mở file [.env](file:///Users/minhhai/workspace/ai/VinUni/Assignment/Day26-Track02-2A202600713-DangMinhHai/.env)
> 2. Cập nhật dòng số 2:
>    ```bash
>    GOOGLE_API_KEY=AIzaSy... # Điền key thực tế của bạn vào đây
>    ```
> 3. Lưu file và báo lại cho tôi biết để bắt đầu khởi chạy toàn bộ A2A servers và hoàn thành các bài test còn lại.
