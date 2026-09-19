# AiOS Overnight Queue — Runbook

**You run one command at night. Claude handles everything else during the day.**

During a session, Claude writes briefs, saves them to `tools/briefs/`, and adds
them to `tools/overnight-queue.md` under today's date. You review and approve
the brief during the session — then kick off the queue when you're done for the night.

---

## Every night — Start the queue

**Paste this in Terminal:**
```
cd "/Volumes/AiOS Repository/code" && ./tools/overnight-queue.sh
```

You'll see servers starting, then each brief processing in order.
macOS notification when done. That's it.

---

## Every morning — Check results

**See the summary:**
```
cat /tmp/aios-overnight/queue.log | grep -E "━━━|PASS|FAIL|SKIP|complete"
```

**Open a specific brief's folder:**
```
open /tmp/aios-overnight/
```
Each brief gets its own folder — open it and read `review.md`.

**If a brief PASSed:** bring it into Xcode / Claude and run the final gate.
**If a brief FAILed:** the review will say why. Tell Claude in the next session.

---

## If you want to see what's queued for tonight

```
open -a TextEdit "/Volumes/AiOS Repository/code/tools/overnight-queue.md"
```

You'll see date sections with `- [ ]` items for tonight and `- [x]` items already done.
You don't need to edit this file — Claude manages it. But you can remove a line
if you change your mind about a brief before running the queue.

---

## Troubleshooting

**"No briefs queued for today"** — the queue file has no `- [ ]` items under today's date.
Either add a date section yourself or check with Claude in the next session.

**"Coder server exited early"** — check the log:
```
cat /tmp/aios-overnight/coder-server.log | tail -20
```

**"Coder failed / timed out"** — the brief is too long. Tell Claude; we'll split it.

**Results folder is gone** — `/tmp/` clears on reboot. Results only survive until
next restart. If you need to keep a result:
```
cp -r /tmp/aios-overnight/brief-name-folder ~/Desktop/
```

---

## One-time setup — Download models

Run when you have time. Internal models are priority (used every night).

**Internal — Qwen2.5 Coder 32B (overnight coder, ~18 GB):**
```
hf download mlx-community/Qwen2.5-Coder-32B-Instruct-4bit --local-dir ~/Models/Qwen2.5-Coder-32b
```

**Internal — Devstral reviewer (~14 GB):**
```
hf download mlx-community/Devstral-Small-2505-4bit --local-dir ~/Models/Devstral
```

**External library — Qwen3 32B for large jobs (~18 GB) — biggest dense Qwen3:**
```
mkdir -p "/Volumes/AiOS Repository/Model-Library/Qwen3-32b_18g"
hf download mlx-community/Qwen3-32B-4bit --local-dir "/Volumes/AiOS Repository/Model-Library/Qwen3-32b_18g"
```
Note: Qwen3 has no 72B model. Sizes go 32B (dense) → 235B MoE. The 235B (~120 GB) won't fit on this machine.

**External library — Qwen3 30B MoE for fast third opinion (~16 GB):**
```
mkdir -p "/Volumes/AiOS Repository/Model-Library/Qwen3-30b-A3B_16g_moe"
hf download mlx-community/Qwen3-30B-A3B-4bit --local-dir "/Volumes/AiOS Repository/Model-Library/Qwen3-30b-A3B_16g_moe"
```

---

## One-time setup — Organize the model library

Move Flash-Next from internal back to the external library:
```
mkdir -p "/Volumes/AiOS Repository/Model-Library/Flash-Next-180b_90g_moe"
mv ~/Models/UD-IQ4_XS "/Volumes/AiOS Repository/Model-Library/Flash-Next-180b_90g_moe/"
mv ~/Models/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf "/Volumes/AiOS Repository/Model-Library/Flash-Next-180b_90g_moe/"
```

Move Qwen 3.8 27B from the HF cache to the external library:
```
mkdir -p "/Volumes/AiOS Repository/Model-Library/Qwen3.8-27b_18g_moe"
mv "/Volumes/AiOS Repository/mlx-models/mlx-community/Qwen3.8-27B-4bit" "/Volumes/AiOS Repository/Model-Library/Qwen3.8-27b_18g_moe"
```

Move Devstral from the HF cache to internal (skip if you ran the download above):
```
mv "/Volumes/AiOS Repository/mlx-models/mlx-community/Devstral-Small-2505-4bit" ~/Models/Devstral
```
