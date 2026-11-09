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
def build_comp(txt):
    """Python mirror of the launcher's buildComp(): wraps a preset in MediaIn/MediaOut."""
    txt = txt.replace("\r\n", "\n")
    mark = "\t\t\tTools = ordered() {\n"
    s = txt.find(mark)
    m = re.search(r'MainOutput1 = InstanceOutput \{ SourceOp = "(\w+)"', txt)
    e = txt.find("\n\t\t\t},\n\t\t},\n\t},")
    if s < 0 or e < 0 or not m:
        return None
    inner = txt[s + len(mark):e + 1]
    anchor = "Src = Transform {\n\t\t\t\t\tCtrlWZoom = false,\n\t\t\t\t\tInputs = {\n"
    link = '\t\t\t\t\t\tInput = Input { SourceOp = "MediaIn1", Source = "Output", },\n'
    inner = inner.replace(anchor, anchor + link, 1)
    out = ('{\n\tTools = ordered() {\n\t\t\t\tMediaIn1 = MediaIn {\n\t\t\t\t},\n' + inner +
           '\n\t\t\t\tMediaOut1 = MediaOut {\n\t\t\t\t\tInputs = {\n'
           '\t\t\t\t\t\tInput = Input { SourceOp = "' + m.group(1) + '", Source = "Output", },\n'
           '\t\t\t\t\t},\n\t\t\t\t},\n\t},\n\tActiveTool = "MediaOut1"\n}\n')
    return out


for p in files:
    n = os.path.basename(p)
    c = build_comp(open(p, encoding="utf-8").read())
    if c is None:
        errors.append("%s: comp build failed" % n)
        continue
    if c.count("{") != c.count("}"):
        errors.append("%s: comp unbalanced braces" % n)
    cnames = re.findall(r"^\t+(\w+) = \w+ \{$", c, re.M)
    for op in set(re.findall(r'SourceOp = "(\w+)"', c)):
        if op not in cnames:
            errors.append("%s: comp SourceOp %s not defined" % (n, op))
    for need in ("MediaIn1", "MediaOut1", "Src", "Ctl"):
        if need not in cnames:
            errors.append("%s: comp missing %s" % (n, need))
    if 'MediaIn1", Source' not in c:
        errors.append("%s: Src not fed by MediaIn1" % n)
print("%d files checked" % len(files))
for e in errors:
    print("ERROR", e)
sys.exit(1 if errors or not files else 0)
