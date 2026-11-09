-- KMV Effects Launcher
-- Resolve: Workspace > Scripts > Edit > KMV Effects Launcher
-- Search/pick a KMV effect, then press PRE / BOTH / POST. An adjustment-style clip is inserted
-- at the playhead containing a Fusion comp (MediaIn -> KMV macro tools -> MediaOut), so the clip
-- can be selected, trimmed/stretched and tweaked in the Inspector/Fusion afterwards.
-- PRE: clip ends at the playhead. POST: clip starts at the playhead.
-- UNTESTED in Resolve: API calls are tried in order with clear fallback messages.

local resolve = resolve or Resolve()
local fu = fusion or Fusion()
if not resolve or not fu then
    print("KMV: must be run from Resolve's Workspace > Scripts menu.")
    return
end

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)
local isWin = (package.config:sub(1, 1) == "\\")
local sep = isWin and "\\" or "/"

-- { name, category, description, enabled optional controls, defaults }
local EFFECTS = {
    { "Flash", "EFFECT", "White flash peaking on the cut, then decaying.", { "Intensity" }, {} },
    { "Color Flash", "EFFECT", "Orange flash (change RGB in the Inspector).", { "Intensity" }, {} },
    { "Glow Flash", "EFFECT", "Bright glowing bloom flash.", { "Intensity" }, {} },
    { "Strobe Flash", "EFFECT", "Rapid on/off white strobe. Set Count.", { "Intensity", "Count" }, { Count = 6 } },
    { "Strobe Black", "EFFECT", "Rapid strobe to black. Set Count.", { "Intensity", "Count" }, { Count = 6 } },
    { "Frame Stutter", "EFFECT", "Freeze-repeat: holds a frame N frames, then jumps.", { "Frames" }, { Frames = 3 } },
    { "Loop Stutter", "EFFECT", "Repeats a short N-frame loop.", { "Frames" }, { Frames = 4 } },
    { "Echo Stutter", "EFFECT", "Trailing ghost frames; Frames = spacing.", { "Intensity", "Frames" }, { Frames = 2 } },
    { "Stutter Flash", "EFFECT", "Frame freeze plus strobing flash.", { "Intensity", "Count", "Frames" }, { Count = 4, Frames = 3, Intensity = 80 } },
    { "Pulse Stutter", "EFFECT", "Rhythmic zoom pulses; Count = pulses.", { "Intensity", "Count", "Amount" }, { Count = 5 } },
    { "Soft Blur", "EFFECT", "Gaussian blur ramp.", { "Amount" }, {} },
    { "Defocus", "EFFECT", "Lens-style defocus ramp.", { "Amount" }, {} },
    { "Directional Blur", "EFFECT", "Linear motion blur.", { "Amount" }, {} },
    { "Shake Y", "MOTION", "Vertical shake that settles.", { "Amount", "Speed" }, { Speed = 300 } },
    { "Shake XY", "MOTION", "Handheld-style shake with rotation.", { "Amount", "Speed" }, { Speed = 300 } },
    { "Shake Twitch", "MOTION", "Sudden random jolts (Seed changes the pattern).", { "Amount", "Speed" }, { Speed = 150 } },
    { "Zoom In", "MOTION", "Punch-in zoom peaking on the cut.", { "Amount" }, {} },
    { "Zoom Pull", "MOTION", "Pull-back zoom (shows edges).", { "Amount" }, {} },
    { "Zoom Blur", "MOTION", "Zoom with radial blur.", { "Amount" }, {} },
    { "Slide Left", "MOTION", "Slides the picture left.", { "Amount" }, {} },
    { "Slide Right", "MOTION", "Slides the picture right.", { "Amount" }, {} },
    { "Slide Up", "MOTION", "Slides the picture up.", { "Amount" }, {} },
    { "Slide Down", "MOTION", "Slides the picture down.", { "Amount" }, {} },
}

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

local function tmpDir() return os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp" end

-- favourites persisted to a small text file (one name per line)
local favPath = (isWin and (os.getenv("APPDATA") or tmpDir()) or ((os.getenv("HOME") or tmpDir()) .. "/Library/Application Support")) .. sep .. "KMV_favourites.txt"
local favs = {}
do
    local f = io.open(favPath, "r")
    if f then
        for line in f:lines() do line = line:gsub("%s+$", ""); if line ~= "" then favs[line] = true end end
        f:close()
    end
end
local function saveFavs()
    local f = io.open(favPath, "w")
    if not f then return false end
    for _, e in ipairs(EFFECTS) do if favs[e[1]] then f:write(e[1], "\n") end end
    f:close()
    return true
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

local function fpsOf(timeline)
    return math.floor((tonumber(timeline:GetSetting("timelineFrameRate")) or 24) + 0.5)
end

local function tcToFrames(tc, fps)
    local h, m, s, f = (tc or ""):match("(%d+)[:;](%d+)[:;](%d+)[:;](%d+)")
    if not h then return nil end
    return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * fps + tonumber(f)
end

local function framesToTc(n, fps)
    local f = n % fps
    local s = math.floor(n / fps) % 60
    local m = math.floor(n / (fps * 60)) % 60
    local h = math.floor(n / (fps * 3600))
    return string.format("%02d:%02d:%02d:%02d", h, m, s, f)
end

-- Insert an adjustment-style clip at the current playhead. Tries several APIs.
local function insertClip(timeline)
    local tries = {
        function() return timeline:InsertGeneratorIntoTimeline("Adjustment Clip") end,
        function() return timeline:InsertFusionGeneratorIntoTimeline("Adjustment Clip") end,
        function() return timeline:InsertFusionCompositionIntoTimeline() end,
    }
    for _, fn in ipairs(tries) do
        local ok, item = pcall(fn)
        if ok and item then return item end
    end
    return nil
end

local function loadComp(item, path)
    local ok, res = pcall(function() return item:ImportFusionComp(path) end)
    if ok and res then return true end
    local ok2, res2 = pcall(function() return item:AddFusionComp() end)
    return false
end

local function placeOne(timeline, entry, mode, v, p, dir)
    local fps = fpsOf(timeline)
    local comp, err = buildComp(dir, entry[1], mode, v)
    if not comp then return mode .. ": " .. err end
    local path = tmpDir() .. sep .. "KMV_" .. entry[1]:gsub(" ", "_") .. "_" .. mode .. ".comp"
    local fh = io.open(path, "wb")
    if not fh then return mode .. ": cannot write " .. path end
    fh:write(comp)
    fh:close()

    local playhead = timeline:GetCurrentTimecode()
    timeline:SetCurrentTimecode(framesToTc(p, fps))
    local item = insertClip(timeline)
    if not item then
        timeline:SetCurrentTimecode(playhead)
        return mode .. ": this Resolve could not insert an adjustment clip via the API. Add an Adjustment Clip on the track above manually, then on the Fusion page choose Fusion > Import Composition: " .. path
    end
    if mode == "Pre" then
        -- shift the clip so it ends at the cut instead of starting there
        local dur = item:GetDuration()
        local okDel = pcall(function() return timeline:DeleteClips({ item }, false) end)
        local start = math.max(0, p - dur)
        timeline:SetCurrentTimecode(framesToTc(start, fps))
        item = insertClip(timeline)
        if not item then
            timeline:SetCurrentTimecode(playhead)
            return mode .. ": re-insert failed (" .. (okDel and "clip removed" or "old clip kept") .. ")"
        end
    end
    timeline:SetCurrentTimecode(playhead)
    if loadComp(item, path) then
        return mode .. ": inserted '" .. tostring(item:GetName()) .. "' - select it to adjust/trim; controls are in the Fusion page / Inspector."
    end
    return mode .. ": clip inserted but loading the effect failed. On the Fusion page use Fusion > Import Composition: " .. path
end

local function applyEffect(entry, modes, v, setStatus)
    local project = resolve:GetProjectManager():GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not timeline then return setStatus("No timeline is open.") end
    local p = tcToFrames(timeline:GetCurrentTimecode(), fpsOf(timeline))
    if not p then return setStatus("Could not read playhead timecode.") end
    local dir = effectsDir()
    if not dir then return setStatus("KMV presets not found. Run the installer and restart Resolve.") end
    local msgs = {}
    for _, mode in ipairs(modes) do
        msgs[#msgs + 1] = placeOne(timeline, entry, mode, v, p, dir)
    end
    setStatus(table.concat(msgs, "\n"))
end

local function buildUI()
local win = disp:AddWindow({
    ID = "KMVWin", WindowTitle = "KMV Effects Launcher", Geometry = { 200, 150, 640, 640 },
    ui:VGroup {
        ui:HGroup { Weight = 0,
            ui:LineEdit { ID = "Search", PlaceholderText = "Search effects..." },
            ui:ComboBox { ID = "Filter", Weight = 0 },
        },
        ui:Tree { ID = "List", Weight = 1, HeaderHidden = true, SortingEnabled = false },
        ui:Label { ID = "Desc", WordWrap = true, Weight = 0, Text = "" },
        ui:Button { ID = "Fav", Text = "Favourite", Weight = 0 },
        ui:HGroup { Weight = 0, ui:Label { Text = "Length (frames)" }, ui:SpinBox { ID = "Length", Minimum = 1, Maximum = 120, Value = 12 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Intensity %" }, ui:SpinBox { ID = "Intensity", Minimum = 0, Maximum = 200, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Strobe / stutter count" }, ui:SpinBox { ID = "Count", Minimum = 1, Maximum = 30, Value = 6 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Hold / loop / echo frames" }, ui:SpinBox { ID = "Frames", Minimum = 1, Maximum = 24, Value = 3 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Amount %" }, ui:SpinBox { ID = "Amount", Minimum = 0, Maximum = 300, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Speed %" }, ui:SpinBox { ID = "Speed", Minimum = 10, Maximum = 500, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Curve" }, ui:ComboBox { ID = "Curve" },
            ui:Label { Text = "Seed" }, ui:SpinBox { ID = "Seed", Minimum = 0, Maximum = 999, Value = 1 },
            ui:Button { ID = "Rand", Text = "Randomize" } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Motion blur %" }, ui:SpinBox { ID = "MB", Minimum = 0, Maximum = 200, Value = 0 },
            ui:Label { Text = "Brightness %" }, ui:SpinBox { ID = "Bri", Minimum = -100, Maximum = 200, Value = 0 } },
        ui:HGroup { Weight = 0,
            ui:Button { ID = "Pre", Text = "PRE" },
            ui:Button { ID = "Both", Text = "BOTH" },
            ui:Button { ID = "Post", Text = "POST" } },
        ui:Label { ID = "Status", WordWrap = true, Text = "", Weight = 0 },
    },
})
local itm = win:GetItems()

itm.Filter:AddItem("ALL")
itm.Filter:AddItem("EFFECTS")
itm.Filter:AddItem("MOTION")
itm.Filter:AddItem("FAVS")
for _, c in ipairs({ "Smooth", "Sharp", "S", "Linear" }) do itm.Curve:AddItem(c) end

local visible = {}
local function setStatus(t) itm.Status.Text = t end

local function rebuildList()
    local q = (itm.Search.Text or ""):lower()
    local flt = itm.Filter.CurrentText
    itm.List:Clear()
    visible = {}
    for _, e in ipairs(EFFECTS) do
        local okF = (flt == "ALL") or (flt == "FAVS" and favs[e[1]]) or (flt == "EFFECTS" and e[2] == "EFFECT") or (flt == "MOTION" and e[2] == "MOTION")
        if okF and (q == "" or e[1]:lower():find(q, 1, true) or e[3]:lower():find(q, 1, true)) then
            local it = itm.List:NewItem()
            it.Text[0] = (favs[e[1]] and "* " or "") .. e[1]
            itm.List:AddTopLevelItem(it)
            visible[#visible + 1] = e
        end
    end
    if #visible > 0 then
        local okF, first = pcall(function() return itm.List:TopLevelItem(0) end)
        if okF and first then
            pcall(function() first.Selected = true end)
            pcall(function() itm.List.CurrentItem = first end)
        end
    end
end

local function current()
    local it = itm.List.CurrentItem
    if type(it) == "function" then
        local ok, r = pcall(function() return itm.List:CurrentItem() end)
        it = ok and r or nil
    end
    if not it then return nil end
    local okT, txt = pcall(function() return it.Text[0] end)
    local name = tostring(okT and txt or ""):gsub("^%* ", "")
    for _, e in ipairs(visible) do if e[1] == name then return e end end
    return nil
end

local function refresh()
    local e = current()
    if not e then itm.Desc.Text = "" return end
    itm.Desc.Text = e[3] .. "\nPRE ramps in over the last frames before the cut; POST bursts at the cut and fades out."
    itm.Fav.Text = favs[e[1]] and "Unfavourite" or "Favourite"
    local has = {}
    for _, k in ipairs(e[4]) do has[k] = true end
    for _, k in ipairs({ "Intensity", "Count", "Frames", "Amount", "Speed" }) do
        itm[k].Enabled = has[k] or false
    end
    local d = e[5]
    itm.Intensity.Value = d.Intensity or 100
    itm.Count.Value = d.Count or 6
    itm.Frames.Value = d.Frames or 3
    itm.Amount.Value = d.Amount or 100
    itm.Speed.Value = d.Speed or 100
end

function win.On.Search.TextChanged(ev) rebuildList() refresh() end
function win.On.Filter.CurrentIndexChanged(ev) rebuildList() refresh() end
function win.On.List.CurrentItemChanged(ev) refresh() end
function win.On.List.ItemClicked(ev) refresh() end
function win.On.KMVWin.Close(ev) disp:ExitLoop() end

function win.On.Fav.Clicked(ev)
    local e = current()
    if not e then return end
    favs[e[1]] = (not favs[e[1]]) or nil
    if not saveFavs() then setStatus("Could not save favourites to " .. favPath) end
    rebuildList() refresh()
end

function win.On.Rand.Clicked(ev) itm.Seed.Value = math.random(1, 999) end

local function go(modes)
    local e = current()
    if not e then return setStatus("Pick an effect first.") end
    local has = {}
    for _, k in ipairs(e[4]) do has[k] = true end
    local v = { Length = itm.Length.Value, Curve = itm.Curve.CurrentIndex, Seed = itm.Seed.Value,
        MotionBlur = itm.MB.Value / 100, Brightness = itm.Bri.Value / 100 }
    if has.Intensity then v.Intensity = itm.Intensity.Value / 100 end
    if has.Count then v.Count = itm.Count.Value end
    if has.Frames then v[(e[1] == "Echo Stutter") and "Offset" or "Hold"] = itm.Frames.Value end
    if has.Amount then v.Amount = itm.Amount.Value / 100 end
    if has.Speed then v.Speed = itm.Speed.Value / 100 end
    local ok, err = pcall(applyEffect, e, modes, v, setStatus)
    if not ok then setStatus("Error: " .. tostring(err)) end
end

function win.On.Pre.Clicked(ev) go({ "Pre" }) end
function win.On.Both.Clicked(ev) go({ "Pre", "Post" }) end
function win.On.Post.Clicked(ev) go({ "Post" }) end

rebuildList()
refresh()
win:Show()
disp:RunLoop()
win:Hide()
end

local okUI, errUI = pcall(buildUI)
if not okUI then print("KMV launcher error: " .. tostring(errUI)) end
