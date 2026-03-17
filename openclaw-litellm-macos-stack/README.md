# OpenClaw + LiteLLM trên macOS (Docker Compose)

Stack này ghép **OpenClaw Gateway** với **LiteLLM Proxy** và **Postgres cho LiteLLM**.
Nó được thiết kế cho macOS, nhưng Compose này cũng chạy được trên Linux nếu bạn giữ nguyên cấu trúc thư mục.

## Cấu trúc

- `docker-compose.yml` — stack hoàn chỉnh
- `.env.example` — biến môi trường mẫu
- `config/openclaw.json` — OpenClaw cấu hình provider LiteLLM + Telegram
- `config/litellm-config.yaml` — LiteLLM cấu hình OpenAI + Anthropic + MiniMax
- `scripts/discover-danglamgiau-models.sh` — gọi trực tiếp `GET /v1/models` của danglamgiau để chốt model ids trước khi bật alias
- `config/cliproxyapi-config.yaml` — CLIProxyAPI host config được render từ `.env` tại máy local và không nên commit
- `scripts/generate-litellm-virtual-key.sh` — tạo virtual key riêng cho OpenClaw
- `scripts/render-litellm-config.py` — render LiteLLM config từ `.env`, hỗ trợ nhiều `OPENAI_API_KEY_*`
- `scripts/apply-provider-config.sh` — render lại config và restart stack sau khi đổi provider keys
- `scripts/render-cliproxy-config.py` — render CLIProxyAPI config host-side từ `.env`
- `scripts/sync-cliproxy-codex-auth.py` — import session Codex từ `~/.codex/auth.json` sang auth-dir của CLIProxyAPI
- `scripts/apply-cliproxyapi.sh` — cài `cliproxyapi` trên macOS, sync auth và nối LiteLLM -> CLIProxyAPI
- `scripts/test-model.sh` — smoke test 1 lệnh cho GPT, MiniMax, CLIProxyAPI và Telegram end-to-end
- `data/*` — thư mục bind mount local cho OpenClaw / Postgres

## 1) Chuẩn bị

```bash
cp .env.example .env
cp config/openclaw.json data/openclaw/config/openclaw.json
```

Sau đó sửa `.env`:
- điền `OPENAI_API_KEY`
- nếu có nhiều OpenAI key, điền thêm `OPENAI_API_KEY_2`, `OPENAI_API_KEY_3`, ...
- điền `ANTHROPIC_API_KEY`
- nếu dùng MiniMax, điền `MINIMAX_API_KEY` và giữ `MINIMAX_API_BASE=https://api.minimax.io/v1`
- nếu muốn bật `danglamgiau.com` như một upstream marketplace OpenAI-compatible phía sau LiteLLM, điền:
  - `DANGLAMGIAU_ENABLE=1`
  - `DANGLAMGIAU_API_KEY`
  - tùy chọn giữ `DANGLAMGIAU_API_BASE=https://danglamgiau.com/v1`
  - tùy chọn chỉnh `DANGLAMGIAU_MODELS=gpt-5,gpt-5-codex,gpt-5.1-codex-max`
  - khuyến nghị chạy `./scripts/discover-danglamgiau-models.sh` trước để xem model ids thực tế từ `/v1/models`
- nếu muốn bật bridge OAuth/subscription qua CLIProxyAPI, điền:
  - `CLIPROXY_ENABLE=1`
  - `CLIPROXY_API_KEY`
  - `CLIPROXY_API_BASE=http://host.docker.internal:8317/v1`
  - tùy chọn `CLIPROXY_MODELS=gpt-5-codex,gpt-5.1-codex,gpt-5.1-codex-max`
  - nếu muốn bật web management/login local, điền thêm `CLIPROXY_MANAGEMENT_KEY`
- điền `TELEGRAM_BOT_TOKEN`
- đổi `POSTGRES_PASSWORD`
- đổi `LITELLM_MASTER_KEY`
- đổi `LITELLM_SALT_KEY`
- tạm thời để `LITELLM_API_KEY` bằng `LITELLM_MASTER_KEY` cho lần boot đầu tiên

## 2) Chạy stack

```bash
docker compose up -d
docker compose ps
```

## 3) Kiểm tra health

OpenClaw:
```bash
curl -fsS http://127.0.0.1:18789/healthz
curl -fsS http://127.0.0.1:18789/readyz
```

LiteLLM:
```bash
curl -fsS http://127.0.0.1:8001/health/liveliness
curl -fsS http://127.0.0.1:8001/health/readiness
```

## 4) Tạo virtual key riêng cho OpenClaw

Khi stack đã lên ổn, chạy:

```bash
chmod +x scripts/generate-litellm-virtual-key.sh
./scripts/generate-litellm-virtual-key.sh
```

Lấy key mới trả về, thay vào `.env` ở `LITELLM_API_KEY=...`, rồi restart OpenClaw:

```bash
docker compose up -d --force-recreate openclaw-gateway openclaw-cli
```

## 5) Telegram pairing

BotFather:
- chat với `@BotFather`
- chạy `/newbot`
- lấy token và dán vào `.env`

Sau khi gateway chạy:
```bash
docker compose run --rm openclaw-cli pairing list telegram
docker compose run --rm openclaw-cli pairing approve telegram <CODE>
```

Pairing code sẽ xuất hiện khi bạn DM bot trên Telegram lần đầu.

## 6) Chọn model mặc định

Stack này tự chọn model mặc định:
- `litellm/MiniMax-M2.5` nếu có `MINIMAX_API_KEY`
- `litellm/dlg-gpt-5-codex` nếu bạn chủ động đổi sang alias danglamgiau sau khi bật provider này
- `litellm/gpt-5.1-codex` nếu có OpenAI key nhưng không có MiniMax
- `litellm/claude-opus-4-6` nếu không có MiniMax/OpenAI

Nếu đã bật CLIProxyAPI, LiteLLM sẽ thêm các alias:
- `codex-oauth-gpt-5-codex`
- `codex-oauth-gpt-5-1-codex`
- `codex-oauth-gpt-5-1-codex-max`

Muốn đổi sang GPT:
```bash
docker compose run --rm openclaw-cli models set litellm/gpt-5.1-codex
```

Muốn đổi sang Codex OAuth qua CLIProxyAPI:
```bash
docker compose run --rm openclaw-cli models set litellm/codex-oauth-gpt-5-1-codex
```

Muốn đổi sang danglamgiau sau khi đã thêm key:
```bash
docker compose run --rm openclaw-cli models set litellm/dlg-gpt-5-codex
```

## 7) Lưu ý vận hành

- Nên pin `OPENCLAW_IMAGE` và `LITELLM_IMAGE` sang tag hoặc digest cố định trước khi dùng lâu dài.
- Trên macOS, host ports đang bind vào `127.0.0.1` để giảm bề mặt lộ cổng.
- OpenClaw gọi LiteLLM nội bộ qua DNS service `litellm` trên network Compose.
- `openclaw-cli` dùng `network_mode: service:openclaw-gateway` để bám theo flow Compose chính thức của OpenClaw.
- Sau khi thêm hoặc đổi nhiều `OPENAI_API_KEY_*`, chạy `./scripts/apply-provider-config.sh` để render lại `config/litellm-config.yaml` và restart `litellm + openclaw-gateway`.
- Sau khi thêm hoặc đổi `DANGLAMGIAU_*`, cũng dùng cùng lệnh `./scripts/apply-provider-config.sh`.
- Nếu muốn bật hoặc cập nhật bridge `LiteLLM -> CLIProxyAPI -> Codex OAuth`, chạy `./scripts/apply-cliproxyapi.sh`.
- Khi `CLIPROXY_MANAGEMENT_KEY` có giá trị, web management của CLIProxyAPI sẽ mở local tại `http://127.0.0.1:8317/management.html`.
- Management UI nên giữ `localhost-only`; stack này đang để `allow-remote: false`.

## 8) Gỡ stack

```bash
docker compose down
```

Xóa cả dữ liệu Postgres/OpenClaw:
```bash
rm -rf data/postgres data/openclaw
```

## 9) Smoke test

Sau khi stack đã pair Telegram xong, chạy:

```bash
chmod +x scripts/test-model.sh
./scripts/test-model.sh
```

Script sẽ:
- test GPT qua LiteLLM
- test MiniMax qua LiteLLM, kèm `reasoning_effort` để xác nhận `drop_params` đang hoạt động
- test danglamgiau qua LiteLLM nếu đã bật `DANGLAMGIAU_ENABLE`
- test CLIProxyAPI/Codex OAuth qua LiteLLM nếu đã bật `CLIPROXY_ENABLE`
- test Telegram end-to-end bằng `openclaw agent --deliver`

Ghi chú:
- Nếu chưa pair Telegram, set `TELEGRAM_TARGET=<chat_id>` hoặc để script tự lấy user đầu tiên từ `telegram-allowFrom.json`
- Có thể bỏ qua tạm một phần bằng `SKIP_GPT=1`, `SKIP_MINIMAX=1`, `SKIP_DANGLAMGIAU=1`, `SKIP_CLIPROXY=1`, hoặc `SKIP_TELEGRAM=1`
