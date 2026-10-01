#!/usr/bin/env python3
"""Summarise integrity-*.log (from scripts/integrity-vm-test.sh) into a jumps table per action and cause.
   scripts/integrity-report.py build/vm-out"""
import re, sys, glob, collections
d = sys.argv[1] if len(sys.argv) > 1 else "build/vm-out"
rx = re.compile(r"selftest: jump (.+?) line (\d+)\.(\d+) dx (\S+) dy (\S+) (.*)")
by = collections.defaultdict(lambda: [0, 0.0, 0.0, set(), collections.Counter()])
total = 0
for f in sorted([g for g in glob.glob(f"{d}/integrity-*.log") if not g.endswith(".err.log")]):
    run = f.split("integrity-")[-1][:-4]
    for l in open(f):
        m = rx.match(l.strip())
        if not m or "[offscreen]" in l: continue
        act = re.sub(r" step \d+$", "", m[1])
        what = m[6]
        cause = ("scroll" if what.startswith("scroll") else "rewrap" if "rewrap" in what else "caret" if "caret" in what
                 else "height" if "height" in what else "x shift" if what.startswith("x ") else "moved")
        if "[transient]" in what: cause += " (transient)"
        e = by[act]; e[0] += 1; e[1] = max(e[1], abs(float(m[4]))); e[2] = max(e[2], abs(float(m[5]))); e[3].add(run); e[4][cause] += 1
        total += 1
print(f"| action | jumps | max dx | max dy | causes | runs |\n|---|---|---|---|---|---|")
for a, e in sorted(by.items(), key=lambda x: -x[1][0]):
    print(f"| {a} | {e[0]} | {e[1]:.1f} | {e[2]:.1f} | {', '.join(f'{k} {v}' for k, v in e[4].most_common())} | {len(e[3])} |")
print(f"| total | {total} | | | | {"8"} logs |")
