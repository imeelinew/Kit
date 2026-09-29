# AGENTS.md

1. Text classification has two fully isolated models: the local rule classifier (`ClipboardTextClassifier`) and TypeSafe AI (`TypeSafeClassifier`, opt-in experiment). Never mix them, no fallback — if one fails, the capture simply stays plain text; fallbacks only add complexity.
2. All documentation must be written in English.
