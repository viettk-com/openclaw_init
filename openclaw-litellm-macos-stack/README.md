# OpenClaw + LiteLLM trên macOS (Docker Compose)

Stack này ghép **OpenClaw Gateway** với **LiteLLM Proxy** và **Postgres cho LiteLLM**.
Nó được thiết kế cho macOS, nhưng Compose này cũng chạy được trên Linux nếu bạn giữ nguyên cấu trúc thư mục.

## Cấu trúc

- `docker-compose.yml` — stack hoàn chỉnh
- `.env.example` — biến môi trường mẫu
- `config/openclaw.json` — OpenClaw cấu hình provider LiteLLM + Telegram
- `config/litellm-config.yaml` — LiteLLM cấu hình OpenAI + Anthropic + MiniMax
- `scripts/discover-danglamgiau-models.sh` — gọi trực tiếp `GET /v1/models` của danglamgiau để chốt model ids trước khi bật alias
- `scripts/discover-claudible-models.sh` — gọi trực tiếp `GET /v1/models` của Claudible để chốt catalog Claude trước khi bật alias
- `config/cliproxyapi-config.yaml` — CLIProxyAPI host config được render từ `.env` tại máy local và không nên commit
- `scripts/generate-litellm-virtual-key.sh` — tạo virtual key riêng cho OpenClaw
- `scripts/render-litellm-config.py` — render LiteLLM config từ `.env`, hỗ trợ nhiều `OPENAI_API_KEY_*`
- `scripts/apply-provider-config.sh` — render lại config và restart stack sau khi đổi provider keys
- `scripts/render-cliproxy-config.py` — render CLIProxyAPI config host-side từ `.env`
- `scripts/sync-cliproxy-codex-auth.py` — import session Codex từ `~/.codex/auth.json` sang auth-dir của CLIProxyAPI
- `scripts/apply-cliproxyapi.sh` — cài `cliproxyapi` trên macOS, sync auth và nối LiteLLM -> CLIProxyAPI
- `scripts/apply-claude-code.sh` — build lại image OpenClaw có kèm Claude Code CLI và verify binary trong container
- `scripts/claude-code.sh` — chạy lệnh `claude ...` trực tiếp bên trong gateway container
- `scripts/test-model.sh` — smoke test 1 lệnh cho GPT, MiniMax, CLIProxyAPI và Telegram end-to-end
- `docker-compose.voice.yml` — overlay để chạy local STT + Telegram voice bot riêng
- `voicebot-python/` — bot Telegram trung gian cho voice commands tiếng Việt
- `scripts/download-whisper-model.sh` — tải model `whisper.cpp` vào `data/whisper/models`
- `scripts/apply-voice-control.sh` — bật endpoint cần thiết của OpenClaw và dựng stack voice
- `scripts/test-voice-control.sh` — self-test parser/bot + kiểm tra wiring compose/config cho voice stack
- `data/*` — thư mục bind mount local cho OpenClaw / Postgres

## 1) Chuẩn bị

```bash
cp .env.example .env
cp config/openclaw.json data/openclaw/config/openclaw.json
```

Sau đó sửa `.env`:
- tùy chọn giữ `CLAUDE_CODE_TARGET=stable` để image OpenClaw cài đúng channel Claude Code ổn định
- điền `OPENAI_API_KEY`
- nếu có nhiều OpenAI key, điền thêm `OPENAI_API_KEY_2`, `OPENAI_API_KEY_3`, ...
- điền `ANTHROPIC_API_KEY`
- nếu dùng MiniMax, điền `MINIMAX_API_KEY` và giữ `MINIMAX_API_BASE=https://api.minimax.io/v1`
- nếu muốn bật `danglamgiau.com` như một upstream marketplace OpenAI-compatible phía sau LiteLLM, điền:
  - `DANGLAMGIAU_ENABLE=1`
  - `DANGLAMGIAU_API_KEY`
  - tùy chọn giữ `DANGLAMGIAU_API_BASE=https://danglamgiau.com/v1`
  - tùy chọn giữ `DANGLAMGIAU_USER_AGENT` như mặc định trong `.env.example`; upstream này hiện chặn Python fingerprint mặc định nếu bỏ header này
  - tùy chọn chỉnh `DANGLAMGIAU_MODELS=gpt-5,gpt-5-codex,deepseek-3-2,claude-sonnet-4-6,claude-sonnet-4-6-thinking,claude-opus-4-6,claude-opus-4-6-thinking`
  - khuyến nghị chạy `./scripts/discover-danglamgiau-models.sh` trước để xem model ids thực tế từ `/v1/models`
- nếu muốn bật `Claudible` như một upstream Claude-focused phía sau LiteLLM, điền:
  - `CLAUDIBLE_ENABLE=1`
  - `CLAUDIBLE_API_KEY`
  - tùy chọn giữ `CLAUDIBLE_API_BASE=https://claudible.io/v1`
  - tùy chọn giữ `CLAUDIBLE_USER_AGENT` như mặc định trong `.env.example`; upstream này hiện cũng chặn Python fingerprint mặc định nếu bỏ header này
  - tùy chọn giữ `CLAUDIBLE_MODELS=claude-sonnet-4.6,claude-opus-4.6,claude-haiku-4.5`
  - khuyến nghị chạy `./scripts/discover-claudible-models.sh` trước để xem catalog thực tế từ `/v1/models`
- nếu muốn bật bridge OAuth/subscription qua CLIProxyAPI, điền:
  - `CLIPROXY_ENABLE=1`
  - `CLIPROXY_API_KEY`
  - `CLIPROXY_API_BASE=http://host.docker.internal:8317/v1`
  - tùy chọn `CLIPROXY_MODELS=gpt-5.4,gpt-5.3-codex`
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

Stack này đang đặt mặc định:
- `litellm/gpt-5.4`

Trong cấu hình hiện tại, alias `gpt-5.4` được ưu tiên map sang `CLIProxyAPI / Codex OAuth`, không còn đi vào OpenAI direct alias mặc định.

Nếu đã bật CLIProxyAPI, LiteLLM sẽ thêm các alias:
- `gpt-5.4`
- `gpt-5.3-codex`
- và alias debug tương ứng `codex-oauth-gpt-5-4`, `codex-oauth-gpt-5-3-codex`

Nếu đã bật Claudible, LiteLLM sẽ thêm các alias:
- `claudible-claude-sonnet-4-6`
- `claudible-claude-opus-4-6`
- `claudible-claude-haiku-4-5`

Muốn đổi sang GPT:
```bash
docker compose run --rm openclaw-cli models set litellm/gpt-5.4
```

Muốn đổi sang GPT-5.3 Codex qua CLIProxyAPI:
```bash
docker compose run --rm openclaw-cli models set litellm/gpt-5.3-codex
```

Muốn đổi sang danglamgiau sau khi đã thêm key:
```bash
docker compose run --rm openclaw-cli models set litellm/dlg-gpt-5-codex
```

Muốn đổi sang Claudible sau khi đã thêm key:
```bash
docker compose run --rm openclaw-cli models set litellm/claudible-claude-sonnet-4-6
```

## 7) Lưu ý vận hành

- Nên pin `OPENCLAW_IMAGE` và `LITELLM_IMAGE` sang tag hoặc digest cố định trước khi dùng lâu dài.
- Trên macOS, host ports đang bind vào `127.0.0.1` để giảm bề mặt lộ cổng.
- OpenClaw gọi LiteLLM nội bộ qua DNS service `litellm` trên network Compose.
- `openclaw-cli` dùng `network_mode: service:openclaw-gateway` để bám theo flow Compose chính thức của OpenClaw.
- Sau khi thêm hoặc đổi nhiều `OPENAI_API_KEY_*`, chạy `./scripts/apply-provider-config.sh` để render lại `config/litellm-config.yaml` và restart `litellm + openclaw-gateway`.
- Sau khi thêm hoặc đổi `DANGLAMGIAU_*`, cũng dùng cùng lệnh `./scripts/apply-provider-config.sh`.
- Sau khi thêm hoặc đổi `CLAUDIBLE_*`, cũng dùng cùng lệnh `./scripts/apply-provider-config.sh`.
- Nếu muốn bật hoặc cập nhật bridge `LiteLLM -> CLIProxyAPI -> Codex OAuth`, chạy `./scripts/apply-cliproxyapi.sh`.
- Nếu muốn build/cập nhật `Claude Code CLI` trong gateway container, chạy `./scripts/apply-claude-code.sh`.
- Khi `CLIPROXY_MANAGEMENT_KEY` có giá trị, web management của CLIProxyAPI sẽ mở local tại `http://127.0.0.1:8317/management.html`.
- Management UI nên giữ `localhost-only`; stack này đang để `allow-remote: false`.
- Sau khi bật một họ model alias mới như `dlg-*`, `claudible-*`, `gpt-5.4`, `gpt-5.3-codex`, hoặc `codex-oauth-*`, nên chạy lại `./scripts/generate-litellm-virtual-key.sh` và thay `LITELLM_API_KEY` trong `.env` nếu OpenClaw cần gọi các alias mới đó.
- Bản hiện tại của `scripts/generate-litellm-virtual-key.sh` gọi local LiteLLM bằng Python thay vì `curl`, vì route `/key/generate` trên máy này thỉnh thoảng trả `empty reply` với `curl`.

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
- test Claudible qua LiteLLM nếu đã bật `CLAUDIBLE_ENABLE`
- test CLIProxyAPI/Codex OAuth qua LiteLLM nếu đã bật `CLIPROXY_ENABLE`
- test Telegram end-to-end bằng `openclaw agent --deliver`

Ghi chú:
- Nếu chưa pair Telegram, set `TELEGRAM_TARGET=<chat_id>` hoặc để script tự lấy user đầu tiên từ `telegram-allowFrom.json`
- Có thể bỏ qua tạm một phần bằng `SKIP_GPT=1`, `SKIP_MINIMAX=1`, `SKIP_DANGLAMGIAU=1`, `SKIP_CLAUDIBLE=1`, `SKIP_CLIPROXY=1`, hoặc `SKIP_TELEGRAM=1`
- Nếu muốn test chi tiết matrix provider, bật `DANGLAMGIAU_TEST_MATRIX=1` hoặc `CLAUDIBLE_TEST_MATRIX=1`

## 10) Trạng thái Provider Hiện Tại

### DangLamGiau

- Đã bật và chạy được qua LiteLLM.
- `DeepSeek 3.2`, `Claude Sonnet 4.6`, `Claude Sonnet 4.6 Thinking`, và `Claude Opus 4.6` đang pass.
- `Claude Sonnet 4.6 Thinking` có `reasoning_content`, nên coi như có thinking thật ở mức runtime.
- `Claude Opus 4.6 Thinking` hiện có trong catalog nhưng upstream đang trả `HTTP 200` với body rỗng; hiện không dùng làm primary.

### Claudible

- Đã bật và chạy được qua LiteLLM.
- Các model catalog hiện tại: `claude-sonnet-4.6`, `claude-opus-4.6`, `claude-haiku-4.5`.
- Cả ba model đều pass qua LiteLLM.
- Hiện chưa thấy `thinking` riêng: docs vendor đánh dấu `reasoning: false`, `/v1/models` không trả model `thinking`, và runtime hiện không trả `reasoning_content`.

## 11) CLI / VS Code / Claude Code: Trạng Thái Hiện Tại

### Đang chạy được ngay

- `OpenClaw CLI` của chính stack này đang chạy được qua service `openclaw-cli`.
- Binary `openclaw` cũng có sẵn trong container gateway.
- `openclaw acp` cũng có sẵn, nghĩa là upstream bridge ACP của OpenClaw có mặt trong runtime hiện tại.
- `Claude Code CLI` hiện đã được bake vào image `openclaw-browser-local` và có symlink tuyệt đối tại `/usr/local/bin/claude`.
- Vì `claude` đã có trên `PATH`, OpenClaw có thể dùng built-in backend mặc định cho `claude-cli/sonnet` hoặc `claude-cli/opus` mà không cần thêm key cấu hình mới.

### Còn cần làm một lần sau khi boot stack

- Chạy `./scripts/apply-claude-code.sh` sau khi đã có `.env` thật để rebuild/recreate gateway bằng image mới.
- Chạy `./scripts/claude-code.sh auth login` một lần để đăng nhập Claude Code ngay trong container.
- Sau khi login xong, có thể kiểm tra bằng `./scripts/claude-code.sh auth status`.

### Kết luận thực dụng

- `CLI`: `Claude Code CLI` đã bật theo đường built-in backend mặc định, không còn là trạng thái “chưa cấu hình”.
- `VS Code`: upstream có đường ACP, nhưng stack hiện tại chưa cấu hình bridge/extension để dùng với VS Code.
- `Claude Code`: dùng được trong stack này sau khi login, với model ids thực dụng là `claude-cli/sonnet` và `claude-cli/opus`.

## 12) Cách dùng Claude Code trong OpenClaw

Build/rebuild image có Claude Code:
```bash
./scripts/apply-claude-code.sh
```

Đăng nhập Claude Code ngay trong gateway container:
```bash
./scripts/claude-code.sh auth login
./scripts/claude-code.sh auth status
```

Chuyển model mặc định của OpenClaw sang Claude Code:
```bash
docker compose run --rm openclaw-cli models set claude-cli/opus
docker compose run --rm openclaw-cli models set claude-cli/sonnet
```

Ghi chú vận hành:
- Auth/session của Claude Code được giữ trong `data/openclaw/claude`, nên không mất sau mỗi lần restart container.

## 13) Voice control qua Telegram (MVP theo hướng bot trung gian)

Stack này đã có sẵn một đường triển khai thực dụng cho voice control tiếng Việt:
- một bot Telegram riêng để nhận voice notes
- `whisper.cpp` chạy local trong Docker để STT
- gọi OpenClaw qua HTTP nội bộ trong docker network

Thiết kế này tránh phụ thuộc vào việc transcript phải tự ra đúng dạng slash command. OpenClaw gốc vẫn giữ nguyên bot Telegram hiện có cho chat thường; voice control dùng bot token riêng để không giành cùng một luồng updates.

### Thành phần mới

- `docker-compose.voice.yml`
- `voicebot-python/bot.py`
- `scripts/download-whisper-model.sh`
- `scripts/apply-voice-control.sh`
- `scripts/test-voice-control.sh`

### Biến môi trường cần thêm

Trong `.env`, điền thêm:
- `VOICEBOT_TELEGRAM_BOT_TOKEN`
- `VOICEBOT_TELEGRAM_ALLOWLIST`
- tùy chọn chỉnh `VOICEBOT_OPENCLAW_AGENT_ID`, `VOICEBOT_OPENCLAW_MODEL`
- tùy chọn chỉnh `WHISPER_CPP_MODEL_NAME`, `WHISPER_CPP_MODEL_FILE`, `WHISPER_CPP_CPU_ARM_ARCH`

Ghi chú quan trọng:
- `VOICEBOT_TELEGRAM_BOT_TOKEN` phải là bot khác với `TELEGRAM_BOT_TOKEN`
- voice bot hiện dùng `/v1/chat/completions` nội bộ để relay các lệnh slash đã map, nên script apply sẽ tự bật endpoint này trong cả template config và runtime config

### Quickstart

1. Tải model `whisper.cpp`:

```bash
./scripts/download-whisper-model.sh
```

Script này sẽ build một image `whisper.cpp` local từ source trước khi tải model, nên tránh được tình huống image prebuilt trên registry không khớp platform của Docker daemon hiện tại.
Mặc định bot sẽ transcode voice note sang WAV trong container Python trước khi gửi sang `whisper-server`, nên container `whisper` không cần gánh thêm `ffmpeg`.

2. Bật OpenClaw voice HTTP surface nội bộ và dựng các service voice:

```bash
./scripts/apply-voice-control.sh
```

3. Chạy self-test tĩnh:

```bash
./scripts/test-voice-control.sh
```

4. Nhắn vào bot voice mới bằng text hoặc voice:
- `trạng thái`
- `trợ giúp`
- `chi phí`
- `token`
- `tôi là ai`
- `model hiện tại`

### Cách vận hành

- `whisper` chỉ expose cổng trong docker network, không bind ra Internet
- `voicebot-python` dùng long polling Telegram để đơn giản hoá deploy trên macOS Docker
- `x-openclaw-agent-id` và session key riêng theo từng Telegram user được gửi nội bộ sang OpenClaw để tách context

### Giới hạn MVP hiện tại

- Intent parser hiện là rule-based, ưu tiên an toàn hơn là tự do
- Nhóm lệnh mặc định đang tập trung vào read-only/low-risk operations
- Nếu muốn hỗ trợ “nói tự nhiên” cho các hành động mutation như đổi model, restart, reset session, nên thêm xác nhận 2 bước trước khi mở rộng parser
- Hướng tích hợp hiện tại là `OpenClaw CLI backend -> Claude Code CLI`, không phải `setup-token`.
- CLI backends của OpenClaw là text-oriented; nếu sau này cần luồng coding harness/IDE sâu hơn thì cân nhắc đi tiếp sang ACP.

Tham khảo chính thức:
- `CLI Backends`: https://docs.openclaw.ai/cli/cli-backends
- `ACP`: https://docs.openclaw.ai/cli/acp
- `ACP Clients`: https://docs.openclaw.ai/use/acp-clients
