--[[ hatch.lua — Auto Hatch + Auto Sell (Stage 1).
     - Team-swap dengan GUARD: team ga diproses kalau yg ke-equip udah sesuai.
     - Auto Hatch: equip hatch team -> hatch semua egg READY -> hitung cycle.
     - Auto Sell: pet yg COCOK filter dijual; sisanya DIFAVORITIN biar aman.
       Favorite via Favorite_Item (toggle), jual via SellPet_RE / SellAllPets_RE.
     Catatan: auto-place egg baru & bronto phase = stage berikutnya. ]]
return function(ctx)
	local RS = game:GetService("ReplicatedStorage")
	local LP = ctx.LP
	local CFG = ctx.CFG
	local DataService = ctx.deps.DataService
	local PetsRemote = RS.GameEvents.PetsService
	local FavoriteRemote = RS.GameEvents:FindFirstChild("Favorite_Item")
	local SellPet = RS.GameEvents:FindFirstChild("SellPet_RE")
	local SellAll = RS.GameEvents:FindFirstChild("SellAllPets_RE")
	local EggRemote = RS.GameEvents.PetEggService
	local FAV_KEY = "d"
	pcall(function() FAV_KEY = require(RS.Data.EnumRegistry.InventoryServiceEnums).Favorite end)

	-- LISTEN notif game = recovery ASLI (1 notif = 1 egg balik). Sumber paling akurat.
	--   Hatch: "Lucky Hatch! Your egg has been recovered."
	--   Sell : "Lucky Pet! You got a ... egg back from selling your pet!"
	do
		local g = (getgenv and getgenv()) or _G
		if g.__hatchNotifConn then pcall(function() g.__hatchNotifConn:Disconnect() end) end
		local NotifRemote = RS.GameEvents:FindFirstChild("Notification")
		if NotifRemote then
			g.__hatchNotifConn = NotifRemote.OnClientEvent:Connect(function(msg)
				if type(msg) ~= "string" or not CFG.hatchEnabled then return end
				local l = msg:lower()
				if l:find("egg has been recovered") then
					ctx.state.periodHatchRec = (ctx.state.periodHatchRec or 0) + 1
					onHatchNotif()   -- rekam timestamp notif Lucky Hatch masuk
				elseif l:find("egg back from selling") then
					ctx.state.periodSellRec = (ctx.state.periodSellRec or 0) + 1
					onSellNotif()    -- rekam timestamp notif Lucky Sell masuk
				end
			end)
		end
	end

	----------------------------------------------------------------- Smart Delay Tracker
	-- Belajar dari data nyata: berapa detik server kirim notif Lucky Hatch / Lucky Sell
	-- setelah FireServer. Rolling average 10 sample terakhir → dipakai gantiin task.wait statis.
	local DEL = {
		hatchFires  = {},   -- queue os.clock() tiap FireServer("HatchPet")
		sellFires   = {},   -- queue os.clock() tiap FireServer Sell
		hatchDelays = {},   -- sampel delay (detik) hatch→notif
		sellDelays  = {},   -- sampel delay (detik) sell→notif
		avgHatch    = nil,  -- rolling avg (nil = belum cukup data, pakai fallback)
		avgSell     = nil,
	}
	ctx.state.hatchDelayTracker = DEL

	local ROLLING_N = 10
	local function rollingAvg(tbl)
		local n = math.min(#tbl, ROLLING_N)
		if n == 0 then return nil end
		local sum = 0
		for i = #tbl - n + 1, #tbl do sum = sum + tbl[i] end
		return sum / n
	end

	-- Waktu tunggu adaptif (fallback 1.5 s kalau belum ada data)
	local function adaptiveWaitHatch()
		return DEL.avgHatch and math.max(1.0, DEL.avgHatch + 0.5) or 1.5
	end
	local function adaptiveWaitSell()
		return DEL.avgSell and math.max(1.0, DEL.avgSell + 0.5) or 1.5
	end

	-- Dipanggil tepat setelah FireServer("HatchPet")
	local function recordHatchFire()
		DEL.hatchFires[#DEL.hatchFires + 1] = os.clock()
	end
	-- Dipanggil tepat setelah FireServer Sell (SellPet/SellAll)
	local function recordSellFire()
		DEL.sellFires[#DEL.sellFires + 1] = os.clock()
	end
	-- Dipanggil saat notif "Lucky Hatch" masuk
	local function onHatchNotif()
		local now = os.clock()
		if #DEL.hatchFires > 0 then
			local delay = now - table.remove(DEL.hatchFires, 1)
			if delay > 0 and delay < 30 then
				DEL.hatchDelays[#DEL.hatchDelays + 1] = delay
				DEL.avgHatch = rollingAvg(DEL.hatchDelays)
			end
		end
	end
	-- Dipanggil saat notif "Lucky Sell" masuk
	local function onSellNotif()
		local now = os.clock()
		if #DEL.sellFires > 0 then
			local delay = now - table.remove(DEL.sellFires, 1)
			if delay > 0 and delay < 30 then
				DEL.sellDelays[#DEL.sellDelays + 1] = delay
				DEL.avgSell = rollingAvg(DEL.sellDelays)
			end
		end
	end

	-- Expose info ke UI
	function ctx.getSmartDelayInfo()
		local nh = math.min(#DEL.hatchDelays, ROLLING_N)
		local ns = math.min(#DEL.sellDelays, ROLLING_N)
		return {
			avgHatchDelay = DEL.avgHatch,
			avgSellDelay  = DEL.avgSell,
			hatchSamples  = nh,
			sellSamples   = ns,
			hatchWait     = adaptiveWaitHatch(),
			sellWait      = adaptiveWaitSell(),
			isLearning    = nh < ROLLING_N or ns < ROLLING_N,
		}
	end

	----------------------------------------------------------------- util
	local function getData() local ok, d = pcall(function() return DataService:GetData() end); return ok and d or nil end
	local function inventory() local d = getData(); return d and d.PetsData and d.PetsData.PetInventory and d.PetsData.PetInventory.Data or {} end
	local function equippedList() local d = getData(); return d and d.PetsData and d.PetsData.EquippedPets or {} end

	local function farmCenter()
		local GetFarm = require(RS.Modules.GetFarm)
		local farm = GetFarm and GetFarm(LP)
		local pa = farm and farm:FindFirstChild("PetArea")
		if pa then return pa.Position end
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		return hrp and hrp.Position or nil
	end
	local slotOf, nextSlot = {}, 0
	local function getPos(uuid)
		if not slotOf[uuid] then slotOf[uuid] = nextSlot; nextSlot = nextSlot + 1 end
		local c = farmCenter(); if not c then return nil end
		local i = slotOf[uuid]
		return c + Vector3.new((i % 6 - 2.5) * 3, 0, (math.floor(i / 6) - 1) * 3)
	end

	----------------------------------------------------------------- TEAM + GUARD
	-- ActivePetsService: sumber pet yg beneran AKTIF (model spawn + passive kebaca).
	local ActivePets; pcall(function() ActivePets = require(RS.Modules.PetServices.ActivePetsService) end)
	-- teamSet = { [uuid]=true }. Return true kalau equipped PERSIS == teamSet.
	local function teamMatches(teamSet)
		if not next(teamSet or {}) then return true end -- team kosong = ga usah proses
		local eq = equippedList()
		local eqSet, eqN = {}, 0
		for _, u in ipairs(eq) do eqSet[u] = true; eqN = eqN + 1 end
		local tN = 0
		for u in pairs(teamSet) do if not eqSet[u] then return false end; tN = tN + 1 end
		return eqN == tN
	end
	-- Semua anggota team udah AKTIF di garden (ClientPetState) -> passive-nya kebaca.
	local function teamActive(teamSet)
		if not next(teamSet or {}) then return true end
		if not ActivePets or not ActivePets.ClientPetState then return true end -- ga bisa cek -> anggap ok
		local cps = ActivePets.ClientPetState[LP.Name]
		if not cps then return false end
		for u in pairs(teamSet) do if cps[u] == nil then return false end end
		return true
	end

	-- 1 pass: cabut non-team, pasang anggota team yg belum ke-equip.
	local function equipTeamOnce(teamSet)
		local keep = {}
		for u in pairs(teamSet) do keep[u] = true end
		for _, u in ipairs(equippedList()) do
			if not keep[u] then
				pcall(function() PetsRemote:FireServer("UnequipPet", u) end)
				task.wait(0.1)
			end
		end
		local eqNow = {}
		for _, u in ipairs(equippedList()) do eqNow[u] = true end
		for u in pairs(teamSet) do
			if not eqNow[u] then
				local pos = getPos(u)
				if pos then pcall(function() PetsRemote:FireServer("EquipPet", u, CFrame.new(pos)) end); task.wait(0.15) end
			end
		end
	end

	-- Equip team: BLOK sampai team LENGKAP ter-equip (data). Boost/passive (bronto/koi/seal)
	-- diterapin server-side pas pet KE-EQUIP, BUKAN pas model kerender di client. ClientPetState
	-- (spawn model) cuma dipake sbg sinyal cepat kalau kebaca — tapi di LOW PERFORMANCE MODE
	-- model pet sering ga spawn, jadi JANGAN jadiin gate. Kalau ga kebaca aktif, tetap lanjut
	-- setelah settle delay (team udah ke-equip = boost udah masuk server).
	local function equipTeam(teamSet, label)
		if not next(teamSet or {}) then return true end
		if teamMatches(teamSet) and teamActive(teamSet) then return true end -- fast path
		ctx.state.hatchStatus = (label or "Team") .. ": equipping..."
		-- 1) pasang sampai data-equipped lengkap
		for _ = 1, 6 do
			if teamMatches(teamSet) then break end
			equipTeamOnce(teamSet)
			task.wait(0.2)
		end
		if not teamMatches(teamSet) then return false end -- beneran ga bisa equip -> gagal
		-- 2) best-effort tunggu pet aktif (model spawn) — poll max ~4s. Begitu kebaca, lanjut.
		for _ = 1, 20 do
			if teamActive(teamSet) then return true end
			ctx.state.hatchStatus = (label or "Team") .. ": nunggu pet aktif..."
			task.wait(0.2)
		end
		-- 3) ga kebaca aktif (kemungkinan low-perf, model ga spawn) TAPI udah ke-equip di data.
		--    Boost server tetap kepasang -> LANJUT (jgn skip). Settle bentar buat jaga2.
		ctx.state.hatchStatus = (label or "Team") .. ": ke-equip (settle)..."
		task.wait(1.5)
		return true
	end

	----------------------------------------------------------------- FAVORITE / SELL
	local function petTools()
		local out = {}
		local bp = LP:FindFirstChildOfClass("Backpack")
		for _, src in ipairs({ bp, LP.Character }) do
			if src then for _, t in ipairs(src:GetChildren()) do
				if t:IsA("Tool") and t:GetAttribute("PET_UUID") then out[#out + 1] = t end
			end end
		end
		return out
	end
	local function isFav(tool) return tool:GetAttribute(FAV_KEY) == true end
	local function setFav(tool, want)
		if isFav(tool) ~= want and FavoriteRemote then
			pcall(function() FavoriteRemote:FireServer(tool) end); task.wait(0.06)
		end
	end

	-- filter disimpan pakai label "Pet - Egg"; cocokin pakai label yg sama.
	local petEggLabel = (ctx.reg and ctx.reg.petEggLabel) or function(p) return p end
	-- apakah pet ini termasuk yg DIJUAL (cocok filter)?
	-- PENTING: pakai berat TAMPIL (BaseWeight*(1+0.1*Level)) = yg keliatan di game/dropdown,
	-- BUKAN BaseWeight mentah (beda angka -> salah keep/favorite). Weight & Age = AND
	-- (harus dua-duanya kepenuhi; 0 = filter itu dimatiin).
	local function shouldSell(petType, pd)
		pd = pd or {}
		local age = pd.Level or 0
		local w = (pd.BaseWeight or 0) * (1 + 0.1 * age)
		local key = petEggLabel(petType)
		if (CFG.sellPetTypes or {})[key] then
			local wt = CFG.sellWeightThreshold or 0
			local at = CFG.sellAgeThreshold or 0
			local wOk = wt <= 0 or w < wt
			local aOk = at <= 0 or age < at
			if (wt > 0 or at > 0) and wOk and aOk then return true end
		end
		if (CFG.sellSpecialTypes or {})[key] then
			local sw = CFG.sellSpecialWeight or 0
			if sw > 0 and w < sw then return true end
		end
		return false
	end

	-- Jalankan sell: pet yg keep -> favorit; pet yg dijual -> unfavorit lalu jual.
	local function doSell()
		-- GUARD: filter kosong -> batalin (biar ga ada kecelakaan)
		if not next(CFG.sellPetTypes or {}) and not next(CFG.sellSpecialTypes or {}) then
			ctx.state.hatchStatus = "Sell dibatalin: filter 'Pets to Sell' kosong"
			return 0
		end
		local inv = inventory()
		local keeps, sells = {}, {}
		for _, t in ipairs(petTools()) do
			local uuid = t:GetAttribute("PET_UUID")
			local v = inv[uuid]
			local pt = (v and v.PetType) or t:GetAttribute("f")
			local pd = v and v.PetData
			if isFav(t) then
				keeps[#keeps + 1] = t              -- udah favorit = MUTLAK ga dijual (walau filter cocok)
			elseif shouldSell(pt, pd) then
				sells[#sells + 1] = t
			else
				keeps[#keeps + 1] = t
			end
		end

		if CFG.sellStyle == "All at Once" then
			-- proteksi: favoritin semua keep, unfavorit yg mau dijual
			ctx.state.hatchStatus = "Selling: favorit proteksi..."
			for _, t in ipairs(keeps) do setFav(t, true) end
			for _, t in ipairs(sells) do setFav(t, false) end
			-- VERIFY: tunggu sync + cek SEMUA keep bener favorit; retry; abort kalau gagal.
			local safe = false
			for _ = 1, 4 do
				task.wait(0.5)
				local bad = {}
				for _, t in ipairs(keeps) do if t.Parent and not isFav(t) then bad[#bad + 1] = t end end
				if #bad == 0 then safe = true; break end
				ctx.state.hatchStatus = ("Verify: %d keep-pet belum favorit, retry..."):format(#bad)
				for _, t in ipairs(bad) do setFav(t, true) end
			end
			if not safe then
				ctx.state.hatchStatus = "Sell DIBATALIN: ada keep-pet belum favorit (aman, ga jadi jual)"
				return 0
			end
			if SellAll then pcall(function() SellAll:FireServer() end) end
			recordSellFire()   -- catat waktu fire untuk Smart Delay Tracker
			ctx.state.hatchSellCycles = (ctx.state.hatchSellCycles or 0) + 1
			ctx.state.hatchStatus = ("Sold all-at-once (%d matched)"):format(#sells)
			return #sells
		else
			-- One by One: cuma jual yg cocok filter, targeted (aman by design)
			ctx.state.hatchStatus = "Selling one-by-one..."
			for _, t in ipairs(sells) do
				if t.Parent then
					setFav(t, false)
					if SellPet then pcall(function() SellPet:FireServer(t, true) end) end
					recordSellFire()   -- catat waktu fire untuk Smart Delay Tracker
					task.wait(0.1)
				end
			end
			ctx.state.hatchSellCycles = (ctx.state.hatchSellCycles or 0) + 1
			ctx.state.hatchStatus = ("Sold %d pet (one by one)"):format(#sells)
			return #sells
		end
	end
	ctx.hatchDoSell = doSell -- expose buat tombol manual

	----------------------------------------------------------------- HATCH
	-- Egg ready = timer habis (TimeToHatch <= 0). Egg yg timer-nya jalan = belum ready.
	local function readyEggs()
		local GetFarm = require(RS.Modules.GetFarm); local farm = GetFarm(LP)
		local t = {}
		if farm then for _, e in ipairs(farm:GetDescendants()) do
			if e:IsA("Model") and e.Name == "PetEgg" and e:GetAttribute("OWNER") == LP.Name then
				local tth = tonumber(e:GetAttribute("TimeToHatch")) or 0
				if tth <= 0 then t[#t + 1] = e end
			end
		end end
		return t
	end
	local function backpackPetCount()
		local n = 0
		for _, t in ipairs(petTools()) do local _ = t; n = n + 1 end
		return n
	end
	local function getInventoryCapacity()
		local d = getData()
		local maxCap = d and d.PetsData and d.PetsData.MutableStats and tonumber(d.PetsData.MutableStats.MaxPetsInInventory) or 0
		local bpc = backpackPetCount()
		local inv = inventory()
		local invCount = 0
		for _ in pairs(inv) do invCount = invCount + 1 end
		local cur = math.max(bpc, invCount)
		return cur, maxCap
	end

	-- Parse nama tool egg & jumlahnya (mendukung angka positif dan minus misal "Paradise Egg x-20")
	local function parseEggTool(t)
		if not (t:IsA("Tool") and not t:GetAttribute("PET_UUID") and tostring(t.Name):find("Egg", 1, true)) then
			return nil, 0
		end
		local raw = tostring(t.Name)
		local base, cnt = raw:match("^(.-)%s*x%s*(%-?%d+)$")
		if not cnt then
			base, cnt = raw:match("^(.-)%s+(%-%d+)$")
		end
		if cnt and tonumber(cnt) then
			base = base and base:match("^%s*(.-)%s*$") or raw
			return base, tonumber(cnt)
		end
		return raw:match("^%s*(.-)%s*$"), 1
	end

	-- Daftar egg di backpack + jumlah (buat dropdown Egg Configuration).
	function ctx.getEggBackpackOptions()
		local out = {}
		local bp = LP:FindFirstChildOfClass("Backpack")
		if bp then for _, t in ipairs(bp:GetChildren()) do
			local base, cnt = parseEggTool(t)
			if base then
				out[#out + 1] = { name = base, display = ("%s x%d"):format(base, cnt) }
			end
		end end
		table.sort(out, function(a, b) return a.name < b.name end)
		return out
	end

	----------------------------------------------------------------- PLACE EGG
	local function placedEggCount()
		local GetFarm = require(RS.Modules.GetFarm); local farm = GetFarm(LP)
		local n = 0
		if farm then for _, e in ipairs(farm:GetDescendants()) do
			if e:IsA("Model") and e.Name == "PetEgg" and e:GetAttribute("OWNER") == LP.Name then n = n + 1 end
		end end
		return n
	end
	local function plantLocPart()
		local GetFarm = require(RS.Modules.GetFarm); local farm = GetFarm(LP)
		local PL = farm and farm:FindFirstChild("Plant_Locations", true)
		if not PL then return nil end
		if PL:IsA("BasePart") then return PL end
		for _, d in ipairs(PL:GetDescendants()) do if d:IsA("BasePart") then return d end end
		return nil
	end
	-- Grid FIX & rapih: n slot, center di area, baris rata (spacing 4 studs).
	-- + sedikit baris cadangan di belakang biar tetap bisa penuh kalau ada egg nyempil.
	local function gridPositions(n)
		local p = plantLocPart(); if not p then return {} end
		n = math.max(1, n or 9)
		local SP = 4 -- jarak antar egg (min server = 3, kasih margin biar ga "Too close")
		local usableX = math.max(SP, p.Size.X - 4)
		local cols = math.max(1, math.min(n, math.floor(usableX / SP) + 1))
		-- baris = cukup buat n + 1 baris cadangan (anti-stuck, tetap rapi)
		local rows = math.ceil(n / cols) + 1
		local startX = -((cols - 1) * SP) / 2
		local startZ = -((rows - 1) * SP) / 2
		local out = {}
		for r = 0, rows - 1 do
			for c = 0, cols - 1 do
				out[#out + 1] = p.Position + Vector3.new(startX + c * SP, p.Size.Y / 2 + 0.2, startZ + r * SP)
			end
		end
		return out
	end
	-- Sebar egg ACAK di dalam area, tetap jaga jarak antar-egg biar ga "Too close".
	local function randomPositions(n)
		local p = plantLocPart(); if not p then return {} end
		n = math.max(1, n or 9)
		local SP = 4 -- jarak minimum antar egg
		local halfX = math.max(SP, p.Size.X / 2 - 2)
		local halfZ = math.max(SP, p.Size.Z / 2 - 2)
		local y = p.Size.Y / 2 + 0.2
		local out, tries = {}, 0
		-- generate lebih banyak dari n (buffer) biar tetap bisa penuh walau ada yg bentrok
		while #out < n * 2 and tries < n * 40 do
			tries = tries + 1
			local cand = p.Position + Vector3.new((math.random() * 2 - 1) * halfX, y, (math.random() * 2 - 1) * halfZ)
			local ok = true
			for _, e in ipairs(out) do
				if (Vector3.new(e.X, 0, e.Z) - Vector3.new(cand.X, 0, cand.Z)).Magnitude < SP then ok = false; break end
			end
			if ok then out[#out + 1] = cand end
		end
		return out
	end
	local function currentEggs()
		local GetFarm = require(RS.Modules.GetFarm); local farm = GetFarm(LP)
		local t = {}
		if farm then for _, e in ipairs(farm:GetDescendants()) do
			if e:IsA("Model") and e.Name == "PetEgg" and e:GetAttribute("OWNER") == LP.Name then t[#t + 1] = e end
		end end
		return t
	end
	local function slotOccupied(pos, eggs)
		for _, e in ipairs(eggs) do
			local ep = e:GetPivot().Position
			if (Vector3.new(ep.X, 0, ep.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude < 3.5 then return true end
		end
		return false
	end
	-- return tool egg yg lagi dipegang (scan SEMUA tool, bukan cuma yg pertama) + apakah ada
	-- tool lain (pet/egg beda) yg ikut nyangkut.
	local function scanHeld(eggName)
		local char = LP.Character
		local heldEgg, otherCount = nil, 0
		if char then for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") then
				if not t:GetAttribute("PET_UUID") and tostring(t.Name):find(eggName, 1, true) then heldEgg = t
				else otherCount = otherCount + 1 end
			end
		end end
		return heldEgg, otherCount
	end
	local function equipEggTool(eggName)
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		if not hum then return nil end
		local heldEgg, otherCount = scanHeld(eggName)
		-- udah megang egg yg bener DAN ga ada tool lain nyangkut -> ok
		if heldEgg and otherCount == 0 then return heldEgg end
		-- ada pet/egg-lain ke-pegang barengan (bug double-hold) -> lepas SEMUA biar bersih
		pcall(function() hum:UnequipTools() end); task.wait(0.15)
		local bp = LP:FindFirstChildOfClass("Backpack")
		if bp then for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and tostring(t.Name):find(eggName, 1, true) and not t:GetAttribute("PET_UUID") then
				pcall(function() hum:EquipTool(t) end); task.wait(0.35)
				-- pastiin abis equip ga ada tool lain nyusup lagi
				local eg2, oc2 = scanHeld(eggName)
				if eg2 and oc2 > 0 then pcall(function() hum:UnequipTools() end); task.wait(0.1); pcall(function() hum:EquipTool(t) end); task.wait(0.25) end
				return t
			end
		end end
		return nil
	end
	-- Isi egg RAPIH ke grid, cuma di slot yg kosong. Retry sampai penuh (target).
	local function placeEggs(target)
		local eggName = CFG.hatchEggName or "Rare Egg"
		if not equipEggTool(eggName) then ctx.state.hatchStatus = "Egg '" .. eggName .. "' ga ada di backpack"; return 0 end
		local start = placedEggCount()
		local isRandom = (CFG.hatchPlacePattern == "Random")
		-- isi slot kosong sampai TEPAT target; berhenti kalau 1 pass ga nambah (mentok)
		for _ = 1, 3 do
			if placedEggCount() >= target then break end
			local before = placedEggCount()
			-- Random: sebar ulang tiap pass (spot baru). Grid: pola tetap.
			local grid = isRandom and randomPositions(target) or gridPositions(target)
			local eggs = currentEggs()
			for _, pos in ipairs(grid) do
				if not CFG.hatchEnabled or placedEggCount() >= target then break end
				if not slotOccupied(pos, eggs) then
					equipEggTool(eggName)
					-- pastiin bener-bener MEGANG egg (scan semua tool, bukan cuma yg pertama;
					-- kadang pet hasil hatch ikut ke-pegang). Kalau ada pet nyangkut, equipEggTool
					-- di atas udah bersihin -> re-scan.
					local held = scanHeld(eggName)
					if held then
						pcall(function() EggRemote:FireServer("CreateEgg", pos) end)
						task.wait(0.3)
						eggs = currentEggs() -- refresh biar ga dobel di slot sama
						ctx.state.hatchStatus = ("Placing: %d/%d egg"):format(placedEggCount(), target)
					end
				end
			end
			if placedEggCount() <= before then break end -- ga nambah -> mentok
		end
		return placedEggCount() - start
	end
	local function unionTeam(a, b)
		local u = {}
		for k in pairs(a or {}) do u[k] = true end
		for k in pairs(b or {}) do u[k] = true end
		return u
	end

	-- Pending pet dari egg (dari SavedObjects): return petType, displayWeight (base*1.1)
	local eggSlotKey
	local function eggPending(egg)
		local uuid = egg:GetAttribute("OBJECT_UUID"); if not uuid then return nil, 0 end
		local d = getData(); local slots = d and d.SaveSlots and d.SaveSlots.AllSlots
		if not slots then return nil, 0 end
		local function fromSlot(s) local so = s and s.SavedObjects and s.SavedObjects[uuid]; return so and so.Data end
		local dt = eggSlotKey and fromSlot(slots[eggSlotKey])
		if not dt then for sn, slot in pairs(slots) do if type(slot) == "table" then local x = fromSlot(slot); if x then eggSlotKey = sn; dt = x; break end end end end
		if not dt then return nil, 0 end
		return dt.Type, (tonumber(dt.BaseWeight) or 0) * 1.1
	end

	-- Klasifikasi egg buat bronto: "skip" | "bronto" | "normal"
	local function classifyEgg(egg)
		local pt, w = eggPending(egg)
		local isSpecial = pt ~= nil and (CFG.brontoSpecialPets or {})[petEggLabel(pt)] == true
		if isSpecial and (CFG.brontoSpecialWeight or 0) > 0 and w <= CFG.brontoSpecialWeight then isSpecial = false end
		if isSpecial and CFG.brontoSkipSpecial then return "skip" end
		local isUni = false
		if (CFG.brontoUniversalWeight or 0) > 0 and w > CFG.brontoUniversalWeight then
			local types = CFG.brontoUniversalTypes or {}
			if not next(types) or (pt and types[petEggLabel(pt)]) then isUni = true end
		end
		if isSpecial or isUni then return "bronto" end
		return "normal"
	end

	----------------------------------------------------------------- Hatch Alert (webhook bronto)
	local PetList; pcall(function() PetList = require(RS.Data.PetRegistry.PetList) end)
	local PetRegistry; pcall(function() PetRegistry = require(RS.Data.PetRegistry) end)
	local function petSize(eggName, petType, baseW)
		local egg = PetRegistry and PetRegistry.PetEggs and PetRegistry.PetEggs[eggName]
		local item = egg and egg.RarityData and egg.RarityData.Items and egg.RarityData.Items[petType]
		local wr = item and item.GeneratedPetData and item.GeneratedPetData.WeightRange
		if type(wr) == "table" and wr[1] and wr[2] and wr[2] > wr[1] then
			local f = (baseW - wr[1]) / (wr[2] - wr[1])
			if f < 0.33 then return "Small" elseif f < 0.7 then return "Normal" else return "Big" end
		end
		return "Normal"
	end
	-- dispWeight = berat tampil (base*1.1). Bronto = dispWeight*1.3 (+30%).
	local function sendHatchAlert(petType, eggName, dispWeight)
		local url = CFG.webhookUrl
		if not url or url == "" or not ctx.sendWebhook then return end
		local brontoW = dispWeight * 1.3
		local payload = {
			content = "@everyone",
			embeds = { {
				title = "✦ CeszParadise — Hatch Alerts",
				color = 5814783,
				fields = {
					{
						name = "**Profile :**",
						value = ("> Username : **%s**"):format(LP.Name),
						inline = false,
					},
					{
						name = "**Hatched :**",
						value = ("> Pet Name: `%s`\n> Hatched From: `%s`\n> Weight: `%.2f KG` ➜ `%.2f KG`")
							:format(petType, eggName, dispWeight, brontoW),
						inline = false,
					},
				},
				footer = {
					text = ("Server Version: %s\n%s"):format(tostring(game.PlaceVersion), os.date("%B %d | %I:%M %p")),
					icon_url = "https://raw.githubusercontent.com/catursec/testing/tanduran/main/kebongedang/Logo/logo_icon.png",
				},
			} },
		}
		pcall(function() ctx.sendWebhook(url, payload, ctx) end)
	end

	local function sendInventoryFullWebhook(cur, maxCap)
		local url = (CFG.hatchWebhookUrl and CFG.hatchWebhookUrl ~= "" and CFG.hatchWebhookUrl) or CFG.webhookUrl
		if not url or url == "" or not ctx.sendWebhook then return end
		local payload = {
			content = ("@everyone ⚠️ **Auto Hatch STOPPED** — Invent Max `%d/%d`"):format(cur, maxCap),
			embeds = { {
				title = "⚠️ CeszParadise — Inventory Full Alert",
				color = 16728135,
				description = ("> **Status :** `Invent Max %d/%d`\n> Auto Hatch otomatis dihentikan karena kapasitas penyimpanan pet telah mencapai batas maksimal!"):format(cur, maxCap),
				fields = {
					{
						name = "**Profile :**",
						value = ("> Username : **%s**"):format(LP.Name),
						inline = false,
					},
					{
						name = "**Inventory Statistics :**",
						value = ("> Current Pets: `%d`\n> Max Capacity: `%d`\n> Capacity Status: `Penuh (%d/%d)`"):format(cur, maxCap, cur, maxCap),
						inline = false,
					},
				},
				footer = {
					text = ("Server Version: %s\n%s"):format(tostring(game.PlaceVersion), os.date("%B %d | %I:%M %p")),
					icon_url = "https://raw.githubusercontent.com/catursec/testing/tanduran/main/kebongedang/Logo/logo_icon.png",
				},
			} },
		}
		pcall(function() ctx.sendWebhook(url, payload, ctx) end)
	end

	local function handleInventoryFull(cur, maxCap)
		if not CFG.hatchEnabled and ctx.state.hatchStatus and ctx.state.hatchStatus:find("Invent Max") then return end
		CFG.hatchEnabled = false
		if ctx.persistState then pcall(ctx.persistState) end
		ctx.stopHatch()
		if ctx.ui and ctx.ui.rHatchToggle then
			pcall(ctx.ui.rHatchToggle)
		end
		ctx.state.hatchPhase = ("Invent Max (%d/%d)"):format(cur, maxCap)
		ctx.state.hatchStatus = ("Auto Hatch STOPPED: Invent Max %d/%d"):format(cur, maxCap)
		if ctx.log then ctx.log(("Auto Hatch STOPPED: Invent Max %d/%d"):format(cur, maxCap)) end
		task.spawn(function()
			sendInventoryFullWebhook(cur, maxCap)
		end)
	end

	----------------------------------------------------------------- Auto Rejoin on Egg Minus
	local function sendRejoinMinusWebhook(eggName, amt, thresh)
		local url = (CFG.hatchWebhookUrl and CFG.hatchWebhookUrl ~= "" and CFG.hatchWebhookUrl) or CFG.webhookUrl
		if not url or url == "" or not ctx.sendWebhook then return end
		local notifyText = ("auto rejoin on, %s %d"):format(eggName, amt)
		local payload = {
			content = ("@everyone ⚠️ **Auto Rejoin** — `%s`"):format(notifyText),
			embeds = { {
				title = "🔄 CeszParadise — Auto Rejoin (Egg Minus)",
				color = 16744272,
				description = ("> **Status :** `%s`\n> Jumlah egg terdeteksi minus di bawah ambang batas (`%d`)! Melakukan auto rejoin ke server..."):format(notifyText, thresh),
				fields = {
					{
						name = "**Profile :**",
						value = ("> Username : **%s**\n> Display : **%s**"):format(LP.Name, LP.DisplayName or LP.Name),
						inline = false,
					},
					{
						name = "**Egg Information :**",
						value = ("> Egg Name : `%s`\n> Current Amount : `%d`\n> Threshold : `%d`"):format(eggName, amt, thresh),
						inline = false,
					},
					{
						name = "**Action :**",
						value = "> Reconnecting to server in 2 seconds...",
						inline = false,
					},
				},
				footer = {
					text = ("Server Version: %s\n%s"):format(tostring(game.PlaceVersion), os.date("%B %d | %I:%M %p")),
					icon_url = "https://raw.githubusercontent.com/catursec/testing/tanduran/main/kebongedang/Logo/logo_icon.png",
				},
			} },
		}
		pcall(function() ctx.sendWebhook(url, payload, ctx) end)
	end

	function ctx.testRejoinWebhook()
		local eggName = CFG.hatchEggName or "Paradise Egg"
		local thresh = -math.abs(tonumber(CFG.hatchRejoinMinusThreshold) or 20)
		sendRejoinMinusWebhook(eggName, thresh, thresh)
	end

	local function checkEggMinus()
		if not CFG.hatchRejoinMinusEnabled then return nil, nil, nil end
		local rawThresh = tonumber(CFG.hatchRejoinMinusThreshold) or 20
		local thresh = -math.abs(rawThresh)

		local counts = {}
		for _, src in ipairs({ LP:FindFirstChildOfClass("Backpack"), LP.Character }) do
			if src then
				for _, t in ipairs(src:GetChildren()) do
					local base, qty = parseEggTool(t)
					if base then
						counts[base] = (counts[base] or 0) + qty
					end
				end
			end
		end

		-- 1. Prioritaskan egg target yang sedang di-hatch
		local targetEgg = CFG.hatchEggName or "Rare Egg"
		if counts[targetEgg] and counts[targetEgg] <= thresh then
			return targetEgg, counts[targetEgg], thresh
		end

		-- 2. Parsial match egg target
		for name, qty in pairs(counts) do
			if name:lower():find(targetEgg:lower(), 1, true) and qty <= thresh then
				return name, qty, thresh
			end
		end

		-- 3. Cek semua egg lain di inventory
		for name, qty in pairs(counts) do
			if qty <= thresh then
				return name, qty, thresh
			end
		end

		return nil, nil, nil
	end

	local function handleEggMinus(eggName, amt, thresh)
		if ctx.state.hatchIsRejoining then return end
		ctx.state.hatchIsRejoining = true

		local reason = ("auto rejoin on, %s %d"):format(eggName, amt)
		ctx.state.hatchPhase = "Auto Rejoin"
		ctx.state.hatchStatus = ("Rejoining (%s %d)..."):format(eggName, amt)
		if ctx.log then ctx.log(("[Auto Hatch] %s (Threshold: %d) -> Rejoining server..."):format(reason, thresh)) end

		-- Kirim webhook sebelum teleport
		task.spawn(function()
			sendRejoinMinusWebhook(eggName, amt, thresh)
		end)

		-- Beri jeda 2 detik agar webhook selesai dikirim sebelum client disconnect
		task.wait(2.0)

		-- Eksekusi Reconnect
		if ctx.reconnect then
			pcall(ctx.reconnect)
		else
			local q = (syn and syn.queue_on_teleport) or queue_on_teleport
				or (fluxus and fluxus.queue_on_teleport) or (getgenv and getgenv().queue_on_teleport)
			if q then
				local branch = (getgenv and getgenv().GAG_BRANCH) or _G.GAG_BRANCH or "main"
				pcall(function()
					q(('if getgenv then getgenv().GAG_BRANCH=%q end loadstring(game:HttpGet("https://raw.githubusercontent.com/catursec/testing/tanduran/%s/kebongedang/init.lua"))()'):format(branch, branch))
				end)
			end
			task.wait(0.4)
			local TeleportService = game:GetService("TeleportService")
			pcall(function() TeleportService:Teleport(game.PlaceId, LP) end)
		end
	end

	----------------------------------------------------------------- Cycle Statistics (webhook)
	-- Team ringkas: "N Nama Lengkap" (mutasi + tipe), grup per nama.
	local function teamNames(set)
		local mutDisplay = (ctx.reg and ctx.reg.mutDisplay) or function(x) return x end
		local inv = inventory()
		local tally, order = {}, {}
		for u in pairs(set or {}) do
			local v = inv[u]
			if v then
				local pt = v.PetType or "?"
				local mut = v.PetData and v.PetData.MutationType
				local mutName = mut and mutDisplay(mut) or mut
				local name = (mut and mut ~= "" and mut ~= "Normal") and (tostring(mutName) .. " " .. pt) or pt
				if not tally[name] then tally[name] = 0; order[#order + 1] = name end
				tally[name] = tally[name] + 1
			end
		end
		table.sort(order)
		local parts = {}
		for _, name in ipairs(order) do parts[#parts + 1] = tally[name] .. " " .. name end
		return #parts > 0 and table.concat(parts, ", ") or "None"
	end
	ctx.hatchTeamNames = teamNames

	-- Kategori Hunt: Special (dari filter Bronto Config) + Heavy (>= 5kg, gabungan Huge s/d Colossal).
	-- Apakah pet masuk filter Special di Bronto Configuration?
	local function isBrontoSpecial(petType, w)
		local key = petEggLabel(petType)
		if (CFG.brontoSpecialPets or {})[key] ~= true then return false end
		if (CFG.brontoSpecialWeight or 0) > 0 and (w or 0) <= CFG.brontoSpecialWeight then return false end
		return true
	end
	-- akumulasi pet ke-hatch: Special vs Heavy (>= 5 kg). Simpan list semua bobot per petType.
	local function trackHatch(petType, dispW, special)
		ctx.state.hatchTiers = ctx.state.hatchTiers or {}
		dispW = tonumber(dispW) or 0
		local category = special and "Special" or (dispW >= 5 and "Heavy" or nil)
		if not category then return end -- <5kg non-special: skip

		local bucket = ctx.state.hatchTiers[category]
		if not bucket then bucket = {}; ctx.state.hatchTiers[category] = bucket end
		local t = bucket[petType]
		if not t then t = { n = 0, weights = {} }; bucket[petType] = t end
		t.n = t.n + 1
		t.weights[#t.weights + 1] = dispW
	end
	ctx.hatchIsBrontoSpecial = isBrontoSpecial

	local function eggAmount(eggName)
		local n = 0
		for _, src in ipairs({ LP:FindFirstChildOfClass("Backpack"), LP.Character }) do
			if src then for _, t in ipairs(src:GetChildren()) do
				local base, cnt = parseEggTool(t)
				if base and (base == eggName or base:find(eggName, 1, true)) then
					n = n + cnt
				end
			end end
		end
		return n
	end
	-- Recovery stat DIHITUNG dari team yg dipilih (formula game, bukan empiris).
	-- Per pet: value = clamp(Base + Scale*scaledLevel, 0, Max). scaledLevel diminishing
	-- di atas 100. Total di-cap 50% (cap per egg). Koi @ Hatch team, Seal @ Sell team.
	local function scaledLevel(lv)
		lv = lv or 0
		if lv <= 100 then return lv
		elseif lv <= 120 then return (lv - 100) * 0.25 + 100
		else return (lv - 120) * 0.1 + 105 end
	end
	local function passivePct(teamSet, typeMatch, base, scale, maxPer)
		local inv = inventory()
		local n, total = 0, 0
		for u in pairs(teamSet or {}) do
			local v = inv[u]
			if v and tostring(v.PetType):find(typeMatch) then
				n = n + 1
				local val = base + scale * scaledLevel((v.PetData or {}).Level or 0)
				total = total + math.clamp(val, 0, maxPer) -- per-pet asli (Max 10), total ga di-cap
			end
		end
		return n, total
	end
	-- Koi (Fish of Fortune): Base1 Scale0.22 Max10. Seal (Seal the Deal): Base1 Scale0.05 Max10.
	function ctx.getRecoveryStat()
		local kn, kp = passivePct(CFG.hatchHatchTeam, "Koi", 1, 0.22, 10)
		local sn, sp = passivePct(CFG.hatchSellTeam, "Seal", 1, 0.05, 10)
		return {
			koiCount = kn, koiPct = kp,
			sealCount = sn, sealPct = sp,
		}
	end

	-- Recovery ASLI dihitung dari notif game (listener di atas): periodHatchRec / periodSellRec.
	-- periodHatched / periodSold = jumlah aksi (buat hitung % efektif).

	local function fmtDur(sec)
		sec = math.max(0, math.floor(sec))
		local h = math.floor(sec / 3600); local m = math.floor((sec % 3600) / 60); local s = sec % 60
		local p = {}
		if h > 0 then p[#p + 1] = h .. "h" end
		if m > 0 then p[#p + 1] = m .. "m" end
		p[#p + 1] = s .. "s"
		return table.concat(p, " ")
	end

	local function sendCycleStats()
		local url = CFG.webhookUrl
		if not url or url == "" or not ctx.sendWebhook then return end
		local eggName = CFG.hatchEggName or "Rare Egg"
		local hatched = ctx.state.hatchEggsHatched or 0
		local eggBefore = ctx.state.hatchEggBefore or 0
		local curAmt = eggAmount(eggName)

		-- Format Hunt: Special (range min-max kg) & Heavy/Huge-Colossal (daftar bobot tiap pet)
		local tiers = ctx.state.hatchTiers or {}
		local huntLines, totalPets = {}, 0

		-- 1. Special Pets (langsung hasil tanpa judul 'Special:')
		local specBucket = tiers["Special"] or {}
		local specKeys = {}
		for pt in pairs(specBucket) do specKeys[#specKeys + 1] = pt end
		table.sort(specKeys)
		for _, pt in ipairs(specKeys) do
			local t = specBucket[pt]
			totalPets = totalPets + t.n
			local minW, maxW = math.huge, 0
			for _, w in ipairs(t.weights) do
				if w < minW then minW = w end
				if w > maxW then maxW = w end
			end
			local rng = (minW == maxW or minW == math.huge) and ("`%.2f kg`"):format(maxW)
				or ("`%.2f-%.2f kg`"):format(minW, maxW)
			huntLines[#huntLines + 1] = ("> • **%s** `x%d` (%s)"):format(pt, t.n, rng)
		end

		-- 2. Heavy / Huge-Colossal Pets (daftar bobot per pet)
		local heavyBucket = tiers["Heavy"] or {}
		local heavyKeys = {}
		for pt in pairs(heavyBucket) do heavyKeys[#heavyKeys + 1] = pt end
		table.sort(heavyKeys)
		for _, pt in ipairs(heavyKeys) do
			local t = heavyBucket[pt]
			totalPets = totalPets + t.n
			local wStrs = {}
			for _, w in ipairs(t.weights) do
				wStrs[#wStrs + 1] = ("%.2f"):format(w)
			end
			huntLines[#huntLines + 1] = ("> • **%s** `x%d` (`%skg`)"):format(pt, t.n, table.concat(wStrs, ", "))
		end

		local huntText = #huntLines > 0 and table.concat(huntLines, "\n"):sub(1, 1020) or "> • *Tidak ada pet bronto*"

		-- Recovery deterministik (cap 50%). Koi dari Hatch+Bronto team; Seal dari Sell team.
		local rec = ctx.getRecoveryStat()
		local sellDone = ctx.state.sellDoneThisReport == true
		local recHatchCycle = math.floor((ctx.state.periodHatchRec or 0) + 0.5)
		local recSellCycle = sellDone and math.floor((ctx.state.periodSellRec or 0) + 0.5) or 0
		local koiPctShown = rec.koiPct
		local sellPctShown = sellDone and rec.sealPct or 0
		local totalRecovery = recHatchCycle + recSellCycle

		local curAdj = curAmt
		local maxBp = 0
		local d = getData(); if d then maxBp = tonumber(d.PetsData.MutableStats.MaxPetsInInventory) or 0 end
		local hatchCycles = ctx.state.hatchRounds or 0
		local netResult = curAdj - eggBefore

		local payload = { embeds = { {
			title = "📊 Tracking",
			color = 5793266,
			fields = {
				{
					name = "**Profile :**",
					value = ("> Username : **%s**"):format(LP.Name),
					inline = false
				},
				{
					name = "**Hatch Statistics :**",
					value = ("> Cycle Count: `%d`\n> Total Hatched: `%d`\n> Sell Cycle: `%d / %d`\n> Reduce Time: `%s`\n> Duration: `%s`\n> \n> Egg Name: `%s`\n> Pet on Inventory: `%d/%d`")
						:format(
							hatchCycles,
							hatched,
							(ctx.state.hatchReportSellProg or ((ctx.state.hatchRounds or 0) - (ctx.state.hatchLastSellCycle or 0))),
							CFG.sellEveryNCycles or 1,
							fmtDur(os.time() - (ctx.state.hatchCycleStartTime or os.time())),
							fmtDur(os.time() - (ctx.state.hatchStartTime or os.time())),
							eggName,
							backpackPetCount(),
							maxBp
						),
					inline = false
				},
				{
					name = ("**Hatch Bronto (%d):**"):format(totalPets),
					value = huntText,
					inline = false
				},
				{
					name = "**Egg Statistics :**",
					value = ("> Egg Before: `%d`\n> Current Egg: `%d` (`%+d`)\n> Lucky Hatch: `%d` (`%.2f%%`)\n> Lucky Sell: `%d` (`%.2f%%`)\n> Total Recovery: `%d`")
						:format(eggBefore, curAdj, netResult, recHatchCycle, koiPctShown, recSellCycle, sellPctShown, totalRecovery),
					inline = false
				},
			},
			footer = {
				text = ("Server Version: %s\n%s"):format(tostring(game.PlaceVersion), os.date("%B %d | %I:%M %p")),
				icon_url = "https://raw.githubusercontent.com/catursec/testing/tanduran/main/kebongedang/Logo/logo_icon.png"
			},
		} } }
		pcall(function() ctx.sendWebhook(url, payload, ctx) end)
		ctx.state.hatchCycleStartTime = os.time()
		-- reset counter periode (Lucky Hatch/Sell dihitung ulang tiap webhook)
		ctx.state.periodHatched, ctx.state.periodSold, ctx.state.sellDoneThisReport = 0, 0, false
		ctx.state.periodHatchRec, ctx.state.periodSellRec = 0, 0
	end
	ctx.hatchSendCycleStats = sendCycleStats
	ctx.hatchTrack = trackHatch

	----------------------------------------------------------------- STATUS
	ctx.state.hatchStatus = "Idle"
	function ctx.getHatchSummary()
		-- team: format per pet "Mutasi - Nama - Berat - Age" (pakai teamNames global)
		local nm = teamNames
		-- max backpack + jumlah egg terpilih
		local d = getData()
		local maxBp = d and d.PetsData and d.PetsData.MutableStats and tonumber(d.PetsData.MutableStats.MaxPetsInInventory) or 0
		local eggName = CFG.hatchEggName or "Rare Egg"
		local curEgg = 0
		for _, src in ipairs({ LP:FindFirstChildOfClass("Backpack"), LP.Character }) do
			if src then for _, t in ipairs(src:GetChildren()) do
				if t:IsA("Tool") and not t:GetAttribute("PET_UUID") and tostring(t.Name):find(eggName, 1, true) then
					local _, cnt = tostring(t.Name):match("^(.-)%s*x(%d+)$"); if tonumber(cnt) then curEgg = tonumber(cnt) end
				end
			end end
		end
		return {
			status = CFG.hatchEnabled and "RUNNING" or "STOPPED",
			phase = ctx.state.hatchPhase or "-",
			core = nm(CFG.hatchCoreTeam), hatch = nm(CFG.hatchHatchTeam),
			bronto = nm(CFG.hatchBrontoTeam), sell = nm(CFG.hatchSellTeam),
			backpack = backpackPetCount(), maxBackpack = maxBp,
			currentEgg = eggName, eggBefore = ctx.state.hatchEggBefore or curEgg, currentAmount = curEgg,
			eggsHatched = ctx.state.hatchEggsHatched or 0,
			sellCycles = ctx.state.hatchSellCycles or 0,
			ready = #readyEggs(),
			placed = placedEggCount(),
			maxPlaced = CFG.hatchMaxPlaced or 9,
			sellMode = CFG.sellMode or "Cycle",
			cycleProg = (ctx.state.hatchRounds or 0) - (ctx.state.hatchLastSellCycle or 0),
			cycleTarget = CFG.sellEveryNCycles or 1,
			proc = ctx.getRecoveryStat(),
		}
	end

	----------------------------------------------------------------- LOOP
	local function tick()
		local bpc = backpackPetCount()
		local maxP = CFG.hatchMaxPlaced or 9
		local placed = placedEggCount()

		-- CHECK EGG MINUS:
		-- Jika Auto Sell mati: langsung cek tiap tick.
		-- Jika Auto Sell hidup tapi garden kosong & pet kosong (stuck): langsung cek agar tidak idle selamanya.
		if CFG.hatchRejoinMinusEnabled then
			local shouldCheckDirectly = (not CFG.autoSellEnabled) or (placed == 0 and bpc == 0)
			if shouldCheckDirectly then
				local minusEgg, minusAmt, minusThresh = checkEggMinus()
				if minusEgg and minusAmt then
					handleEggMinus(minusEgg, minusAmt, minusThresh)
					return
				end
			end
		end

		-- cycle = jumlah RONDE hatch (tiap 1 batch garden selesai di-hatch = 1 cycle)
		local cycle = ctx.state.hatchRounds or 0
		-- 1) SELL trigger: mode "Cycle" (tiap N cycle) atau "Backpack" (pas penuh)
		local sellNow = false
		if CFG.autoSellEnabled then
			if CFG.sellMode == "Cycle" then
				sellNow = (cycle - (ctx.state.hatchLastSellCycle or 0)) >= (CFG.sellEveryNCycles or 1)
			else
				sellNow = bpc >= (CFG.sellWhenReach or 100)
			end
		end
		if sellNow then
			ctx.state.hatchPhase = "Selling Pets"
			if next(CFG.hatchSellTeam or {}) and not equipTeam(CFG.hatchSellTeam, "Sell Team") then return end -- team wajib lengkap
			task.wait(CFG.sellTeamDelay or 5)
			local sold = doSell()
			ctx.state.periodSold = (ctx.state.periodSold or 0) + (tonumber(sold) or 0)
			ctx.state.sellDoneThisReport = true
			-- simpan progress sell-cycle SEBELUM reset (biar webhook nampilin 2/2 bukan 0/2)
			ctx.state.hatchReportSellProg = cycle - (ctx.state.hatchLastSellCycle or 0)
			ctx.state.hatchLastSellCycle = cycle

			-- Tunggu adaptif agar notifikasi Lucky Pet / recovery Seal the Deal masuk ke inventory
			local sw = adaptiveWaitSell()
			ctx.state.hatchStatus = ("Nunggu Lucky Sell window (%.1fs)..."):format(sw)
			task.wait(sw)

			-- CEK EGG MINUS SETELAH SIKLUS AUTO SELL SELESAI
			if CFG.hatchRejoinMinusEnabled then
				local minusEgg, minusAmt, minusThresh = checkEggMinus()
				if minusEgg and minusAmt then
					handleEggMinus(minusEgg, minusAmt, minusThresh)
					return
				end
			end

			-- report DITUNDA: dikirim nanti setelah garden ke-refill (place egg lagi), biar
			-- Current Amount stabil & Lucky Sell (egg balik) udah nyampe.
			return
		end

		-- CHECK INVENTORY FULL: jika penyimpanan penuh, hentikan auto hatch & kirim webhook
		local curPets, maxPets = getInventoryCapacity()
		if maxPets > 0 and curPets >= maxPets then
			if CFG.autoSellEnabled and not ctx.state.sellDoneThisReport then
				ctx.state.hatchPhase = "Selling Pets (Inv Full)"
				if not next(CFG.hatchSellTeam or {}) or equipTeam(CFG.hatchSellTeam, "Sell Team") then
					task.wait(CFG.sellTeamDelay or 5)
					local sold = doSell()
					ctx.state.periodSold = (ctx.state.periodSold or 0) + (tonumber(sold) or 0)
					ctx.state.sellDoneThisReport = true
					curPets, maxPets = getInventoryCapacity()
					local sw2 = adaptiveWaitSell()
					ctx.state.hatchStatus = ("Nunggu Lucky Sell window (%.1fs)..."):format(sw2)
					task.wait(sw2)

					-- Cek egg minus setelah sell darurat
					if CFG.hatchRejoinMinusEnabled then
						local minusEgg, minusAmt, minusThresh = checkEggMinus()
						if minusEgg and minusAmt then
							handleEggMinus(minusEgg, minusAmt, minusThresh)
							return
						end
					end
				end
			end
			if maxPets > 0 and curPets >= maxPets then
				handleInventoryFull(curPets, maxPets)
				return
			end
		end

		-- clamp target ke kapasitas farm biar ga nyangkut (mis. Max Placed > MaxEggsInFarm)
		local d = getData()
		local farmCap = d and d.PetsData and d.PetsData.MutableStats and d.PetsData.MutableStats.MaxEggsInFarm or maxP
		maxP = math.min(maxP, farmCap)

		local placed = placedEggCount()

		-- 2) PLACE (best-effort): tambah egg kalau kurang. JANGAN stuck kalau ga bisa penuh
		--    (grid bentrok egg recovered / kapasitas farm mentok) -> lanjut proses egg yg ada.
		if placed < maxP then
			ctx.state.hatchPhase = ("Placing Eggs (%d/%d)"):format(placed, maxP)
			if not equipTeam(CFG.hatchCoreTeam, "Core Team") then return end -- team wajib lengkap dulu
			local added = placeEggs(maxP)
			placed = placedEggCount()
			if added > 0 and placed < maxP then return end -- masih nambah -> lanjut place tick berikut
			-- added==0 (mentok) & belum penuh -> anti-stuck: lanjut proses egg yg udah ada
		end

		-- REPORT: garden udah ke-refill (place selesai). Kalau ada report pending dari
		-- hatch/sell sebelumnya, KIRIM sekarang -> Current Amount = backpack + garden (stabil).
		if ctx.state.hatchPendingReport then
			ctx.state.hatchPendingReport = false
			task.spawn(sendCycleStats)
		end

		local ready = readyEggs()
		-- 3) HATCH: HANYA kalau SEMUA egg (yg ke-place) udah READY (jangan switch selama timer jalan)
		if placed > 0 and #ready >= placed then
			local curHatchPets, maxHatchPets = getInventoryCapacity()
			if maxHatchPets > 0 and curHatchPets >= maxHatchPets then
				handleInventoryFull(curHatchPets, maxHatchPets)
				return
			end

			ctx.state.hatchPhase = "Hatching"
			-- klasifikasi tiap egg: normal (Hatch team) / bronto (Bronto team) / skip
			local normal, bronto = {}, {}
			for _, e in ipairs(ready) do
				local c = classifyEgg(e)
				if c == "bronto" then bronto[#bronto + 1] = e
				elseif c == "normal" then normal[#normal + 1] = e end
			end
			local function hatchList(list)
				for _, e in ipairs(list) do
					if not CFG.hatchEnabled then break end
					local cPets, mPets = getInventoryCapacity()
					if mPets > 0 and cPets >= mPets then
						handleInventoryFull(cPets, mPets)
						break
					end
					local pt, w = eggPending(e)
					if pt then trackHatch(pt, w, isBrontoSpecial(pt, w)) end
					pcall(function() EggRemote:FireServer("HatchPet", e) end)
					recordHatchFire()   -- catat waktu fire untuk Smart Delay Tracker
					ctx.state.hatchEggsHatched = (ctx.state.hatchEggsHatched or 0) + 1
				end
			end
			-- pass NORMAL -> Hatch Team (Koi recover)
			if #normal > 0 then
				if next(CFG.hatchHatchTeam or {}) and not equipTeam(CFG.hatchHatchTeam, "Hatch Team") then return end
				if next(CFG.hatchHatchTeam or {}) and (CFG.hatchTeamDelay or 5) > 0 then
					task.wait(CFG.hatchTeamDelay or 5)
				end
				ctx.state.hatchPhase = ("Hatching Hatch-team (%d)"):format(#normal)
				hatchList(normal)
			end
			if not CFG.hatchEnabled then return end
			-- pass BRONTO -> Bronto Team (+30% berat) + kirim Hatch Alert per pet
			if #bronto > 0 then
				if next(CFG.hatchBrontoTeam or {}) and not equipTeam(CFG.hatchBrontoTeam, "Bronto Team") then return end
				if next(CFG.hatchBrontoTeam or {}) and (CFG.brontoTeamDelay or 5) > 0 then
					task.wait(CFG.brontoTeamDelay or 5)
				end
				ctx.state.hatchPhase = ("Hatching Bronto-team (%d)"):format(#bronto)
				for _, e in ipairs(bronto) do
					if not CFG.hatchEnabled then break end
					local cPets, mPets = getInventoryCapacity()
					if mPets > 0 and cPets >= mPets then
						handleInventoryFull(cPets, mPets)
						break
					end
					local pt, w = eggPending(e)
					-- pet ini di-hatch pakai Bronto team -> berat aktual +30% (buat tier Hunt)
					if pt then trackHatch(pt, w * 1.3, isBrontoSpecial(pt, w)); task.spawn(function() sendHatchAlert(pt, CFG.hatchEggName or "Rare Egg", w) end) end
					pcall(function() EggRemote:FireServer("HatchPet", e) end)
					recordHatchFire()   -- catat waktu fire untuk Smart Delay Tracker
					ctx.state.hatchEggsHatched = (ctx.state.hatchEggsHatched or 0) + 1
				end
			end
			if not CFG.hatchEnabled then return end
			-- jumlah hatch (recovery-nya diisi listener notif). Beri jeda adaptif biar notif nyusul.
			ctx.state.periodHatched = (ctx.state.periodHatched or 0) + #normal + #bronto
			local aw = adaptiveWaitHatch()
			ctx.state.hatchStatus = ("Nunggu Lucky Hatch window (%.1fs)..."):format(aw)
			task.wait(aw)
			-- 1 batch (normal+bronto) selesai = 1 ronde/cycle
			ctx.state.hatchRounds = (ctx.state.hatchRounds or 0) + 1
			-- TANDAI report pending. Webhook ga dikirim di sini — ditunda sampai garden
			-- ke-refill (place egg lagi) biar Current Amount stabil & Lucky Hatch keitung.
			if not (ctx.state.sellDoneThisReport) then ctx.state.hatchReportSellProg = nil end
			ctx.state.hatchPendingReport = true
			return
		end

		-- 4) INCUBATE: masih ada egg belum ready -> TETAP Core Team (speed), jangan switch/hatch
		ctx.state.hatchPhase = ("Incubating (%d/%d ready)"):format(#ready, placed)
		equipTeam(CFG.hatchCoreTeam, "Core Team")
		ctx.state.hatchStatus = ("Nunggu egg ready (%d/%d)..."):format(#ready, placed)
	end

	local function loop()
		ctx.state.hatchId = (ctx.state.hatchId or 0) + 1
		local my = ctx.state.hatchId
		ctx.elevate()
		while CFG.hatchEnabled and ctx.alive() and ctx.state.hatchId == my do
			pcall(tick)
			task.wait(1.0)
		end
		ctx.state.hatchStatus = "Idle"
	end

	function ctx.startHatch()
		if ctx.cancelClearGarden then ctx.cancelClearGarden() end
		-- RESET semua statistik: tiap nyalain ulang mulai dari awal (webhook + live status)
		ctx.state.hatchEggsHatched = 0
		ctx.state.hatchRounds = 0
		ctx.state.hatchLastSellCycle = 0
		ctx.state.hatchReportSellProg = nil
		ctx.state.hatchSellCycles = 0
		ctx.state.hatchTiers = {}
		ctx.state.periodHatched = 0
		ctx.state.periodSold = 0
		ctx.state.periodHatchRec = 0
		ctx.state.periodSellRec = 0
		ctx.state.sellDoneThisReport = false
		ctx.state.hatchPendingReport = false
		ctx.state.hatchIsRejoining = false
		-- catat jumlah egg terpilih di awal (buat "Egg Before") = backpack apa adanya
		local eggName = CFG.hatchEggName or "Rare Egg"
		ctx.state.hatchEggBefore = 0
		for _, src in ipairs({ LP:FindFirstChildOfClass("Backpack"), LP.Character }) do
			if src then for _, t in ipairs(src:GetChildren()) do
				local base, cnt = parseEggTool(t)
				if base and (base == eggName or base:find(eggName, 1, true)) then
					ctx.state.hatchEggBefore = ctx.state.hatchEggBefore + cnt
				end
			end end
		end
		ctx.state.hatchStartTime = os.time()
		ctx.state.hatchCycleStartTime = os.time()
		task.spawn(loop)
	end
	function ctx.stopHatch()
		ctx.state.hatchId = (ctx.state.hatchId or 0) + 1
		ctx.state.hatchStatus = "Idle"
	end

	----------------------------------------------------------------- AUTO FAVORITE
	-- Favoritin otomatis pet yg tipenya ada di CFG.favoritePetTypes (biar ga ke-sell).
	-- favoritePetTypes = key PET_OPTIONS (nama pet polos); tool attribute "f" = nama pet.
	function ctx.startAutoFavorite()
		ctx.state.autoFavId = (ctx.state.autoFavId or 0) + 1
		local my = ctx.state.autoFavId
		ctx.elevate()
		task.spawn(function()
			while CFG.autoFavorite and ctx.alive() and ctx.state.autoFavId == my do
				if next(CFG.favoritePetTypes or {}) then
					for _, t in ipairs(petTools()) do
						local pt = t:GetAttribute("f")
						if pt and (CFG.favoritePetTypes)[pt] and not isFav(t) then
							setFav(t, true)
						end
					end
				end
				task.wait(3)
			end
		end)
	end
	function ctx.stopAutoFavorite()
		ctx.state.autoFavId = (ctx.state.autoFavId or 0) + 1
	end
end
