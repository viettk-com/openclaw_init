# OpenClaw + LiteLLM trên macOS (Docker Compose)

Stack này ghép **OpenClaw Gateway** với **LiteLLM Proxy** và **Postgres cho LiteLLM**.
Nó được thiết kế cho macOS, nhưng Compose này cũng chạy được trên Linux nếu bạn giữ nguyên cấu trúc thư mục.

## Cấu trúc

- `docker-compose.yml` — stack hoàn chỉnh
- `.env.example` — biến môi trường mẫu
- `config/openclaw.json` — OpenClaw cấu hình provider LiteLLM + Telegram
- `config/litellm-config.yaml` — LiteLLM cấu hình OpenAI + Anthropic + MiniMax
- `scripts/generate-litellm-virtual-key.sh` — tạo virtual key riêng cho OpenClaw
- `scripts/render-litellm-config.py` — render LiteLLM config từ `.env`, hỗ trợ nhiều `OPENAI_API_KEY_*`
- `scripts/apply-provider-config.sh` — render lại config và restart stack sau khi đổi provider keys
- `scripts/test-model.sh` — smoke test 1 lệnh cho GPT, MiniMax, và Telegram end-to-end
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
- `litellm/gpt-5.1-codex` nếu có OpenAI key nhưng không có MiniMax
- `litellm/claude-opus-4-6` nếu không có MiniMax/OpenAI

Muốn đổi sang GPT:
```bash
docker compose run --rm openclaw-cli models set litellm/gpt-5.1-codex
```

## 7) Lưu ý vận hành

- Nên pin `OPENCLAW_IMAGE` và `LITELLM_IMAGE` sang tag hoặc digest cố định trước khi dùng lâu dài.
- Trên macOS, host ports đang bind vào `127.0.0.1` để giảm bề mặt lộ cổng.
- OpenClaw gọi LiteLLM nội bộ qua DNS service `litellm` trên network Compose.
- `openclaw-cli` dùng `network_mode: service:openclaw-gateway` để bám theo flow Compose chính thức của OpenClaw.
- Sau khi thêm hoặc đổi nhiều `OPENAI_API_KEY_*`, chạy `./scripts/apply-provider-config.sh` để render lại `config/litellm-config.yaml` và restart `litellm + openclaw-gateway`.

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
- test Telegram end-to-end bằng `openclaw agent --deliver`

Ghi chú:
- Nếu chưa pair Telegram, set `TELEGRAM_TARGET=<chat_id>` hoặc để script tự lấy user đầu tiên từ `telegram-allowFrom.json`
- Có thể bỏ qua tạm một phần bằng `SKIP_GPT=1`, `SKIP_MINIMAX=1`, hoặc `SKIP_TELEGRAM=1`
