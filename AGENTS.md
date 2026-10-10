# AGENTS.md

1. Text classification has two fully isolated paths: the local rule classifier (`ClipboardTextClassifier`) and opt-in LLM classification (`LLMTextClassifier`, using the selected TypeSafe AI or OpenAI Decisions model). Never mix them, no fallback — if one fails, the capture simply stays plain text; fallbacks only add complexity.
2. Documentation may be written in English or Simplified Chinese, but keep each document in a single language. Code comments stay in English.
## DESIGN
3. Do not write secondary description text without permission.
4. Do not use periods. Commas are allowed.