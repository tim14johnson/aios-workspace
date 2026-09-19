# AiOS Overnight Queue — Runbook

Copy-paste steps for every scenario. No memory required.

---

## Every night — Start the queue

**Step 1 — Open Terminal and paste this:**
```
cd "/Volumes/AiOS Repository/code" && ./tools/overnight-queue.sh
```

That's it. You'll see servers starting, then each brief processing in order.
When everything is done, you'll get a macOS notification.

---

## Every morning — Check results

**Step 1 — Open Terminal and paste this to see the summary:**
```
cat /tmp/aios-overnight/queue.log | grep -E "━━━|PASS|FAIL|SKIP|complete"
```

**Step 2 — Read a specific brief's review:**
```
open /tmp/aios-overnight/
```
That opens Finder. Each brief gets its own folder — open it and read `review.md`.

**Step 3 — Bring Xcode / Claude up and run the gate on anything marked PASS.**

---

## Add a brief to tonight's queue

**Step 1 — Open the queue file:**
```
open -a TextEdit "/Volumes/AiOS Repository/code/tools/overnight-queue.md"
```

**Step 2 — Add a line in the `## Queue` section:**
```
- [ ] /tmp/aios-overnight/your-brief-name.md | /Volumes/AiOS Repository/code
```

Change `your-brief-name.md` to the actual brief path.
Change the path after `|` to the target workspace if it's not the main code repo.
Save the file and close TextEdit.

The queue runner skips any line starting with `- [x]` (already done)
and processes every `- [ ]` line in order, top to bottom.

---

## Remove a brief from the queue (before it runs)

Open the queue file (Step 1 above), delete the line or change `[ ]` to `[-]`.

---

## One-time setup — Download models

Run each block separately. The internal models are priority (used every night).
The external library models are large and optional — do them when you have time.

**Internal — Qwen2.5 Coder 32B (overnight coder, ~18 GB):**
```
hf download mlx-community/Qwen2.5-Coder-32B-Instruct-4bit --local-dir ~/Models/Qwen2.5-Coder-32b
```

**Internal — Devstral reviewer (~14 GB):**
```
hf download mlx-community/Devstral-Small-2505-4bit --local-dir ~/Models/Devstral
```

**External library — Qwen3 72B for large jobs or second opinion (~40 GB):**
```
mkdir -p "/Volumes/AiOS Repository/Model-Library/Qwen3-72b_40g"
hf download mlx-community/Qwen3-72B-4bit --local-dir "/Volumes/AiOS Repository/Model-Library/Qwen3-72b_40g"
```

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
mv "/Volumes/AiOS Repository/mlx-models/mlx-community/Qwen3.8-27B-4bit" \
   "/Volumes/AiOS Repository/Model-Library/Qwen3.8-27b_18g_moe"
```

Move Devstral from the HF cache to internal (once the `hf download` above is done, skip this):
```
mv "/Volumes/AiOS Repository/mlx-models/mlx-community/Devstral-Small-2505-4bit" \
   ~/Models/Devstral
```

---

## Troubleshooting

**"Queue is empty"** — open the queue file, make sure the lines start with `- [ ]` not `- [x]`.

**"Coder server exited early"** — check the log:
```
cat /tmp/aios-overnight/coder-server.log | tail -20
```

**"Coder failed / timed out"** — the brief is probably too long. Split it into two shorter briefs and add both to the queue.

**Results folder is gone** — `/tmp/` is cleared on reboot. Results only survive until next restart. If you want to keep a result, copy the review.md somewhere before rebooting:
```
cp /tmp/aios-overnight/your-brief-name/review.md ~/Desktop/
```

**"hf command not found"** — run this once:
```
pip install huggingface_hub[cli]
```
