--[[
=====================================================================
  ENI // GRESIE AUTOFARM — NextUI edition
  - drives the game's own AutoBuild engine (sapat -> gata)
  - chains house / world progression automatically
  - refills material piles when the local stock hits zero
  - skips stages through the Op ("etapa") remote
  - NextUI interface (diser.me/nextui) + mobile button + PC keybinds
  - falls back to a tiny built-in HUD if NextUI cannot load
  - every option starts OFF on a fresh install, choices are saved
  Keys : F6 auto · F8 skip · F7 menu · F9 next house
=====================================================================
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local Gresie = RS:WaitForChild("Gresie", 30)
if not Gresie then
	return
end

local GENV = getgenv()
if GENV.ENI_GRESIE and type(GENV.ENI_GRESIE.destroy) == "function" then
	pcall(GENV.ENI_GRESIE.destroy)
end

-- wipe interfaces left behind by a previous run
local function purgeOldUI()
	local function clean(parent)
		if not parent then
			return
		end
		local ok, kids = pcall(function()
			return parent:GetChildren()
		end)
		if not ok or type(kids) ~= "table" then
			return
		end
		for _, v in ipairs(kids) do
			if v:IsA("ScreenGui") and (v.Name == "NextUI" or v.Name == "ENI_GresieHUD") then
				pcall(function()
					v:Destroy()
				end)
			end
		end
	end
	pcall(function()
		clean(lp.PlayerGui)
	end)
	pcall(function()
		local core = game:GetService("CoreGui")
		clean(core)
		local container = core:FindFirstChild("Container")
		clean(container)
		local nui = container and container:FindFirstChild("NextUI")
		if nui then
			pcall(function()
				nui:Destroy()
			end)
		end
	end)
	pcall(function()
		if type(get_hui) == "function" then
			clean(get_hui())
		end
	end)
end
purgeOldUI()

local FILE = "eni_gresie_autoplay.luau"
local STATS = "eni_gresie_stats.txt"
local CFG = "eni_gresie_cfg.txt"
local NEXTUI_URL = "https://diser.me/nextui/source.lua"

local IS_MOBILE = UIS.TouchEnabled and not UIS.KeyboardEnabled

local PLACE_NAMES = {
	[87250613004169] = "HOUSE",
	[73046197580120] = "POOL",
	[102433728587631] = "VILLA",
	[113986269985034] = "LOBBY",
}

local ORDER = {
	"sapat", "pietris", "compactare", "fiare", "custi", "turnare", "cofraj", "soclu",
	"caramizi", "placaEtaj", "caramiziEtaj", "acoperis", "acoperisPlat", "atic", "tigle",
	"streasina", "tamplarie", "tavan", "tencuiala", "zugraveala", "ciment", "ciment2",
	"placi", "placi2", "rosturi", "rosturi2", "plinte", "piscinaSapat", "piscina",
	"piscinaApa", "tencuialaAfara", "fatada", "curte", "mobila", "gata",
}
local ORDER_INDEX = {}
for i, k in ipairs(ORDER) do
	ORDER_INDEX[k] = i
end

-- material key used by each stage (piles are refilled with umplePeLoc)
local MAT = {
	caramizi = "BCA",
	caramiziEtaj = "BCA",
	pietris = "PIETRIS",
	tencuiala = "CIMENT",
	tencuialaAfara = "CIMENT",
	ciment = "CIMENT",
	ciment2 = "CIMENT",
	zugraveala = "VOPSEA",
	fatada = "VOPSEA",
	mobila = "MOBILA",
}
local MAT_LIST = { "CIMENT", "VOPSEA", "BCA", "PIETRIS", "MOBILA" }
local MAT_LABEL = {
	CIMENT = "Cement",
	VOPSEA = "Paint",
	BCA = "Bricks",
	PIETRIS = "Gravel",
	MOBILA = "Furniture",
}

---------------------------------------------------------------------
-- EXECUTOR COMPATIBILITY
---------------------------------------------------------------------
local HAS = {
	getgc = type(getgc) == "function",
	writefile = type(writefile) == "function",
	readfile = type(readfile) == "function",
	isfile = type(isfile) == "function",
	queue = type(queue_on_teleport) == "function",
	clearQueue = type(clear_teleport_queue) == "function",
	httpget = type(game.HttpGet) == "function",
}

local function readText(path)
	if not HAS.readfile then
		return nil
	end
	local ok, txt = pcall(readfile, path)
	if ok and type(txt) == "string" then
		return txt
	end
	return nil
end

local function writeText(path, txt)
	if not HAS.writefile then
		return false
	end
	return (pcall(writefile, path, txt))
end

local function log(...)
	local parts = { "[ENI-GRESIE]" }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	print(table.concat(parts, " "))
end

---------------------------------------------------------------------
-- STATE
-- everything is off until the player turns it on
---------------------------------------------------------------------
local S = {
	enabled = false,
	autoSkip = false,
	autoRefill = false,
	autoNext = false,
	watchdog = false,
	persist = false,
	saveCfg = true,

	tick = 1.2,
	maxSkip = 40,
	stuck = 360,

	engine = nil,
	snap = {},
	stage = nil,
	stageSince = os.clock(),
	lastNextAt = 0,
	nextTries = 0,
	countedFor = nil,
	done = 0,
	skipping = false,
	lastErr = nil,
	status = "idle",
	destroyed = false,
	ui = nil,
}
GENV.ENI_GRESIE = S

-- A previous copy of this script keeps its controller loop alive even after
-- the global is replaced. Those ghosts keep calling startEngine() forever,
-- so the character walks around with every option switched off. Mark them
-- dead before doing anything else.
local function killStaleInstances()
	if not HAS.getgc then
		return 0
	end
	local ok, gc = pcall(getgc, true)
	if not ok or type(gc) ~= "table" then
		return 0
	end
	local killed = 0
	for _, v in ipairs(gc) do
		if type(v) == "table" and v ~= S
			and rawget(v, "enabled") ~= nil
			and rawget(v, "engine") ~= nil
			and rawget(v, "tick") ~= nil
			and rawget(v, "stageSince") ~= nil
			and rawget(v, "snap") ~= nil
			and rawget(v, "ui") ~= nil then
			v.destroyed = true
			v.enabled = false
			killed += 1
		end
	end
	return killed
end

local STALE = killStaleInstances()
if STALE > 0 then
	log("stopped", STALE, "stale instance(s)")
end

S.done = tonumber((readText(STATS) or ""):match("%d+") or "0") or 0

local function saveDone()
	writeText(STATS, tostring(S.done))
end

local function saveSettings()
	if S.saveCfg == false then
		return
	end
	local function n(v)
		return v and "1" or "0"
	end
	writeText(CFG, table.concat({
		n(S.enabled), n(S.autoSkip), n(S.autoRefill), n(S.autoNext),
		n(S.persist), n(S.watchdog), tostring(S.tick), tostring(S.maxSkip),
	}, ","))
end

-- restore the player's previous choices, if any
local function loadSettings()
	local txt = readText(CFG)
	if not txt then
		return
	end
	local p = {}
	for chunk in string.gmatch(txt, "[^,]+") do
		p[#p + 1] = chunk
	end
	local function b(v, fallback)
		if v == "1" then
			return true
		elseif v == "0" then
			return false
		end
		return fallback
	end
	S.enabled = b(p[1], S.enabled)
	S.autoSkip = b(p[2], S.autoSkip)
	S.autoRefill = b(p[3], S.autoRefill)
	S.autoNext = b(p[4], S.autoNext)
	S.persist = b(p[5], S.persist)
	S.watchdog = b(p[6], S.watchdog)
	S.tick = tonumber(p[7]) or S.tick
	S.maxSkip = tonumber(p[8]) or S.maxSkip
end

loadSettings()

---------------------------------------------------------------------
-- AUTOBUILD ENGINE
---------------------------------------------------------------------
local function findEngine()
	local cur = S.engine
	if type(cur) == "table" and rawget(cur, "comuta") and rawget(cur, "U") then
		return cur
	end
	if not HAS.getgc then
		return nil
	end
	local ok, gc = pcall(getgc, true)
	if not ok or type(gc) ~= "table" then
		return nil
	end
	for _, v in ipairs(gc) do
		if type(v) == "table"
			and rawget(v, "comuta")
			and rawget(v, "opreste")
			and rawget(v, "activ")
			and rawget(v, "U") then
			S.engine = v
			return v
		end
	end
	return nil
end

local function readState()
	local E = findEngine()
	if not E then
		return nil
	end
	local ok, plot, etapa, slot = pcall(E.U.stare)
	if not ok then
		return nil
	end
	local active = false
	if type(E.activ) == "function" then
		local okA, a = pcall(E.activ)
		active = okA and a == true
	end
	return { eng = E, plot = plot, etapa = etapa, slot = slot, active = active }
end

local function startEngine()
	local E = findEngine()
	if not E then
		return false
	end
	if E.activ and E.activ() then
		return true
	end
	local ok, res = pcall(E.comuta)
	return ok and res == true
end

local function stopEngine()
	local E = findEngine()
	if E then
		pcall(E.opreste)
	end
	-- opreste() bails out early when the engine flag is already false, and a
	-- routine killed mid-run leaves the body anchored and the camera scripted.
	-- Put the player back in control (but leave the end-of-house cinematic).
	local finished = false
	if E and type(E.U) == "table" and type(E.U.stare) == "function" then
		local ok, _, etapa = pcall(E.U.stare)
		finished = ok and etapa == "gata"
	end
	if finished then
		return
	end
	local ch = lp.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if hrp and hrp.Anchored then
		hrp.Anchored = false
	end
	local cam = workspace.CurrentCamera
	if cam and cam.CameraType == Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Custom
	end
end

local function goNextHouse()
	if not Gresie:FindFirstChild("CasaUrmatoare") then
		return false
	end
	local ok, res = pcall(function()
		return Gresie:WaitForChild("CasaUrmatoare", 5):InvokeServer()
	end)
	log("CasaUrmatoare ->", ok and tostring(res) or "error")
	return ok and res
end

---------------------------------------------------------------------
-- TELEPORT PERSISTENCE
---------------------------------------------------------------------
local function setPersistence(on)
	if not HAS.queue then
		return
	end
	pcall(function()
		if on and (not HAS.isfile or isfile(FILE)) then
			queue_on_teleport('loadstring(readfile("' .. FILE .. '"))()')
		elseif HAS.clearQueue then
			clear_teleport_queue()
		end
	end)
end

---------------------------------------------------------------------
-- MATERIALS
---------------------------------------------------------------------
local lastRefill = {}

local function matAre(E)
	if E and E.U and E.U.Mat and type(E.U.Mat.are) == "table" then
		return E.U.Mat.are
	end
	return nil
end

local function refillMaterial(E, key)
	if not E or not E.U.Mat or type(E.U.Mat.umplePeLoc) ~= "function" then
		return false
	end
	local ok = pcall(E.U.Mat.umplePeLoc, key)
	if ok then
		log("refill", key)
	end
	return ok
end

local function refillIfEmpty(E, etapa)
	if not S.autoRefill then
		return
	end
	local key = MAT[etapa]
	if not key then
		return
	end
	local are = matAre(E)
	if not are then
		return
	end
	local stock = are[key]
	if stock == nil or stock >= 1 then
		return
	end
	local now = os.clock()
	if now - (lastRefill[key] or 0) > 3 then
		lastRefill[key] = now
		refillMaterial(E, key)
	end
end

---------------------------------------------------------------------
-- SKIPPING STAGES
-- The server accepts a stage request when it is exactly the next one
-- in the order. It does not verify that the work was actually done.
---------------------------------------------------------------------
local function stageNext(E, etapa)
	if E and E.U and type(E.U.dupa) == "function" then
		local ok, nxt = pcall(E.U.dupa, etapa)
		if ok and type(nxt) == "string" and nxt ~= "" then
			return nxt
		end
	end
	local i = ORDER_INDEX[etapa]
	return i and ORDER[i + 1] or nil
end

local function fireStage(E, etapa, nxt)
	local ok, plot, _, slot = pcall(E.U.stare)
	if not ok then
		return
	end
	local etapaS = (type(plot) == "table" and plot.etapaS) or etapa
	pcall(function()
		Gresie.Op:FireServer("etapa", slot, etapaS, nxt)
	end)
end

function S.skipStep()
	local E = findEngine()
	if not E then
		return false, "engine not found"
	end
	local ok, _, etapa = pcall(E.U.stare)
	if not ok then
		return false, "state unreadable"
	end
	local nxt = stageNext(E, etapa)
	if not nxt then
		return false, "end of list"
	end
	fireStage(E, etapa, nxt)
	task.wait(1.1)
	local _, after = E.U.stare()
	if after == nxt then
		return true, tostring(etapa) .. " -> " .. tostring(nxt)
	end
	return false, "refused on " .. tostring(etapa)
end

function S.skipAll(maxSteps)
	if S.skipping then
		return 0
	end
	S.skipping = true
	local steps = 0
	pcall(function()
		local E = findEngine()
		if not E then
			return
		end
		local _, first = E.U.stare()
		if first == "gata" then
			goNextHouse()
			return
		end
		stopEngine()
		task.wait(0.4)
		for _ = 1, (maxSteps or S.maxSkip or 40) do
			local ok, _, etapa = pcall(E.U.stare)
			if not ok or etapa == "gata" then
				break
			end
			local nxt = stageNext(E, etapa)
			if not nxt then
				break
			end
			fireStage(E, etapa, nxt)
			task.wait(1.1)
			local ok2, _, after = pcall(E.U.stare)
			if not ok2 or after ~= nxt then
				log("skip refused on", tostring(etapa))
				break
			end
			steps += 1
			log("skip", tostring(etapa), "->", tostring(nxt))
		end
	end)
	S.skipping = false
	if S.enabled then
		startEngine()
	end
	return steps
end

---------------------------------------------------------------------
-- CONTROLLER
---------------------------------------------------------------------
local function tickOnce()
	if S.skipping then
		S.status = "skipping"
		return
	end
	local st = readState()
	if st then
		S.snap = st
	end
	if not st then
		S.status = HAS.getgc and "engine not found" or "getgc required"
		return
	end

	if not S.enabled then
		stopEngine()
		S.status = "auto off"
		return
	end

	if st.etapa ~= S.stage then
		S.stage = st.etapa
		S.stageSince = os.clock()
		S.nextTries = 0
	end

	refillIfEmpty(st.eng, st.etapa)

	if st.etapa == "gata" then
		S.status = "house complete"
		local key = tostring(game.JobId) .. "/" .. tostring(type(st.plot) == "table" and st.plot.folder or "?")
		if S.countedFor ~= key then
			S.countedFor = key
			S.done += 1
			saveDone()
		end
		if not S.autoNext then
			S.status = "house complete · manual"
			return
		end
		local gataAt = lp:GetAttribute("CasaGata")
		local cooldown = (gataAt ~= nil) and 15 or 40
		if os.clock() - S.lastNextAt > cooldown and S.nextTries < 10 then
			S.lastNextAt = os.clock()
			S.nextTries += 1
			goNextHouse()
		end
		task.wait(0.5)
		local again = readState()
		if again and again.etapa ~= "gata" then
			S.stage = again.etapa
			S.stageSince = os.clock()
			startEngine()
		end
		return
	end

	S.status = "running"

	if not st.active then
		if startEngine() then
			S.stageSince = os.clock()
			S.status = "engine restarted"
		end
		return
	end

	if S.watchdog and os.clock() - S.stageSince > S.stuck then
		log("stuck on", tostring(st.etapa), "-> restarting")
		S.status = "stuck · restarting"
		stopEngine()
		task.wait(1)
		startEngine()
		S.stageSince = os.clock()
	end
end

local function controller()
	-- GENV.ENI_GRESIE ~= S means a newer copy took over: this loop must die,
	-- otherwise it keeps restarting the build engine behind the new copy's back.
	while not S.destroyed and GENV.ENI_GRESIE == S do
		local ok, err = pcall(tickOnce)
		if not ok then
			S.lastErr = tostring(err)
		end
		task.wait(S.tick)
	end
	S.destroyed = true
end

---------------------------------------------------------------------
-- UI HELPERS
---------------------------------------------------------------------
local ACCENT = Color3.fromRGB(224, 122, 95)
local CREAM = Color3.fromRGB(246, 238, 228)
local DIM = Color3.fromRGB(168, 156, 148)
local BG = Color3.fromRGB(24, 21, 20)

local function stagePct(etapa)
	local i = ORDER_INDEX[etapa] or 0
	if i <= 0 then
		return 0
	end
	return i / #ORDER
end

local MAP_NAME = nil

local function fmtMap()
	local known = PLACE_NAMES[game.PlaceId]
	if known then
		return known
	end
	if MAP_NAME then
		return MAP_NAME
	end
	return "WORLD " .. tostring(game.PlaceId)
end

task.spawn(function()
	if PLACE_NAMES[game.PlaceId] or not HAS.httpget then
		return
	end
	local ok, info = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
	end)
	if ok and type(info) == "table" and info.Name then
		MAP_NAME = tostring(info.Name)
	end
end)

---------------------------------------------------------------------
-- UI : NextUI
---------------------------------------------------------------------
local function buildNextUI(NextUI)
	local ui = { sync = {} }

	NextUI.TextScale = IS_MOBILE and 1.0 or 1.1
	NextUI.TitleCase = false
	NextUI.ToggleKeys = { Enum.KeyCode.Insert, Enum.KeyCode.RightShift }
	NextUI.ConfigFolder = "ENI_Gresie"

	local Win = NextUI:CreateWindow({
		Title = "ENI GRESIE",
		SubTitle = "autofarm · v3",
		Theme = "Dark",
		Size = IS_MOBILE and Vector2.new(520, 360) or Vector2.new(700, 460),
		MinSize = IS_MOBILE and Vector2.new(420, 300) or Vector2.new(560, 380),
		Resizable = true,
		Stars = false,
		Profile = false,
		Search = false,
		Collapsible = false,
		ThemePicker = true,
		MobileButton = {
			Icon = "menu",
			Size = IS_MOBILE and 56 or 48,
			Position = UDim2.new(1, -36, 0.42, 0),
			Draggable = true,
		},
	})
	ui.window = Win

	local Farm = Win:AddTab({ Title = "Farm", Icon = "sprout" })

	local AutoCard = Farm:AddSection({ Title = "Automatic", Icon = "play", Side = "Left" })

	ui.autoToggle = AutoCard:AddToggle({
		Title = "Auto farm",
		Description = "Drives the building engine",
		Flag = "auto_farm",
		Default = S.enabled,
		Keybind = Enum.KeyCode.F6,
		KeyMode = "Toggle",
		Callback = function(v)
			S.setEnabled(v)
		end,
	})
	table.insert(ui.sync, { toggle = ui.autoToggle, get = function()
		return S.enabled
	end })

	local refillToggle = AutoCard:AddToggle({
		Title = "Refill materials",
		Description = "Tops up the pile when stock hits zero",
		Flag = "auto_refill",
		Default = S.autoRefill,
		Callback = function(v)
			S.autoRefill = v and true or false
			saveSettings()
		end,
	})
	table.insert(ui.sync, { toggle = refillToggle, get = function()
		return S.autoRefill
	end })

	local nextToggle = AutoCard:AddToggle({
		Title = "Next house",
		Description = "Chains through CasaUrmatoare",
		Flag = "auto_next",
		Default = S.autoNext,
		Callback = function(v)
			S.autoNext = v and true or false
			saveSettings()
		end,
	})
	table.insert(ui.sync, { toggle = nextToggle, get = function()
		return S.autoNext
	end })

	local watchToggle = AutoCard:AddToggle({
		Title = "Watchdog",
		Description = "Restarts the engine when a stage freezes",
		Flag = "watchdog",
		Default = S.watchdog,
		Callback = function(v)
			S.watchdog = v and true or false
			saveSettings()
		end,
	})
	table.insert(ui.sync, { toggle = watchToggle, get = function()
		return S.watchdog
	end })

	local SkipCard = Farm:AddSection({ Title = "Skip & manual", Icon = "fast-forward", Side = "Right" })

	local skipToggle = SkipCard:AddToggle({
		Title = "Auto skip",
		Description = "Fallback jump when a stage refuses to move",
		Flag = "auto_skip",
		Default = S.autoSkip,
		Callback = function(v)
			S.autoSkip = v and true or false
			saveSettings()
		end,
	})
	table.insert(ui.sync, { toggle = skipToggle, get = function()
		return S.autoSkip
	end })

	SkipCard:AddButton({
		Title = "Skip stages",
		Description = "Walks forward while the server accepts",
		Hold = 0.4,
		Callback = function()
			local n = S.skipAll(S.maxSkip)
			if ui.notify then
				ui.notify(n > 0 and (tostring(n) .. " stage(s) skipped") or "no stage accepted")
			end
		end,
	})

	SkipCard:AddButton({
		Title = "Next house",
		Description = "Forces CasaUrmatoare",
		Callback = function()
			goNextHouse()
		end,
	})

	SkipCard:AddButton({
		Title = "Restart engine",
		Description = "Stop then start",
		Callback = function()
			stopEngine()
			task.wait(0.6)
			startEngine()
		end,
	})

	local StatusCard = Farm:AddSection({ Title = "Status", Icon = "activity", Side = "Full" })

	ui.stageLabel = StatusCard:AddLabel("stage · idle")
	ui.progress = StatusCard:AddProgress({
		Title = "Progress",
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = " %",
		Smooth = true,
	})
	ui.statsLabel = StatusCard:AddLabel("houses 0 · gems 0")

	-- materials
	local Mats = Win:AddTab({ Title = "Materials", Icon = "package" })
	local MatCard = Mats:AddSection({ Title = "Piles", Icon = "package", Side = "Left" })
	ui.stockLabels = {}

	for _, key in ipairs(MAT_LIST) do
		MatCard:AddButton({
			Title = "Fill " .. (MAT_LABEL[key] or key),
			Callback = function()
				local E = findEngine()
				if E then
					refillMaterial(E, key)
				end
			end,
		})
	end

	local StockCard = Mats:AddSection({ Title = "Stock", Icon = "list", Side = "Right" })
	for _, key in ipairs(MAT_LIST) do
		ui.stockLabels[key] = StockCard:AddLabel((MAT_LABEL[key] or key) .. " · —")
	end
	StockCard:AddLabel("Refill checks the pile every 3 s")

	-- options
	local Opt = Win:AddTab({ Title = "Options", Icon = "settings" })
	local PerfCard = Opt:AddSection({ Title = "Performance", Icon = "gauge", Side = "Left" })

	PerfCard:AddSlider({
		Title = "Controller interval",
		Description = "Lower is faster, heavier",
		Flag = "tick",
		Min = 0.4,
		Max = 4,
		Default = S.tick,
		Increment = 0.1,
		Suffix = " s",
		Callback = function(v)
			S.tick = v
			saveSettings()
		end,
	})

	PerfCard:AddSlider({
		Title = "Max skip per press",
		Flag = "max_skip",
		Min = 5,
		Max = 60,
		Default = S.maxSkip,
		Increment = 1,
		Callback = function(v)
			S.maxSkip = math.floor(v)
			saveSettings()
		end,
	})

	PerfCard:AddSlider({
		Title = "Freeze before restart",
		Flag = "stuck",
		Min = 60,
		Max = 900,
		Default = S.stuck,
		Increment = 30,
		Suffix = " s",
		Callback = function(v)
			S.stuck = math.floor(v)
		end,
	})

	local SessCard = Opt:AddSection({ Title = "Session", Icon = "power", Side = "Right" })

	local persistToggle = SessCard:AddToggle({
		Title = "Survive teleport",
		Description = "Re-injects itself in the next world",
		Flag = "persist",
		Default = S.persist,
		Callback = function(v)
			S.persist = v and true or false
			if S.persist and S.enabled then
				setPersistence(true)
			else
				setPersistence(false)
			end
			saveSettings()
		end,
	})
	table.insert(ui.sync, { toggle = persistToggle, get = function()
		return S.persist
	end })

	local saveToggle = SessCard:AddToggle({
		Title = "Remember choices",
		Description = "Keeps your settings between sessions",
		Flag = "save_cfg",
		Default = S.saveCfg,
		Locked = not HAS.writefile,
		LockedReason = "writefile unavailable",
		Callback = function(v)
			S.saveCfg = v and true or false
			if S.saveCfg then
				saveSettings()
			end
		end,
	})
	table.insert(ui.sync, { toggle = saveToggle, get = function()
		return S.saveCfg
	end })

	SessCard:AddButton({
		Title = "Reset house counter",
		Description = "Sets finished houses back to zero",
		Hold = 1,
		Callback = function()
			S.done = 0
			saveDone()
		end,
	})

	SessCard:AddButton({
		Title = "Unload script",
		Description = "Stops everything and closes the UI",
		Hold = 1,
		Callback = function()
			S.destroy()
		end,
	})

	-- theme
	local Look = Win:AddTab({ Title = "Theme", Icon = "palette" })
	local ThemeCard = Look:AddSection({ Title = "Appearance", Icon = "palette" })
	ThemeCard:AddDropdown({
		Title = "Theme",
		Values = { "Dark", "Rose", "Crimson", "Onyx", "Darker", "Light", "Aqua", "Lagoon", "Amethyst", "Emerald", "Toxic", "Noir" },
		Default = "Dark",
		Callback = function(v)
			pcall(function()
				NextUI:SetTheme(v)
			end)
		end,
	})
	ThemeCard:AddLabel("Insert or R-Shift opens / closes the window")
	if IS_MOBILE then
		ThemeCard:AddLabel("Round button on the right edge on mobile")
	end

	local Info = Win:AddTab({ Title = "Info", Icon = "info" })
	local InfoCard = Info:AddSection({ Title = "Commands", Icon = "keyboard", Side = "Left" })
	InfoCard:AddLabel("F6 · auto on / off")
	InfoCard:AddLabel("F8 · skip stages")
	InfoCard:AddLabel("F7 · menu")
	InfoCard:AddLabel("F9 · next house")

	local AboutCard = Info:AddSection({ Title = "Notes", Icon = "book", Side = "Right" })
	AboutCard:AddLabel("Skipping uses the game's own Op remote.")
	AboutCard:AddLabel("Some stages (mobila) need real placement.")
	AboutCard:AddLabel("getgc : " .. (HAS.getgc and "ok" or "missing"))
	AboutCard:AddLabel("writefile : " .. (HAS.writefile and "ok" or "missing"))
	AboutCard:AddLabel("queue_on_teleport : " .. (HAS.queue and "ok" or "missing"))

	-- extra keybinds
	local Keys = Win:AddTab({ Title = "Keys", Icon = "keyboard" })
	local KeyCard = Keys:AddSection({ Title = "Shortcuts", Icon = "keyboard" })

	KeyCard:AddKeybind({
		Title = "Menu",
		Mode = "Press",
		Default = Enum.KeyCode.F7,
		Callback = function()
			Win:Toggle()
		end,
	})
	KeyCard:AddKeybind({
		Title = "Skip stages",
		Mode = "Press",
		Default = Enum.KeyCode.F8,
		Callback = function()
			task.spawn(function()
				S.skipAll(S.maxSkip)
			end)
		end,
	})
	KeyCard:AddKeybind({
		Title = "Next house",
		Mode = "Press",
		Default = Enum.KeyCode.F9,
		Callback = function()
			goNextHouse()
		end,
	})

	ui.notify = function(text)
		pcall(function()
			NextUI:Info("ENI", text)
		end)
	end

	ui.render = function()
		local st = S.snap or {}
		local etapa = st.etapa or "—"
		local map = fmtMap()
		local folder = "—"
		if type(st.plot) == "table" and st.plot.folder then
			folder = tostring(st.plot.folder)
		end
		pcall(function()
			ui.stageLabel:Set(map .. " · " .. folder .. " · " .. etapa .. " · " .. tostring(S.status))
			ui.progress:Set(math.floor(stagePct(etapa) * 100))
			local gems = lp:GetAttribute("Gems") or 0
			ui.statsLabel:Set("houses " .. tostring(S.done) .. " · gems " .. tostring(gems))
		end)
		local are = matAre(st.eng)
		if are then
			for _, key in ipairs(MAT_LIST) do
				local lbl = ui.stockLabels[key]
				if lbl then
					local n = are[key]
					pcall(function()
						lbl:Set((MAT_LABEL[key] or key) .. " · " .. tostring(n and math.floor(n) or 0))
					end)
				end
			end
		end
		for _, entry in ipairs(ui.sync) do
			pcall(function()
				local want = entry.get() and true or false
				if entry.toggle:Get() ~= want then
					entry.toggle:Set(want)
				end
			end)
		end
	end

	return ui
end

---------------------------------------------------------------------
-- UI : minimal fallback (executors that refuse NextUI)
---------------------------------------------------------------------
local function buildFallbackUI()
	local ui = {}
	local old = lp.PlayerGui:FindFirstChild("ENI_GresieHUD")
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ENI_GresieHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Parent = lp.PlayerGui

	local root = Instance.new("Frame")
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -20, 0, 90)
	root.Size = UDim2.new(0, 250, 0, 130)
	root.BackgroundColor3 = BG
	root.BackgroundTransparency = 0.08
	root.BorderSizePixel = 0
	root.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = root

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 12, 0, 8)
	title.Size = UDim2.new(1, -24, 0, 16)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = CREAM
	title.Text = "ENI · FALLBACK"
	title.Parent = root

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Position = UDim2.new(0, 12, 0, 28)
	info.Size = UDim2.new(1, -24, 0, 30)
	info.Font = Enum.Font.Gotham
	info.TextSize = 11
	info.TextWrapped = true
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextColor3 = DIM
	info.Text = "loading…"
	info.Parent = root

	local function makeBtn(text, slot, color, cb)
		local b = Instance.new("TextButton")
		b.Position = UDim2.new(0, 12 + (slot % 2) * 118, 0, slot < 2 and 62 or 94)
		b.Size = UDim2.new(0, 108, 0, 28)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.TextColor3 = Color3.fromRGB(28, 22, 20)
		b.Text = text
		b.Parent = root
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = b
		b.Activated:Connect(cb)
		return b
	end

	ui.autoBtn = makeBtn("AUTO : OFF", 0, ACCENT, function()
		S.setEnabled(not S.enabled)
	end)
	makeBtn("SKIP", 1, Color3.fromRGB(70, 62, 56), function()
		task.spawn(function()
			S.skipAll(S.maxSkip)
		end)
	end)
	makeBtn("NEXT", 2, Color3.fromRGB(70, 62, 56), function()
		goNextHouse()
	end)

	-- floating button for touch users
	local fab = Instance.new("TextButton")
	fab.AnchorPoint = Vector2.new(0.5, 0.5)
	fab.Position = UDim2.new(1, -40, 0.4, 0)
	fab.Size = UDim2.fromOffset(52, 52)
	fab.BackgroundColor3 = ACCENT
	fab.BorderSizePixel = 0
	fab.Font = Enum.Font.GothamBold
	fab.TextSize = 20
	fab.TextColor3 = Color3.fromRGB(28, 22, 20)
	fab.Text = "≡"
	fab.Visible = IS_MOBILE
	fab.Parent = gui
	local fabCorner = Instance.new("UICorner")
	fabCorner.CornerRadius = UDim.new(1, 0)
	fabCorner.Parent = fab
	fab.Activated:Connect(function()
		root.Visible = not root.Visible
	end)

	ui.render = function()
		local st = S.snap or {}
		local etapa = st.etapa or "—"
		pcall(function()
			info.Text = fmtMap() .. " · " .. etapa .. "\n" .. tostring(S.status) .. " · houses " .. tostring(S.done)
			ui.autoBtn.Text = S.enabled and "AUTO : ON" or "AUTO : OFF"
			ui.autoBtn.BackgroundColor3 = S.enabled and ACCENT or Color3.fromRGB(52, 46, 42)
		end)
	end

	ui.notify = function(text)
		info.Text = tostring(text)
	end

	ui.destroy = function()
		if gui then
			gui:Destroy()
		end
	end

	return ui
end

---------------------------------------------------------------------
-- UI SELECTION
---------------------------------------------------------------------
local ui
local NextUI = nil

if HAS.httpget then
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet(NEXTUI_URL))()
	end)
	if ok and type(lib) == "table" and type(lib.CreateWindow) == "function" then
		NextUI = lib
	end
end

if NextUI then
	local ok, res = pcall(buildNextUI, NextUI)
	if ok then
		ui = res
	else
		log("NextUI failed:", tostring(res))
		pcall(function()
			NextUI:Destroy()
		end)
		NextUI = nil
	end
end

if not ui then
	ui = buildFallbackUI()
	log("falling back to the minimal HUD")
end

S.ui = ui

---------------------------------------------------------------------
-- SHARED ACTIONS
---------------------------------------------------------------------
function S.setEnabled(on)
	S.enabled = on and true or false
	if S.enabled then
		-- a farm that dies on every teleport is useless, so arm the
		-- reload as soon as the player switches the farm on
		if not S.persist then
			S.persist = true
		end
		setPersistence(true)
		startEngine()
	else
		stopEngine()
		setPersistence(false)
	end
	saveSettings()
	log("AUTO", S.enabled and "ON" or "OFF")
end

S.goNext = goNextHouse

-- keeps the interface in sync with the real state
task.spawn(function()
	while not S.destroyed and GENV.ENI_GRESIE == S do
		pcall(function()
			ui.render()
		end)
		task.wait(0.5)
	end
end)

-- backup keybinds (only used when NextUI is unavailable)
UIS.InputBegan:Connect(function(input, processed)
	if processed or S.destroyed or NextUI then
		return
	end
	if input.KeyCode == Enum.KeyCode.F6 then
		S.setEnabled(not S.enabled)
	elseif input.KeyCode == Enum.KeyCode.F8 then
		task.spawn(function()
			S.skipAll(S.maxSkip)
		end)
	end
end)

---------------------------------------------------------------------
-- STARTUP
---------------------------------------------------------------------
if S.enabled then
	if S.persist then
		setPersistence(true)
	end
	startEngine()
else
	S.status = "idle · auto off"
	stopEngine()
end

task.spawn(controller)

log("ready ·", fmtMap(), HAS.getgc and "getgc ok" or "getgc missing", S.enabled and "auto ON" or "auto OFF")

S.destroy = function()
	S.destroyed = true
	pcall(stopEngine)
	setPersistence(false)
	if NextUI then
		pcall(function()
			NextUI:Destroy()
		end)
	end
	if ui and type(ui.destroy) == "function" then
		pcall(ui.destroy)
	end
	pcall(purgeOldUI)
	GENV.ENI_GRESIE = nil
end
