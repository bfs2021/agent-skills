#!/usr/bin/env python3
"""Check that skill descriptions still catch the requests they should.

Reads evals/triggers.tsv: `skill<TAB>prompt`, one per line. A skill name is
the one expected to win; `-skill` means that skill must NOT be the winner
(use it for requests that belong to a sibling).

This is a lexical proxy, not the real model router: each prompt is scored
against every description by TF-IDF-weighted word overlap (sqrt term frequency), and the top
score wins. It catches a dropped trigger phrase, not a subtle misroute.
Stdlib only. Run: python3 .github/scripts/eval-triggers.py [-v]
"""
import math
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STOP = set("a an and the to of in on for is are it this that my me i we you with or be do not at as by from what how".split())


def words(text):
    return [w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in STOP and len(w) > 1]


def stem(w):
    for suf in ("ing", "es", "s", "ed"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)]
    return w


def tokens(text):
    return [stem(w) for w in words(text)]


def load_descriptions():
    out = {}
    for md in sorted((ROOT / "skills").glob("*/SKILL.md")):
        m = re.search(r"^description:\s*(.*?)^(?=\S)", md.read_text().split("\n---", 1)[0] + "\n_:", re.S | re.M)
        body = m.group(1) if m else ""
        out[md.parent.name] = body.replace(">", " ", 1) + " " + md.parent.name.replace("-", " ")
    return out


def main():
    verbose = "-v" in sys.argv
    descs = load_descriptions()
    docs = {n: Counter(tokens(d)) for n, d in descs.items()}
    df = Counter(t for c in docs.values() for t in c)
    idf = {t: math.log(1 + len(docs) / n) for t, n in df.items()}

    def rank(prompt):
        q = set(tokens(prompt))
        scores = {n: sum(idf[t] * math.sqrt(c[t]) for t in q if t in c) for n, c in docs.items()}
        return sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))

    fails = total = 0
    for n, line in enumerate((ROOT / "evals" / "triggers.tsv").read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        skill, prompt = line.split("\t", 1)
        neg = skill.startswith("-")
        name = skill.lstrip("-")
        if name not in descs:
            print(f"triggers.tsv:{n}: unknown skill {name!r}")
            fails += 1
            continue
        total += 1
        ranked = rank(prompt)
        top = ranked[0][0]
        ok = (top != name) if neg else (top == name)
        if not ok:
            fails += 1
            print(f"MISS triggers.tsv:{n}: {'not ' if neg else ''}{name} <- {prompt!r} (got {top}, then {ranked[1][0]})")
        elif verbose:
            print(f"ok   {skill}: {prompt}")
    print(f"{total - fails}/{total} trigger evals pass")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
