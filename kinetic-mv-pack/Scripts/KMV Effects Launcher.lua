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

local LENGTHS = { ["Flash"] = 4, ["Color Flash"] = 4, ["Glow Flash"] = 6, ["Strobe Flash"] = 8, ["Strobe Black"] = 8,
    ["Frame Stutter"] = 8, ["Loop Stutter"] = 8, ["Echo Stutter"] = 8, ["Stutter Flash"] = 10, ["Pulse Stutter"] = 10,
    ["Shake Y"] = 8, ["Shake XY"] = 8, ["Shake Twitch"] = 8, ["Zoom In"] = 6, ["Zoom Pull"] = 6, ["Zoom Blur"] = 6,
    ["Slide Left"] = 6, ["Slide Right"] = 6, ["Slide Up"] = 6, ["Slide Down"] = 6, ["Soft Blur"] = 6, ["Defocus"] = 6,
    ["Directional Blur"] = 6 }

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
    local kinds = {}
    for k in inner:gmatch("\n\t\t\t\t%w+ = (%w+) {") do kinds[#kinds + 1] = k end
    print("KMV: " .. name .. " " .. mode .. " <- KMV " .. name .. " " .. mode .. ".setting [" .. table.concat(kinds, ",") .. "]")

    local plain = inner
    local si = inner:find("Src = Transform {", 1, true)
    local ii = si and inner:find("Inputs = {\n", si, true)
    if not ii then return nil, "source tool missing" end
    local ie = ii + #"Inputs = {\n" - 1
    inner = inner:sub(1, ie) .. '\t\t\t\t\t\tInput = Input { SourceOp = "MediaIn1", Source = "Output", },\n' .. inner:sub(ie + 1)

    local paste = "{\n\tTools = ordered() {\n" .. plain .. "\n\t}\n}\n"
    local comp = table.concat({
        "{\n\tTools = ordered() {\n",
        "\t\t\t\tMediaIn1 = MediaIn {\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { -110, 0 } },\n\t\t\t\t},\n",
        inner, "\n",
        "\t\t\t\tMediaOut1 = MediaOut {\n\t\t\t\t\tInputs = {\n\t\t\t\t\t\tIndex = Input { Value = \"0\", },\n",
        "\t\t\t\t\t\tInput = Input { SourceOp = \"", last, "\", Source = \"Output\", },\n",
        "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 1500, 0 } },\n\t\t\t\t},\n",
        "\t},\n\tActiveTool = \"MediaOut1\"\n}\n" })
    return comp, nil, paste, last
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

local function loadComp(item, path, paste, lastTool)
    local ok, res = pcall(function() return item:ImportFusionComp(path) end)
    print("KMV: ImportFusionComp ->", ok, tostring(res))
    if ok and res then return true, "ImportFusionComp" end

    -- fallback: new comp on the clip, paste the effect tools, wire MediaIn/MediaOut by hand
    local okA, comp = pcall(function() return item:AddFusionComp() end)
    print("KMV: AddFusionComp ->", okA, tostring(comp))
    if not (okA and comp) then
        local okN, names = pcall(function() return item:GetFusionCompNameList() end)
        if okN and type(names) == "table" and names[1] then
            local okG, c2 = pcall(function() return item:GetFusionCompByIndex(1) end)
            print("KMV: GetFusionCompByIndex(1) ->", okG, tostring(c2))
            if okG and c2 then comp = c2 end
        end
    end
    if not comp then return false, "no Fusion comp available on the clip" end
    local okP, resP = pcall(function() return comp:Paste(paste) end)
    print("KMV: comp:Paste ->", okP, tostring(resP))
    if not okP then return false, "comp:Paste failed" end
    local okW, errW = pcall(function()
        local mi, mo = comp:FindTool("MediaIn1"), comp:FindTool("MediaOut1")
        local src, tail = comp:FindTool("Src"), comp:FindTool(lastTool)
        if not (src and tail) then error("pasted tools not found") end
        if mi then src.Input = mi.Output end
        if mo then mo.Input = tail.Output end
    end)
    print("KMV: wiring ->", okW, tostring(errW))
    if not okW then return false, "pasted but wiring failed: " .. tostring(errW) end
    return true, "AddFusionComp+Paste"
end
local function trackOf(item)
    local ok, r = pcall(function() return item:GetTrackTypeAndIndex() end)
    if ok and type(r) == "table" then return r[2] end
    return nil
end

-- Resolve inserts on the targeted track; the API has no target setter, so lock every other
-- video track while inserting, then restore the previous lock states.
local function insertOnTrack(timeline, T)
    local count = timeline:GetTrackCount("video")
    local was = {}
    for i = 1, count do
        if i ~= T then
            local ok, locked = pcall(function() return timeline:GetIsTrackLocked("video", i) end)
            was[i] = ok and locked or false
            pcall(function() timeline:SetTrackLock("video", i, true) end)
        end
    end
    local item = insertClip(timeline)
    for i, locked in pairs(was) do
        pcall(function() timeline:SetTrackLock("video", i, locked) end)
    end
    return item
end

local function deleteItem(timeline, item)
    return pcall(function() return timeline:DeleteClips({ item }, false) end)
end

-- Picks the video track for the effect clips: reuse the top track if empty around the cut,
-- else add a new one above everything. Never moves existing clips.
local function ensureTopTrack(timeline, lo, hi)
    local top = timeline:GetTrackCount("video")
    local busy = false
    for _, it in ipairs(timeline:GetItemListInTrack("video", top) or {}) do
        if it:GetStart() < hi and it:GetEnd() > lo then busy = true break end
    end
    if not busy and top > 1 then return top, false end
    local ok = pcall(function() return timeline:AddTrack("video") end)
    local n = timeline:GetTrackCount("video")
    if ok and n > top then return n, true end
    return nil
end

local function placeOne(timeline, entry, mode, v, p, dir, T, cache)
    local fps = fpsOf(timeline)
    local length = v.Length
    local base = tonumber(timeline:GetStartFrame()) or 0
    local comp, err, paste, lastTool = buildComp(dir, entry[1], mode, v)
    if not comp then return mode .. ": " .. err end
    local path = tmpDir() .. sep .. "KMV_" .. entry[1]:gsub(" ", "_") .. "_" .. mode .. ".comp"
    local fh = io.open(path, "wb")
    if not fh then return mode .. ": cannot write " .. path end
    fh:write(comp)
    fh:close()

    local playhead = timeline:GetCurrentTimecode()
    local rec = (mode == "Post") and p or math.max(base, p - length)
    local item

    -- Method B: append a media pool item with exact length and track (once we have one)
    local function appendExact()
        if not cache.mpi then return nil end
        local ok, res = pcall(function()
            return resolve:GetProjectManager():GetCurrentProject():GetMediaPool():AppendToTimeline({ {
                mediaPoolItem = cache.mpi, startFrame = 0, endFrame = length - 1,
                trackIndex = T, recordFrame = rec, mediaType = 1 } })
        end)
        if ok and type(res) == "table" and res[1] then return res[1] end
        return nil
    end

    item = appendExact()
    if not item then
        timeline:SetCurrentTimecode(framesToTc(rec, fps))
        item = insertOnTrack(timeline, T)
        if not item then
            timeline:SetCurrentTimecode(playhead)
            return mode .. ": the API could not insert an adjustment clip. Add one on the new track manually, then on the Fusion page use Fusion > Import Composition: " .. path
        end
        if mode == "Pre" then
            local dur = item:GetDuration()
            local want = math.max(base, p - dur)
            if dur and want ~= rec then
                deleteItem(timeline, item)
                timeline:SetCurrentTimecode(framesToTc(want, fps))
                item = insertOnTrack(timeline, T)
            end
        end
        -- try to swap for an exact-length clip when a pool item is obtainable
        if item and not cache.mpi then
            local okM, mpi = pcall(function() return item:GetMediaPoolItem() end)
            if okM and mpi then cache.mpi = mpi end
        end
        if item and cache.mpi and not cache.triedExact then
            cache.triedExact = true
            local keepStart = item:GetStart()
            deleteItem(timeline, item)
            local exact = appendExact()
            if exact then
                item = exact
            else
                timeline:SetCurrentTimecode(framesToTc(keepStart, fps))
                item = insertOnTrack(timeline, T)
            end
        end
    end
    timeline:SetCurrentTimecode(playhead)
    if not item then return mode .. ": insertion failed." end

    local landed = trackOf(item)
    local note = ""
    if landed and landed ~= T then
        note = " WARNING: landed on V" .. landed .. ", expected V" .. T .. "."
    elseif not landed then
        note = " (could not verify track)"
    end
    local loaded, how = loadComp(item, path, paste, lastTool)
    if loaded then
        return mode .. ": clip on V" .. tostring(landed or T) .. " (loaded via " .. how .. ") - select it to trim/adjust." .. note
    end
    return mode .. ": clip inserted on V" .. tostring(landed or T) .. note .. " but loading the effect failed (" .. tostring(how) .. "; see Console). Use Fusion > Import Composition: " .. path
end

local function applyEffect(entry, modes, v, setStatus)
    local project = resolve:GetProjectManager():GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not timeline then return setStatus("No timeline is open.") end
    local p = tcToFrames(timeline:GetCurrentTimecode(), fpsOf(timeline))
    if not p then return setStatus("Could not read playhead timecode.") end
    local dir = effectsDir()
    if not dir then return setStatus("KMV presets not found. Run the installer and restart Resolve.") end
    local T, added = ensureTopTrack(timeline, p - v.Length, p + v.Length)
    if not T then return setStatus("Could not find or add a free video track above the clips (AddTrack failed). Add one manually and retry.") end
    local msgs = { (added and "Added track V" or "Using empty top track V") .. T }
    local cache = {}
    for _, mode in ipairs(modes) do
        msgs[#msgs + 1] = placeOne(timeline, entry, mode, v, p, dir, T, cache)
    end
    local out = table.concat(msgs, "\n")
    print("KMV: " .. out)
    setStatus(out)
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
        ui:HGroup { Weight = 0, ui:Label { Text = "Length (frames)" }, ui:SpinBox { ID = "Length", Minimum = 1, Maximum = 30, Value = 8 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Intensity %" }, ui:SpinBox { ID = "Intensity", Minimum = 0, Maximum = 200, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Strobe / stutter count" }, ui:SpinBox { ID = "Count", Minimum = 1, Maximum = 30, Value = 6 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Hold / loop / echo frames" }, ui:SpinBox { ID = "Frames", Minimum = 1, Maximum = 24, Value = 3 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Amount %" }, ui:SpinBox { ID = "Amount", Minimum = 0, Maximum = 300, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Speed %" }, ui:SpinBox { ID = "Speed", Minimum = 10, Maximum = 500, Value = 100 } },
        ui:HGroup { Weight = 0, ui:Label { Text = "Curve" }, ui:ComboBox { ID = "Curve", CurrentIndex = 1 },
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
pcall(function() itm.Curve.CurrentIndex = 1 end)

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
    itm.Length.Value = LENGTHS[e[1]] or 8
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
