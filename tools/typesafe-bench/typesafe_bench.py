#!/usr/bin/env python3
"""Run the TypeSafe API over samples.json using Kit's own classification semantics.

One call per sample: a `choice` question over Kit's five text kinds, plus a
`noul` question ("would a developer paste this into an editor/terminal?") as an
independent signal. Writes typesafe-out.json.

Usage: python3 typesafe_bench.py [samples.json] [out.json]
"""
import json
import os
import re
import sys
import time
import urllib.request

API_URL = "https://api.typesafe.ai/v1/systemone"

# Questions are constants on purpose (per TypeSafe docs: keep them in one
# reviewable place). The wording mirrors Kit's classifier semantics:
# link = the WHOLE clipboard is a single http(s) URL; code inside Markdown
# prose keeps the document Markdown; code covers source, config, shell.
QUESTIONS = {
    "kind": {
        "type": "choice",
        "instructions": (
            "This string was captured from a developer's clipboard. Which single "
            "kind is it? Judge the whole string: a URL embedded in prose is not "
            "a link capture, and source code embedded in a Markdown article "
            "keeps the article Markdown."
        ),
        "criteria": {
            "link": "The entire string is one http(s) URL, nothing else",
            "path": "A file or directory path the user means to reference on disk",
            "code": "Source code, shell commands, terminal transcripts, JSON, or config files",
            "markdown": "A Markdown document with headings, lists, emphasis, or inline code",
            "text": "Plain prose: sentences, notes, emails, chat messages",
        },
    },
    "editor_paste": {
        "type": "noul",
        "instructions": "Would a developer most likely paste this into an editor or terminal rather than a document?",
        "criteria": {
            "true": "It is code, a command, or a path/URL to open somewhere technical",
            "false": "It is prose meant for reading or pasting into a document or chat",
        },
    },
}


def load_key():
    env = os.environ.get("TYPESAFE_API_KEY")
    if env:
        return env
    # Fall back to the export line in ~/.zshrc
    with open(os.path.expanduser("~/.zshrc"), encoding="utf-8") as f:
        for line in f:
            m = re.search(r'export TYPESAFE_API_KEY="([^"]+)"', line)
            if m:
                return m.group(1)
    raise SystemExit("TYPESAFE_API_KEY not found in env or ~/.zshrc")


def classify(text: str, key: str) -> dict:
    body = json.dumps(
        {"state": text, "model": "jev-latest", "questions": QUESTIONS}
    ).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main():
    samples_path = sys.argv[1] if len(sys.argv) > 1 else "samples.json"
    out_path = sys.argv[2] if len(sys.argv) > 2 else "typesafe-out.json"
    key = load_key()
    with open(samples_path, encoding="utf-8") as f:
        samples = json.load(f)

    results = []
    for i, s in enumerate(samples, 1):
        t0 = time.time()
        data = classify(s["text"], key)
        answers = data["answers"]
        kind = answers["kind"]
        results.append(
            {
                "id": s["id"],
                "choice": kind["choice"],
                "confidence": kind["confidence"],
                "probabilities": kind["probabilities"],
                "editor_paste": answers["editor_paste"]["noul"],
                "usage": data["usage"],
                "latency_s": round(time.time() - t0, 2),
            }
        )
        print(
            f"[{i:>2}/{len(samples)}] {s['id']:<22} -> {kind['choice']:<8} "
            f"conf={kind['confidence']:.2f}  ({time.time() - t0:.2f}s)",
            flush=True,
        )

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    total_in = sum(r["usage"]["input_tokens"] for r in results)
    total_out = sum(r["usage"]["output_tokens"] for r in results)
    print(
        f"\nDone. {len(results)} calls, {total_in} input + {total_out} output tokens, "
        f"~${total_in * 42 / 1e9 + total_out * 42 / 1e9:.6f} at $42/1B tokens."
    )


if __name__ == "__main__":
    main()
