-- KMV Effects Launcher
-- Resolve: Workspace > Scripts > Edit > KMV Effects Launcher
-- Pick a KMV effect, set its controls, and apply it at the playhead cut.
-- Method: builds a Fusion .comp (MediaIn -> KMV tools -> MediaOut) from the installed
-- KMV preset and imports it onto the clip with TimelineItem:ImportFusionComp().
-- Pre goes on the clip ending at the playhead, Post on the clip starting at it.

local resolve = resolve or Resolve()
local fu = fusion or Fusion()
if not resolve or not fu then
    print("KMV: must be run from Resolve's Workspace > Scripts menu.")
    return
end

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- { name, description, enabled optional controls, defaults }
local EFFECTS = {
    { "Flash", "White flash that peaks on the cut and decays.", { "Intensity" }, {} },
    { "Color Flash", "Orange flash (edit Red/Green/Blue in the Fusion page).", { "Intensity" }, {} },
    { "Glow Flash", "Bright, glowing bloom flash on the cut.", { "Intensity" }, {} },
    { "Strobe Flash", "Rapid on/off white strobe across the window. Set Count.", { "Intensity", "Count" }, { Count = 6 } },
    { "Strobe Black", "Rapid strobe to black. Set Count.", { "Intensity", "Count" }, { Count = 6 } },
    { "Frame Stutter", "Freeze-repeat: holds a frame for N frames, then jumps. Set Hold.", { "Frames" }, { Frames = 3 } },
    { "Loop Stutter", "Repeats a short loop of N frames. Set Hold.", { "Frames" }, { Frames = 4 } },
    { "Echo Stutter", "Trailing ghost frames. Frames = echo spacing.", { "Intensity", "Frames" }, { Frames = 2 } },
    { "Stutter Flash", "Frame freeze plus strobing flash.", { "Intensity", "Count", "Frames" }, { Count = 4, Frames = 3, Intensity = 80 } },
    { "Pulse Stutter", "Rhythmic zoom pulses; Count = number of pulses.", { "Intensity", "Count", "Amount" }, { Count = 5 } },
    { "Shake Y", "Vertical shake that settles.", { "Amount", "Speed" }, { Speed = 300 } },
    { "Shake XY", "Handheld-style shake in X, Y and rotation.", { "Amount", "Speed" }, { Speed = 300 } },
    { "Shake Twitch", "Sudden random jolts.", { "Amount", "Speed" }, { Speed = 150 } },
    { "Zoom In", "Punch-in zoom peaking on the cut.", { "Amount" }, {} },
    { "Zoom Pull", "Pull-back zoom (shows edges).", { "Amount" }, {} },
    { "Zoom Blur", "Zoom with radial motion blur.", { "Amount" }, {} },
    { "Slide Left", "Slides the picture left.", { "Amount" }, {} },
    { "Slide Right", "Slides the picture right.", { "Amount" }, {} },
    { "Slide Up", "Slides the picture up.", { "Amount" }, {} },
    { "Slide Down", "Slides the picture down.", { "Amount" }, {} },
    { "Soft Blur", "Gaussian blur ramp.", { "Amount" }, {} },
    { "Defocus", "Lens-style defocus ramp.", { "Amount" }, {} },
    { "Directional Blur", "Linear motion blur.", { "Amount" }, {} },
}

local isWin = (package.config:sub(1, 1) == "\\")

local function fileExists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local function effectsDir()
    local cands = {}
    local ok, mapped = pcall(function() return fu:MapPath("Templates:/Edit/Effects/") end)
    if ok and mapped and mapped ~= "" then cands[#cands + 1] = mapped end
    if isWin then
        cands[#cands + 1] = (os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Templates\\Edit\\Effects\\"
        cands[#cands + 1] = (os.getenv("ProgramData") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Templates\\Edit\\Effects\\"
    else
        cands[#cands + 1] = (os.getenv("HOME") or "") .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Templates/Edit/Effects/"
        cands[#cands + 1] = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Templates/Edit/Effects/"
    end
    for _, c in ipairs(cands) do
        if fileExists(c .. "KMV Flash Pre.setting") then return c end
    end
    return nil
end

local function setNumber(block, name, value)
    local pat = "(%f[%w]" .. name .. " = Input { Value = )[^,]+(,)"
    return (block:gsub(pat, function(a, b) return a .. tostring(value) .. b end, 1))
end

-- Returns .comp text for one preset, or nil + error
local function buildComp(dir, name, mode, v)
    local f = io.open(dir .. "KMV " .. name .. " " .. mode .. ".setting", "rb")
    if not f then return nil, "preset file not found" end
    local txt = f:read("*a")
    f:close()
    txt = txt:gsub("\r\n", "\n")
    local startMark = "\t\t\tTools = ordered() {\n"
    local s = txt:find(startMark, 1, true)
    local last = txt:match('MainOutput1 = InstanceOutput { SourceOp = "(%w+)"')
    local e = txt:find("\n\t\t\t},\n\t\t},\n\t},", 1, true)
    if not s or not e or not last then return nil, "unexpected preset format" end
    local inner = txt:sub(s + #startMark, e)

    local ci = inner:find("Ctl = Background {", 1, true)
    if not ci then return nil, "control tool missing" end
    local head, ctl = inner:sub(1, ci - 1), inner:sub(ci)
    for k, val in pairs(v) do ctl = setNumber(ctl, k, val) end
    inner = head .. ctl

    local si = inner:find("Src = Transform {", 1, true)
    local ii = si and inner:find("Inputs = {\n", si, true)
    if not ii then return nil, "source tool missing" end
    local ie = ii + #"Inputs = {\n" - 1
    inner = inner:sub(1, ie) .. '\t\t\t\t\t\tInput = Input { SourceOp = "MediaIn1", Source = "Output", },\n' .. inner:sub(ie + 1)

    return table.concat({
        "{\n\tTools = ordered() {\n",
        "\t\t\t\tMediaIn1 = MediaIn {\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { -110, 0 } },\n\t\t\t\t},\n",
        inner, "\n",
        "\t\t\t\tMediaOut1 = MediaOut {\n\t\t\t\t\tInputs = {\n\t\t\t\t\t\tIndex = Input { Value = \"0\", },\n",
        "\t\t\t\t\t\tInput = Input { SourceOp = \"", last, "\", Source = \"Output\", },\n",
        "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 1500, 0 } },\n\t\t\t\t},\n",
        "\t}\n}\n" }), nil
end

local function playheadFrame(timeline)
    local fps = tonumber(timeline:GetSetting("timelineFrameRate")) or 24
    fps = math.floor(fps + 0.5)
    local tc = timeline:GetCurrentTimecode() or ""
    local h, m, s, f = tc:match("(%d+)[:;](%d+)[:;](%d+)[:;](%d+)")
    if not h then return nil end
    return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * fps + tonumber(f)
end

-- clip ending (Pre) or starting (Post) at frame p, searching top track down
local function findClip(timeline, mode, p)
    for t = timeline:GetTrackCount("video"), 1, -1 do
        for _, item in ipairs(timeline:GetItemListInTrack("video", t) or {}) do
            local edge = (mode == "Pre") and item:GetEnd() or item:GetStart()
            if math.abs(edge - p) <= 1 then return item end
        end
    end
    return nil
end

local function tmpDir()
    return os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
end

local function applyEffect(entry, modes, v, setStatus)
    local project = resolve:GetProjectManager():GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not timeline then return setStatus("No timeline is open.") end
    local p = playheadFrame(timeline)
    if not p then return setStatus("Could not read playhead timecode.") end
    local dir = effectsDir()
    if not dir then return setStatus("KMV presets not found. Run the installer and restart Resolve.") end

    local msgs = {}
    for _, mode in ipairs(modes) do
        local item = findClip(timeline, mode, p)
        if not item then
            msgs[#msgs + 1] = mode .. ": no clip " .. (mode == "Pre" and "ends" or "starts") .. " at the playhead"
        else
            local comp, err = buildComp(dir, entry[1], mode, v)
            if not comp then
                msgs[#msgs + 1] = mode .. ": " .. err
            else
                local sep = isWin and "\\" or "/"
                local path = tmpDir() .. sep .. "KMV_" .. entry[1]:gsub(" ", "_") .. "_" .. mode .. ".comp"
                local fh = io.open(path, "wb")
                if not fh then
                    msgs[#msgs + 1] = mode .. ": cannot write " .. path
                else
                    fh:write(comp)
                    fh:close()
                    if not item.ImportFusionComp then
                        msgs[#msgs + 1] = mode .. ": this Resolve has no ImportFusionComp API. Import manually on the Fusion page: " .. path
                    else
                        local ok, res = pcall(function() return item:ImportFusionComp(path) end)
                        if ok and res then
                            msgs[#msgs + 1] = mode .. ": applied to " .. tostring(item:GetName())
                        else
                            msgs[#msgs + 1] = mode .. ": import failed. Import manually on the Fusion page: " .. path
                        end
                    end
                end
            end
        end
    end
    setStatus(table.concat(msgs, "\n"))
end

local win = disp:AddWindow({
    ID = "KMVWin", WindowTitle = "KMV Effects Launcher", Geometry = { 200, 200, 520, 420 },
    ui:VGroup {
        ui:Label { Text = "Park the playhead on a cut, pick an effect, then Apply.", Weight = 0 },
        ui:ComboBox { ID = "Effect", Weight = 0 },
        ui:Label { ID = "Desc", WordWrap = true, Weight = 0, Text = "" },
        ui:HGroup { Weight = 0, ui:Label { Text = "Apply to" }, ui:ComboBox { ID = "Where" } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Length (frames)" }, ui:SpinBox { ID = "Length", Minimum = 1, Maximum = 120, Value = 12 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Intensity %" }, ui:SpinBox { ID = "Intensity", Minimum = 0, Maximum = 200, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Strobe / stutter count" }, ui:SpinBox { ID = "Count", Minimum = 1, Maximum = 30, Value = 6 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Hold / loop / echo frames" }, ui:SpinBox { ID = "Frames", Minimum = 1, Maximum = 24, Value = 3 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Amount %" }, ui:SpinBox { ID = "Amount", Minimum = 0, Maximum = 300, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Speed %" }, ui:SpinBox { ID = "Speed", Minimum = 10, Maximum = 500, Value = 100 } },
        ui:Button { ID = "Apply", Text = "Apply at playhead", Weight = 0 },
        ui:Label { ID = "Status", WordWrap = true, Text = "", Alignment = { AlignTop = true } },
    },
})
local itm = win:GetItems()

for _, e in ipairs(EFFECTS) do itm.Effect:AddItem(e[1]) end
itm.Where:AddItem("Both (Pre on outgoing, Post on incoming)")
itm.Where:AddItem("Pre only (outgoing clip)")
itm.Where:AddItem("Post only (incoming clip)")

local function setStatus(t) itm.Status.Text = t end

local function refresh()
    local e = EFFECTS[itm.Effect.CurrentIndex + 1]
    if not e then return end
    itm.Desc.Text = e[2]
    local has = {}
    for _, k in ipairs(e[3]) do has[k] = true end
    for _, k in ipairs({ "Intensity", "Count", "Frames", "Amount", "Speed" }) do
        itm[k].Enabled = has[k] or false
    end
    local d = e[4]
    itm.Intensity.Value = d.Intensity or 100
    itm.Count.Value = d.Count or 6
    itm.Frames.Value = d.Frames or 3
    itm.Amount.Value = d.Amount or 100
    itm.Speed.Value = d.Speed or 100
end

function win.On.Effect.CurrentIndexChanged(ev) refresh() end
function win.On.KMVWin.Close(ev) disp:ExitLoop() end

function win.On.Apply.Clicked(ev)
    local e = EFFECTS[itm.Effect.CurrentIndex + 1]
    local has = {}
    for _, k in ipairs(e[3]) do has[k] = true end
    local v = { Length = itm.Length.Value }
    if has.Intensity then v.Intensity = itm.Intensity.Value / 100 end
    if has.Count then v.Count = itm.Count.Value end
    if has.Frames then
        v[(e[1] == "Echo Stutter") and "Offset" or "Hold"] = itm.Frames.Value
    end
    if has.Amount then v.Amount = itm.Amount.Value / 100 end
    if has.Speed then v.Speed = itm.Speed.Value / 100 end
    local w = itm.Where.CurrentIndex
    local modes = (w == 0) and { "Pre", "Post" } or (w == 1) and { "Pre" } or { "Post" }
    local ok, err = pcall(applyEffect, e, modes, v, setStatus)
    if not ok then setStatus("Error: " .. tostring(err)) end
end

refresh()
win:Show()
disp:RunLoop()
win:Hide()
