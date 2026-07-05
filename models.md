# Ollama Models

| Model | Size | Best for |
|---|---|---|
| `devstral:24b` | 14 GB | Coding — Mistral's best coder |
| `mistral-small:22b` | 12 GB | Strong general purpose |
| `phi4:14b` | 9.1 GB | Math & reasoning (Microsoft) |
| `qwen3:14b` | 9.3 GB | Latest Qwen3 with thinking mode |
| `llama3.2-vision:11b` | 7.8 GB | Image + text understanding (multimodal) |
| `gemma3:12b` | 8.1 GB | General purpose (Google) |
| `nomic-embed-text` | 274 MB | Local embeddings / RAG |
| `gpt-oss:120b` | 65 GB | Meta's largest open-source model (spills to RAM) |
| `qwen3-coder:30b` | 18 GB | Coding, large context (spills to RAM) |
| `gemma3:27b` | 17 GB | General purpose, large (spills to RAM) |
| `gpt-oss:20b` | 13 GB | Meta open-source, general purpose |
| `qwen2.5-coder:14b` | 9.0 GB | Coding (Qwen 2.5 generation) |
| `qwen2.5:14b` | 9.0 GB | General purpose (Qwen 2.5 generation) |
| `deepseek-r1:14b` | 9.0 GB | Best reasoning/VRAM ratio |
| `qwen3:8b` | 5.2 GB | Fast, thinking mode |
| `deepseek-r1:8b` | 5.2 GB | Strong reasoning, compact |
| `llama3.1:8b` | 4.9 GB | General purpose (Meta Llama 3.1) |
| `deepseek-r1:1.5b` | 1.1 GB | Tiny reasoning model |

## GPU fit (RTX 5080 — 16GB VRAM)

Models up to ~14B (Q4) run fully on GPU. Larger models spill weights to RAM and run slower.
