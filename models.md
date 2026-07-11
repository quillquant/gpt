# Ollama Models

| Model | Size | Category | Best for | GPU fit |
|---|---|---|---|---|
| `deepseek-r1:14b` | 9.0 GB | reasoning | Best reasoning/VRAM ratio | full |
| `deepseek-r1:8b` | 5.2 GB | reasoning | Strong reasoning, compact | full |
| `deepseek-r1:1.5b` | 1.1 GB | reasoning | Tiny reasoning model | full |
| `phi4:14b` | 9.1 GB | reasoning | Math & STEM (Microsoft) | full |
| `devstral-small-2:24b` | 15 GB | coding | Agentic coding, tools, 384K context | tight |
| `devstral:24b` | 14 GB | coding | Coding — earlier Devstral | full |
| `qwen2.5-coder:14b` | 9.0 GB | coding | Coding (Qwen 2.5) | full |
| `qwen3-coder:30b` | 18 GB | coding | Coding, large context | spill |
| `qwen3.5:9b` | 6.6 GB | general | Multimodal + thinking, fast | full |
| `qwen3.5:9b-q8_0` | 10 GB | general | Higher-quality Qwen 3.5 9B | full |
| `qwen3.5:27b` | 17 GB | large | Strong Qwen 3.5 quality | spill |
| `qwen3:14b` | 9.3 GB | general | Thinking mode, instruction following | full |
| `qwen3:8b` | 5.2 GB | general | Fast thinking mode | full |
| `qwen2.5:14b` | 9.0 GB | general | General purpose Qwen 2.5 | full |
| `gemma4:12b` | 7.6 GB | general | Reasoning, coding, vision, agents | full |
| `gemma4:26b-a4b-it-qat` | 15 GB | large | MoE near-30B quality on 16GB | tight |
| `gemma3:12b` | 8.1 GB | general | General purpose (Gemma 3) | full |
| `gemma3:27b` | 17 GB | large | Larger Gemma 3 | spill |
| `ministral-3:14b` | 9.1 GB | general | Vision + tools, fast Mistral | full |
| `mistral-small3.2:24b` | 15 GB | general | Instruction following + vision | tight |
| `mistral-small:22b` | 12 GB | general | Strong general purpose | full |
| `gpt-oss:20b` | 13 GB | general | Fastest interactive gpt-oss | full |
| `gpt-oss:120b` | 65 GB | large | Largest gpt-oss (heavy spill) | spill |
| `lfm2.5:8b` | 5.2 GB | general | Fast tool calling (edge MoE) | full |
| `llama3.1:8b` | 4.9 GB | general | Meta Llama 3.1 general purpose | full |
| `qwen3-vl:8b` | 6.1 GB | vision | Vision-language (Qwen3-VL) | full |
| `llama3.2-vision:11b` | 7.8 GB | vision | Image + text understanding | full |
| `nomic-embed-text:latest` | 274 MB | embeddings | Local embeddings / RAG | full |

## GPU fit (RTX 5080 — 16GB VRAM)

- **full** — runs entirely on GPU at typical Q4 context
- **tight** — fits with short context (4K–8K); watch KV cache
- **spill** — weights overflow to RAM; much slower for interactive use

Models up to ~14B (Q4) run fully on GPU. Larger models spill weights to RAM and run slower.
