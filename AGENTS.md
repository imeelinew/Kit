# AGENTS.md

1. Text classification has two fully isolated models: the local rule classifier (`ClipboardTextClassifier`) and TypeSafe AI (`TypeSafeClassifier`, opt-in experiment). Never mix them, no fallback — if one fails, the capture simply stays plain text; fallbacks only add complexity.
2. Documentation may be written in English or Simplified Chinese, but keep each document in a single language. Code comments stay in English.
