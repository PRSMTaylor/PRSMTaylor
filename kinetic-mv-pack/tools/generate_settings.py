#!/usr/bin/env python3
"""Generates the KMV Fusion macro .setting files into ../Effects.

Every effect is a Fusion MacroOperator built around a hidden control tool
("Ctl") that owns all sliders plus two computed values:
  Active - 1 while inside the effect window, else 0
  Env    - 0..1(+) envelope shaped by the effect kind
Window: Pre = last <Length> frames of the clip (peak at the cut = last frame),
        Post = first <Length> frames of the clip (peak at the cut = first frame).
Trimming the clip does not change the window; Length is a slider.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Effects")

START, END = "comp.RenderStart", "comp.RenderEnd"

# name: (default, min, max, label, integer)
CONTROLS = {
    "Intensity": (1.0, 0.0, 2.0, "Intensity", False),
    "Length": (8, 1, 30, "Length (frames)", True),
    "Count": (6, 1, 30, "Strobe Count", True),
    "Duty": (0.5, 0.05, 0.95, "Strobe On-Time", False),
    "Fade": (0.0, 0.0, 1.0, "Strobe Fade-Out", False),
    "Hold": (3, 1, 24, "Hold / Loop (frames)", True),
    "Offset": (2, 1, 24, "Echo Spacing (frames)", True),
    "Echo": (0.6, 0.0, 1.0, "Echo Strength", False),
    "Speed": (1.0, 0.1, 5.0, "Speed", False),
    "Amount": (1.0, 0.0, 3.0, "Amount", False),
    "Angle": (0.0, -180.0, 180.0, "Angle", False),
    "Strength": (1.0, 0.0, 3.0, "Strength", False),
    "Curve": (0, 0, 3, "Curve (0 Smooth, 1 Sharp, 2 S, 3 Linear)", True),
    "Seed": (1, 0, 999, "Random Seed (0 = fixed)", True),
    "MotionBlur": (0.0, 0.0, 2.0, "Motion Blur", False),
    "Brightness": (0.0, -1.0, 2.0, "Brightness", False),
}
COMMON = ["Strength", "Curve", "Seed", "MotionBlur", "Brightness"]
REQUIRED = {
    "decay": ["Intensity"],
    "hold": ["Intensity"],
    "strobe": ["Intensity", "Count", "Duty", "Fade"],
}


def ser(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"%s"' % v.replace('"', '\\"')
    raise TypeError(v)


def inp(spec):
    if isinstance(spec, dict):
        if "expr" in spec:
            return "Input { Expression = %s, }" % ser(spec["expr"])
        return "Input { SourceOp = %s, Source = %s, }" % (
            ser(spec["op"]), ser(spec.get("src", "Output")))
    return "Input { Value = %s, }" % ser(spec)


def E(s):
    return {"expr": s}


def link(op):
    return {"op": op, "src": "Output"}


class Tool:
    def __init__(self, name, kind, inputs=None, extra=""):
        self.name, self.kind, self.inputs, self.extra = name, kind, inputs or {}, extra

    def render(self, pos, t):
        lines = ["%s%s = %s {" % (t, self.name, self.kind),
                 "%s\tCtrlWZoom = false," % t,
                 "%s\tInputs = {" % t]
        for k, v in self.inputs.items():
            lines.append("%s\t\t%s = %s," % (t, k, inp(v)))
        lines.append("%s\t}," % t)
        if self.extra:
            lines.append(self.extra)
        lines.append("%s\tViewInfo = OperatorInfo { Pos = { %d, %d } }," % (t, pos[0], pos[1]))
        lines.append("%s}," % t)
        return "\n".join(lines)


def src():
    return Tool("Src", "Transform", {"Size": 1.0})


def color_bg(name, rgb):
    return Tool(name, "Background", {
        "UseFrameFormatSettings": 1,
        "TopLeftRed": rgb[0], "TopLeftGreen": rgb[1],
        "TopLeftBlue": rgb[2], "TopLeftAlpha": 1.0,
    })


def merge(name, prev, fg, blend):
    return Tool(name, "Merge", {"Background": link(prev), "Foreground": link(fg),
                                "Blend": blend})


def ctl(kind, mode, controls, defaults):
    d = "(time-%s)" % START if mode == "Post" else "(%s-time)" % END
    w = START if mode == "Post" else "(%s-Ctl.Length)" % END
    active = "iif(%s < self.Length, 1, 0)" % d
    u = "(1-%s/self.Length)" % d
    shape = ("iif(self.Curve==1, %s^4, iif(self.Curve==2, %s*%s*(3-2*%s), iif(self.Curve==3, %s, %s^2)))"
             % (u, u, u, u, u, u))
    if kind == "decay":
        env = "iif(%s < self.Length, self.Intensity*self.Strength*%s, 0)" % (d, shape)
    elif kind == "hold":
        env = "iif(%s < self.Length, self.Intensity*self.Strength, 0)" % d
    else:
        cyc = "(%s/(self.Length/self.Count))" % d
        env = ("iif(%s < self.Length and (%s-floor(%s)) < self.Duty, "
               "self.Intensity*self.Strength*(1-self.Fade*%s/self.Length), 0)" % (d, cyc, cyc, d))
    inputs = {"Width": 1920, "Height": 1080, "UseFrameFormatSettings": 1,
              "Active": E(active), "Env": E(env)}
    uc = ["\t\t\t\tUserControls = ordered() {"]
    for c in controls + ["Active", "Env"]:
        dv, lo, hi, label, integer = CONTROLS.get(c, (0, 0, 2, c, False))
        if c in controls:
            dv = defaults.get(c, dv)
            inputs[c] = dv
        hidden = c in ("Active", "Env")
        uc.append(
            "\t\t\t\t\t%s = { LINKID_DataType = \"Number\", INPID_InputControl = \"SliderControl\", "
            "INP_Default = %s, INP_MinScale = %s, INP_MaxScale = %s, INP_Integer = %s, "
            "LINKS_Name = %s, ICS_ControlPage = \"Controls\"%s }," % (
                c, ser(dv), ser(lo), ser(hi), "true" if integer else "false", ser(label),
                ", IC_Visible = false" if hidden else ""))
    uc.append("\t\t\t\t},")
    return Tool("Ctl", "Background", inputs, extra="\n".join(uc)), w


LENGTHS = {"Flash": 4, "Color Flash": 4, "Glow Flash": 6, "Strobe Flash": 8, "Strobe Black": 8,
           "Frame Stutter": 8, "Loop Stutter": 8, "Echo Stutter": 8, "Stutter Flash": 10,
           "Pulse Stutter": 10, "Shake Y": 8, "Shake XY": 8, "Shake Twitch": 8, "Zoom In": 6,
           "Zoom Pull": 6, "Zoom Blur": 6, "Slide Left": 6, "Slide Right": 6, "Slide Up": 6,
           "Slide Down": 6, "Soft Blur": 6, "Defocus": 6, "Directional Blur": 6}


def build(name, mode, kind, controls, tools_fn, defaults=None, rgb=False):
    defaults = dict(defaults or {})
    defaults.setdefault("Length", LENGTHS.get(name, 8))
    defaults.setdefault("Curve", 1)
    exposed = ["Length"] + [c for c in controls if c != "Length"] + COMMON
    allc = list(exposed)
    for c in REQUIRED[kind]:
        if c not in allc:
            allc.append(c)
    c, w = ctl(kind, mode, allc, defaults)
    chain = tools_fn(mode)
    prev = chain[-1].name
    post = [
        Tool("Bri", "BrightnessContrast", {"Input": link(prev),
             "Gain": E("1+Ctl.Brightness*Ctl.Active")}),
        Tool("MB", "DirectionalBlur", {"Input": link("Bri"), "Type": 0,
             "Length": E("Ctl.MotionBlur*Ctl.Env*0.1"), "Angle": 0.0}),
    ]
    tools = [src()] + chain + post + [c]
    last = "MB"
    for t in tools:
        for k, v in list(t.inputs.items()):
            if isinstance(v, dict) and "expr" in v:
                t.inputs[k] = E(v["expr"].replace("{W}", w))
    ins = ['\t\t\t\tMainInput1 = InstanceInput { SourceOp = "Src", Source = "Input", },']
    for ctrl in exposed:
        ins.append('\t\t\t\t%s = InstanceInput { SourceOp = "Ctl", Source = %s, Default = %s, },' % (
            ctrl, ser(ctrl), ser(defaults.get(ctrl, CONTROLS[ctrl][0]))))
    if rgb:
        for ch in ("Red", "Green", "Blue"):
            ins.append('\t\t\t\t%s = InstanceInput { SourceOp = "Col", Source = "TopLeft%s", '
                       'Name = %s, Default = %s, },' % (
                           ch, ch, ser(ch + " (flash color)"), ser(defaults.get(ch, 1.0))))
    macro = "KMV %s %s" % (name, mode)
    ident = macro.replace(" ", "_")
    out = ["{", "\tTools = ordered() {", "\t\t%s = MacroOperator {" % ident,
           "\t\t\tCtrlWZoom = false,",
           "\t\t\tInputs = ordered() {"] + ins + [
           "\t\t\t},",
           "\t\t\tOutputs = {",
           '\t\t\t\tMainOutput1 = InstanceOutput { SourceOp = "%s", Source = "Output", },' % last,
           "\t\t\t},",
           "\t\t\tViewInfo = GroupInfo { Pos = { 0, 0 } },",
           "\t\t\tTools = ordered() {"]
    for i, t in enumerate(tools):
        out.append(t.render((110 * i, 0), "\t\t\t\t"))
    out += ["\t\t\t},", "\t\t},", "\t},", '\tActiveTool = "%s"' % ident, "}", ""]
    with open(os.path.join(OUT, macro + ".setting"), "w", newline="\n") as f:
        f.write("\n".join(out))
    return macro


# ---- tool chains -----------------------------------------------------------

def flash(mode):
    return [color_bg("Col", (1, 1, 1)), merge("Fx", "Src", "Col", E("Ctl.Env"))]


def glow_flash(mode):
    return [
        Tool("Bright", "BrightnessContrast", {
            "Input": link("Src"), "Gain": E("1+Ctl.Env*1.5"), "Brightness": E("Ctl.Env*0.25")}),
        Tool("Fx", "Glow", {"Input": link("Bright"), "GlowSize": 25.0,
                            "Glow": E("Ctl.Env*1.2"), "Blend": 1.0}),
    ]


def freeze(mode, loop=False):
    x = "(time-{W})"
    h = "Ctl.Hold"
    if loop:
        srcf = "{W}+(%s-floor(%s/%s)*%s)" % (x, x, h, h)
    else:
        srcf = "{W}+floor(%s/%s)*%s" % (x, h, h)
    return [Tool("Fx", "TimeStretcher", {
        "Input": link("Src"), "SourceTime": E("iif(Ctl.Active>0, %s, time)" % srcf)})]


def loop_stutter(mode):
    return freeze(mode, loop=True)


def echo(mode):
    ts = [Tool("Echo%d" % k, "TimeStretcher", {
        "Input": link("Src"), "SourceTime": E("time-Ctl.Active*%d*Ctl.Offset" % k)})
        for k in (1, 2, 3)]
    ms, prev = [], "Src"
    for k in (1, 2, 3):
        name = "Fx" if k == 3 else "Mix%d" % k
        ms.append(merge(name, prev, "Echo%d" % k, E("Ctl.Env*Ctl.Echo^%d" % k)))
        prev = name
    return ts + ms


def stutter_flash(mode):
    return freeze(mode) + [color_bg("Col", (1, 1, 1)),
                           merge("Flash", "Fx", "Col", E("Ctl.Env*0.8"))]


def shake(kind):
    def f(mode):
        amp = "Ctl.Env*Ctl.Amount*0.04"
        t = "time*Ctl.Speed"
        if kind == "Y":
            cx, cy = "0.5", "0.5+%s*sin(%s*2.3)" % (amp, t)
            ang = "0"
        elif kind == "XY":
            cx = "0.5+%s*sin(%s*1.9)" % (amp, t)
            cy = "0.5+%s*sin(%s*2.7+1)" % (amp, t)
            ang = "Ctl.Env*Ctl.Amount*0.8*sin(%s*1.3)" % t
        else:
            r1 = "sin((floor(time*Ctl.Speed/2)+Ctl.Seed)*12.9898)*43758.5453"
            r2 = "sin((floor(time*Ctl.Speed/2)+Ctl.Seed)*78.233)*12345.6789"
            cx = "0.5+%s*2*((%s)-floor(%s)-0.5)" % (amp, r1, r1)
            cy = "0.5+%s*2*((%s)-floor(%s)-0.5)" % (amp, r2, r2)
            ang = "Ctl.Env*Ctl.Amount*0.8*sin(%s*1.3)" % t
        return [Tool("Fx", "Transform", {
            "Input": link("Src"), "Center": E("Point(%s, %s)" % (cx, cy)),
            "Size": E("1+Ctl.Amount*0.12"), "Angle": E(ang)})]
    return f


def zoom(direction):
    def f(mode):
        s = ("1+Ctl.Env^2*Ctl.Amount*0.6" if direction == "In"
             else "1/(1+Ctl.Env^2*Ctl.Amount*0.6)")
        return [Tool("Fx", "Transform", {"Input": link("Src"), "Size": E(s)})]
    return f


def zoom_blur(mode):
    return [
        Tool("Zm", "Transform", {"Input": link("Src"),
                                 "Size": E("1+Ctl.Env^2*Ctl.Amount*0.4")}),
        Tool("Fx", "DirectionalBlur", {"Input": link("Zm"), "Type": 3,
                                       "Length": E("Ctl.Env*Ctl.Amount*0.3")}),
    ]


def slide(dx, dy):
    def f(mode):
        return [Tool("Fx", "Transform", {
            "Input": link("Src"),
            "Center": E("Point(0.5+%d*Ctl.Env^2*Ctl.Amount, 0.5+%d*Ctl.Env^2*Ctl.Amount)" % (dx, dy)),
        })]
    return f


def blur(kind):
    def f(mode):
        if kind == "Soft":
            return [Tool("Fx", "Blur", {"Input": link("Src"), "Filter": "Fast Gaussian",
                                        "XBlurSize": E("Ctl.Env*Ctl.Amount*40")})]
        if kind == "Defocus":
            return [Tool("Fx", "Defocus", {"Input": link("Src"),
                                           "DefocusSize": E("Ctl.Env*Ctl.Amount*40")})]
        return [Tool("Fx", "DirectionalBlur", {
            "Input": link("Src"), "Type": 0,
            "Length": E("Ctl.Env*Ctl.Amount*0.3"), "Angle": E("Ctl.Angle")})]
    return f


def pulse(mode):
    return [Tool("Fx", "Transform", {"Input": link("Src"),
                                     "Size": E("1+Ctl.Env*Ctl.Amount*0.15")})]


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".setting"):
            os.remove(os.path.join(OUT, f))
    S = ["Intensity", "Count", "Duty", "Fade"]
    made = []
    for mode in ("Pre", "Post"):
        made += [
            build("Flash", mode, "decay", ["Intensity"], flash),
            build("Color Flash", mode, "decay", ["Intensity"], flash,
                  {"Red": 1.0, "Green": 0.35, "Blue": 0.1}, rgb=True),
            build("Glow Flash", mode, "decay", ["Intensity"], glow_flash),
            build("Strobe Flash", mode, "strobe", S, flash, rgb=True),
            build("Strobe Black", mode, "strobe", S, flash,
                  {"Red": 0.0, "Green": 0.0, "Blue": 0.0}, rgb=True),
            build("Frame Stutter", mode, "hold", ["Hold"], freeze),
            build("Loop Stutter", mode, "hold", ["Hold"], loop_stutter, {"Hold": 4}),
            build("Echo Stutter", mode, "hold", ["Intensity", "Offset", "Echo"], echo),
            build("Stutter Flash", mode, "strobe", S + ["Hold"], stutter_flash,
                  {"Count": 4, "Hold": 3, "Intensity": 0.8}),
            build("Pulse Stutter", mode, "strobe", S + ["Amount"], pulse,
                  {"Count": 5, "Fade": 0.4}),
            build("Shake Y", mode, "decay", ["Speed", "Amount"], shake("Y"), {"Speed": 3.0}),
            build("Shake XY", mode, "decay", ["Speed", "Amount"], shake("XY"), {"Speed": 3.0}),
            build("Shake Twitch", mode, "decay", ["Speed", "Amount"], shake("T"), {"Speed": 1.5}),
            build("Zoom In", mode, "decay", ["Amount"], zoom("In")),
            build("Zoom Pull", mode, "decay", ["Amount"], zoom("Out")),
            build("Zoom Blur", mode, "decay", ["Amount"], zoom_blur),
            build("Slide Left", mode, "decay", ["Amount"], slide(-1, 0)),
            build("Slide Right", mode, "decay", ["Amount"], slide(1, 0)),
            build("Slide Up", mode, "decay", ["Amount"], slide(0, 1)),
            build("Slide Down", mode, "decay", ["Amount"], slide(0, -1)),
            build("Soft Blur", mode, "decay", ["Amount"], blur("Soft")),
            build("Defocus", mode, "decay", ["Amount"], blur("Defocus")),
            build("Directional Blur", mode, "decay", ["Amount", "Angle"], blur("Dir")),
        ]
    print("Generated %d presets in %s" % (len(made), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
