# AiOS oMLX Qwen3-Coder Evaluation

## Decision

Evaluate `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` as the first dedicated local coding model for AiOS. This is a controlled inference-runtime and coding-quality evaluation, not a change to the Xcode ACP or OpenCode workflow.

## Why this model

- It is an MLX 4-bit conversion of `Qwen/Qwen3-Coder-30B-A3B-Instruct`.
- The underlying model is a 30.5B-parameter mixture-of-experts model with approximately 3.3B active parameters per token, 128 experts, and 8 active experts.
- The upstream model is intended for agentic coding and tool use, with native 256K context support.
- The MLX download footprint is approximately 17.21 GB, which is appropriate for the M1 Max with 64 GB unified memory and leaves room for runtime memory plus cache.
- The 80B Qwen3-Coder-Next 4-bit alternative is approximately 45 GB and is deferred. It would leave too little practical headroom under the Mac's observed Metal memory limits while retaining a useful coding cache.

## Isolation design

```text
Existing Ollama coding models  -> port 11434 -> unchanged rollback path
Gemma oMLX cache pilot        -> port 8000  -> stop before coding-model test
Qwen3-Coder oMLX candidate    -> port 18080 -> separate evaluation endpoint
```

- Model weights: `/Volumes/AiOS Repository/models/omlx/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`
- Model source volume: external APFS SSD with approximately 3.6 TiB free.
- KV cache: `~/.omlx/cache-qwen3-coder-30b` on the internal SSD, capped at 20 GB.
- Hot in-memory cache: capped at 8 GB.
- oMLX memory guard: `balanced`.

Keeping model weights on the external SSD preserves internal capacity. Keeping the hot and SSD KV cache on the internal volume favors lower-latency repeated context.

## Download gate

The download is public and resumable, but it transfers approximately 17.21 GB and writes to the external AiOS volume. Do not run the downloader until explicitly approved.

```bash
cd "/Volumes/AiOS Repository/code"
bash tools/download-omlx-qwen3-coder-30b.sh
```

The downloader uses the Hugging Face CLI bundled inside the oMLX Homebrew package. It does not require installing another Python environment or altering Ollama.

## Startup gate

Stop the Gemma foreground server with `Control-C` before launching Qwen3-Coder, so only one oMLX model occupies unified memory.

```bash
cd "/Volumes/AiOS Repository/code"
bash tools/start-omlx-qwen3-coder-30b.sh
```

Expected endpoint:

```text
http://127.0.0.1:18080/v1
```

## Evaluation gates

### Runtime and cache

1. `GET /v1/models` lists Qwen3-Coder.
2. Two identical repository-grounded prompts complete successfully.
3. The repeated turn is materially faster than the first turn.
4. Ollama remains available at port 11434.

### Coding quality

1. Produce a small, bounded Swift change proposal from actual AiOSCore context.
2. Identify affected files, constraints, and focused tests without inventing project structure.
3. Produce a patch draft that passes static review before any source modification.
4. Compare the result with the existing Ollama `qwen3-coder:30b` path using the same context and rubric.

### Integration decision

Only after runtime and coding-quality gates pass should AiOS add an oMLX provider to `opencode.json`, and only as a separate local provider. Xcode ACP configuration remains unchanged through this evaluation.

## Rollback

Press `Control-C` in the candidate server Terminal. This stops only the oMLX Qwen3-Coder foreground process. Ollama, Xcode, OpenCode, and source repositories remain unchanged. The downloaded model can be retained for later evaluation or deleted manually from its external-volume directory.

## Sources

- Official Qwen model card: https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct
- MLX 4-bit model conversion: https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
- MLX model file listing: https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit/tree/main
- oMLX model and tool-calling support: https://github.com/jundot/omlx
