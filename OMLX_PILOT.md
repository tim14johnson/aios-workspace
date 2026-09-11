# AiOS oMLX Pilot

## Purpose

Validate oMLX as a side-by-side Apple Silicon inference server before changing Xcode, OpenCode, Ollama, or downloading a dedicated coding model. This pilot uses the existing MLX Gemma model only to prove server startup, OpenAI-compatible API access, and repeated-context behavior.

## What this pilot does not change

- Ollama remains at `http://127.0.0.1:11434/v1` with its current models and configuration.
- `opencode.json` is not changed.
- Xcode ACP agent configuration is not changed.
- No new model is downloaded.
- No repository source code is changed by the benchmark.

## One-time local installation

oMLX 0.5.7 is installed on the Mac Studio. For future reinstalls, Homebrew must use Xcode 27 beta as the globally selected developer directory on this macOS 27 pre-release system:

```bash
sudo xcode-select --switch "/Applications/Xcode-beta-b4.app/Contents/Developer"
brew trust --formula jundot/omlx/omlx
brew install omlx
```

The formula trust and installation add the oMLX package plus its Homebrew dependencies. Do not use a broad `sudo chown` workaround for Homebrew permissions.

## Start the pilot

In Terminal window 1:

```bash
cd "/Volumes/AiOS Repository/code"
bash tools/start-omlx-pilot.sh
```

Expected endpoint:

```text
http://127.0.0.1:8000/v1
```

The launcher uses the existing MLX model directory:

```text
~/.lmstudio/models
```

It also enables a bounded KV cache for the benchmark:

```text
SSD cache: ~/.omlx/cache, capped at 20 GB
Hot in-memory cache: 8 GB
```

Override those locations or limits only for a targeted experiment by setting `OMLX_CACHE_DIR`, `OMLX_SSD_CACHE_MAX_SIZE`, or `OMLX_HOT_CACHE_MAX_SIZE` before the command. To use a different free port, set `OMLX_PORT` before the command. For example:

```bash
OMLX_PORT=18080 bash tools/start-omlx-pilot.sh
```

## Verify and benchmark

With the server still running, open Terminal window 2:

```bash
cd "/Volumes/AiOS Repository/code"
curl -s http://127.0.0.1:8000/v1/models
bash tools/benchmark-omlx-pilot.sh
```

If the `/v1/models` output uses a model ID different from the default, pass that ID explicitly:

```bash
bash tools/benchmark-omlx-pilot.sh 'model-id-from-v1-models'
```

A successful baseline has all of the following:

1. `/v1/models` lists the existing Gemma MLX model.
2. Both benchmark turns return a concise code-review response.
3. The repeated identical turn is faster than the first turn, indicating usable prompt/KV reuse.
4. Ollama remains reachable at `http://127.0.0.1:11434/v1`.

Gemma is a runtime validation model, not the final coding model. Do not judge the final coding workflow from its code-quality output.

## Stop and rollback

Press `Control-C` in Terminal window 1. This stops only the oMLX foreground server. It leaves Ollama, its models, Xcode, OpenCode, and repository configuration unchanged.

## Next decision

Only after this pilot passes should AiOS download and evaluate a dedicated MLX coding model, then add a separate oMLX provider to OpenCode for a controlled A/B comparison. Keep Ollama configured as the rollback path until the coding-model comparison is complete.

## Official references

- https://github.com/jundot/omlx
- https://omlx.ai/
