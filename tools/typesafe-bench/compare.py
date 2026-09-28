#!/usr/bin/env python3
"""Merge rules-out.json + typesafe-out.json into a verdict table."""
import json
import sys

def main():
    samples = {s["id"]: s for s in json.load(open("samples.json", encoding="utf-8"))}
    rules = {r["id"]: r["kind"] for r in json.load(open("rules-out.json", encoding="utf-8"))}
    ts = {r["id"]: r for r in json.load(open("typesafe-out.json", encoding="utf-8"))}

    rules_ok = ts_ok = 0
    rows = []
    for sid, s in samples.items():
        exp = s["expected"]
        r = rules.get(sid, "?")
        t = ts.get(sid, {})
        t_kind = t.get("choice", "?")
        conf = t.get("confidence", 0)
        r_hit = r == exp
        t_hit = t_kind == exp
        rules_ok += r_hit
        ts_ok += t_hit
        preview = s["text"][:34].replace("\n", "\\n")
        rows.append(
            f"{sid:<20} | {preview:<36} | {exp:<8} | "
            f"{'✓' if r_hit else '✗'} {r:<8} | "
            f"{'✓' if t_hit else '✗'} {t_kind:<8} {conf:.2f} | {s['note']}"
        )

    print(f"{'sample':<20} | {'text (truncated)':<36} | {'期望':<8} | {'规则':<11} | {'TypeSafe':<18} | 说明")
    print("-" * 130)
    print("\n".join(rows))
    print("-" * 130)
    n = len(samples)
    print(f"规则分类器:  {rules_ok}/{n}")
    print(f"TypeSafe:   {ts_ok}/{n}")
    misses = [sid for sid in samples if rules.get(sid) != samples[sid]["expected"] or ts.get(sid, {}).get("choice") != samples[sid]["expected"]]
    if misses:
        print("\n分歧/错误样本:")
        for sid in misses:
            print(f"  {sid}: 期望={samples[sid]['expected']} 规则={rules.get(sid)} TypeSafe={ts.get(sid, {}).get('choice')}")

if __name__ == "__main__":
    main()
