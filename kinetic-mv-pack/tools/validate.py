#!/usr/bin/env python3
"""Structural lint for the generated .setting files (no Resolve required)."""
import glob
import os
import re
import sys

eff = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Effects")
files = sorted(glob.glob(os.path.join(eff, "*.setting")))
errors = []
for p in files:
    s = open(p, encoding="utf-8").read()
    n = os.path.basename(p)
    if s.count("{") != s.count("}"):
        errors.append("%s: unbalanced braces" % n)
    if s.count('"') % 2:
        errors.append("%s: odd quote count" % n)
    inner = s.split("Tools = ordered() {")[2:]
    names = re.findall(r"^\t\t\t\t(\w+) = \w+ \{$", s, re.M)
    if len(names) != len(set(names)):
        errors.append("%s: duplicate tool names" % n)
    for op in set(re.findall(r'SourceOp = "(\w+)"', s)):
        if op not in names:
            errors.append("%s: SourceOp %s not defined" % (n, op))
    for ref in set(re.findall(r"\b(Ctl|Src|Col)\.\w+", s)):
        if ref not in names:
            errors.append("%s: expression references missing tool %s" % (n, ref))
    for e in re.findall(r'Expression = "([^"]*)"', s):
        if e.count("(") != e.count(")"):
            errors.append("%s: unbalanced parens in expression %s" % (n, e))
    for t in re.findall(r"self\.(\w+)", s):
        if not re.search(r"^\t+\t\t\t%s = \{ LINKID" % t, s, re.M) and not re.search(
                r"\n\t+\t%s = Input" % t, s):
            errors.append("%s: self.%s has no Ctl input" % (n, t))
print("%d files checked" % len(files))
for e in errors:
    print("ERROR", e)
sys.exit(1 if errors or not files else 0)
