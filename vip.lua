-- amirking hub v5.3 — Auto Plane Deployment entegre
-- Compatibility polyfill
if not table.find then
    table.find = function(t, val)
        for i, v in ipairs(t) do
            if v == val then return i end
        end
        return nil
    end
end
if not task then
    task = {
        wait  = wait or function(n) return wait(n or 0) end,
        spawn = function(f, ...) return spawn(f, ...) end,
        defer = function(f, ...) return spawn(f, ...) end,
    }
end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local CoreGui           = game:GetService("CoreGui")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")
local LocalPlayer       = Players.LocalPlayer
-- ═══ MAIN ENGINE ══════════════════════════════════════════════
local function startMainScript()
    local PurchaseFactory   = ReplicatedStorage.Cities.PurchaseFactory
    local SetProductionPct  = ReplicatedStorage.Production.SetProductionPercentage
    local TryPurchaseTech   = ReplicatedStorage.Research.TryPurchaseTech
    local StartResearch     = ReplicatedStorage.Research.StartResearch
    local TryStartFocus     = ReplicatedStorage.Government.TryStartFocus
    local TryIncreaseTarget = ReplicatedStorage.Army.TryIncreaseTarget
    local MoveTroop         = ReplicatedStorage.Player.MoveTroop
    local TryDeployPlanes   = ReplicatedStorage:WaitForChild("Planes"):WaitForChild("TryDeployPlanes")
    local ResearchCommon    = require(ReplicatedStorage.Common.ResearchCommon)
    local PreviewPath       = require(LocalPlayer.PlayerScripts.PlayerControls.PreviewPath)
    local Map               = workspace:WaitForChild("Map")
    local AirMap            = workspace:WaitForChild("AirMap")
    local function safeFire(r, ...) pcall(function(...) r:FireServer(...) end, ...) end
    local function safeInvoke(r, ...) local ok, a = pcall(function(...) return r:InvokeServer(...) end, ...); return ok and a or false end
    local function numAttr(i, n, f) local v = i and i:GetAttribute(n); return type(v) == "number" and v or (f or 0) end
    local function decodeJ(raw) if not raw then return nil end; local ok, d = pcall(HttpService.JSONDecode, HttpService, raw); return ok and d or nil end
    local function getCountry() local o = LocalPlayer:FindFirstChild("Country"); return o and o.Value or nil end
    local ok_ct, CommonTypes = pcall(function() return require(ReplicatedStorage.Common.CommonTypes) end)
    if not ok_ct then CommonTypes = nil end
    local PRESETS = {
        ["Упор на пехоту"] = { "Infantry Equipment", "Infantry Attack Equipment", "Infantry Armor", "Anti-Tank", "Support Equipment", "Fortifications", "Industry" },
        ["Упор на танки"]     = { "Tank Parts", "Tank Turret", "Mechanization", "Anti-Tank", "Support Equipment", "Industry" },
        ["Упор на авиацию"]      = { "Fighter", "CAS", "Bomber", "Support Equipment", "Industry" },
        ["Упор на флот"]    = { "Destroyer", "Battleship", "Submarine", "Transport Ship", "Shipyard", "Industry" },
        ["Ядерная программа"]     = { "Uranium Mining", "Uranium Enrichment", "Nuke", "Nuclear Protection", "Industry" },
    }
    local latestSnapshot = nil
    local State = {
        AutoFactory     = false, AutoProduction = false, AutoGovernment = false,
        AutoArmy        = false, AutoResearch   = false, SmartMovement  = false,
        AutoPlanes      = false, AutoSilo       = false, AutoNaval      = false,
        AutoDiplomacy   = false, AutoMissile    = false,
        GovernmentMode  = "War", ArmySpawnFocus = "Infantry", ResearchBases  = {},
    }
    local function applyPreset(name) local b = PRESETS[name]; if not b then return end; State.ResearchBases = {}; for _, x in pairs(b) do table.insert(State.ResearchBases, x) end end
    -- ═══ AUTO NAVAL INVASION ══════════════════════════════════
    local LoadDivisionOnShip   = ReplicatedStorage:WaitForChild("Cities"):WaitForChild("Port"):WaitForChild("LoadDivisionOnShip")
    local TryExitPortWithFleet = ReplicatedStorage:WaitForChild("Cities"):WaitForChild("Port"):WaitForChild("TryExitPortWithFleet")
    local PreviewPath_naval    = require(LocalPlayer.PlayerScripts.PlayerControls.PreviewPath)
    local navalState = {
        phase       = "idle",   -- idle | loading | sailing | landed
        targetTile  = nil,
        usedArmies  = {},
        lastAt      = 0,
    }
    local function getEnemyCapitalTile(country)
        local dip = country:FindFirstChild("Diplomacy")
        if not dip then return nil end
        local enemies = dip:FindFirstChild("Enemies")
        if not enemies then return nil end
        for _, e in ipairs(enemies:GetChildren()) do
            if not e.Value then continue end
            local cities = e.Value:FindFirstChild("Cities")
            if not cities then continue end
            for _, city in ipairs(cities:GetChildren()) do
                if city:GetAttribute("isCapital") then
                    local tileName = tostring(city:GetAttribute("tileName") or "")
                    local tile = Map:FindFirstChild(tileName)
                    if tile then return tile, e.Value end
                end
            end
        end
        return nil
    end
    local function getBestInfantry(country, myHex, count)
        local units = {}
        for _, tile in ipairs(Map:GetChildren()) do
            if tile.Color:ToHex() ~= myHex then continue end
            local m = tile:FindFirstChildWhichIsA("Model")
            if not m then continue end
            if m:GetAttribute("state") ~= "Idle" then continue end
            local troopName = m:GetAttribute("troopName") or ""
            -- AntiTank ve Tank değil
            if troopName:find("AntiTank") or troopName:find("Tank") then continue end
            if navalState.usedArmies[m] then continue end
            local pow = (m:GetAttribute("attack") or 0) * (m:GetAttribute("health") or 0)
            table.insert(units, {tile = tile, model = m, pow = pow, troopName = troopName})
        end
        table.sort(units, function(a,b) return a.pow > b.pow end)
        local result = {}
        for i = 1, math.min(count, #units) do
            table.insert(result, units[i])
        end
        return result
    end
    local function getTransportShips(country)
        local ships = {}
        local cities = country:FindFirstChild("Cities")
        if not cities then return ships end
        for _, city in ipairs(cities:GetChildren()) do
            local port = city:FindFirstChild("Port")
            if not port then continue end
            local docked = port:FindFirstChild("DockedShips")
            if not docked then continue end
            for _, ship in ipairs(docked:GetChildren()) do
                local divCap = ship:GetAttribute("divisionCapacity") or 0
                if divCap <= 0 then continue end -- sadece transport
                local loaded = game:GetService("HttpService"):JSONDecode(ship:GetAttribute("loadedDivisions") or "[]")
                local freeSlots = divCap - #loaded
                if freeSlots > 0 then
                    table.insert(ships, {ship = ship, city = city, freeSlots = freeSlots, totalCap = divCap})
                end
            end
        end
        return ships
    end
    local function getPortTile(city)
        local tileName = tostring(city:GetAttribute("tileName") or "")
        return Map:FindFirstChild(tileName)
    end

    local function getSeaTileAdjacentTo(tile)
        -- Port tile'ına komşu deniz tile'ını bul
        local ns = PreviewPath_naval.neighbours[tile]
        if not ns then return nil end
        for _, n in ipairs(ns) do
            if n.Name:match("^Sea") then return n end
        end
        return nil
    end
    local function autoNavalTick(snap)
        if not State.AutoNaval then return end
        if os.clock() - navalState.lastAt < 5 then return end
        navalState.lastAt = os.clock()

        local country = snap.country
        local myHex   = snap.myColorHex
        local myColor = snap.myColor
        -- Düşman capital'ini bul
        local targetTile, enemyCountry = getEnemyCapitalTile(country)
        if not targetTile then
            print("[NAVAL] Düşman capital bulunamadı — savaşta değil")
            return
        end

        -- Transport ship var mı?
        local transports = getTransportShips(country)
        if #transports == 0 then
            print("[NAVAL] Transport ship yok — bekliyor")
            return
        end
        -- En iyi infantry ordularını al (ship kapasitesi kadar)
        local totalCap = 0
        for _, t in ipairs(transports) do totalCap = totalCap + t.freeSlots end
        local infantry = getBestInfantry(country, myHex, totalCap)

        if #infantry == 0 then
            print("[NAVAL] Yüklenebilir infantry yok")
            return
        end
        -- Phase 1: Infantry'yi porta hareket ettir ve gemiye yükle
        local allowed = {[myHex] = true}
        local dip = country:FindFirstChild("Diplomacy")
        if dip then
            local ef = dip:FindFirstChild("Enemies")
            if ef then for _, e in ipairs(ef:GetChildren()) do
                if e.Value then allowed[e.Value:GetAttribute("color"):ToHex()] = true end
            end end
        end
        local loadedCount = 0
        for _, transport in ipairs(transports) do
            if loadedCount >= #infantry then break end
            local portTile = getPortTile(transport.city)
            if not portTile then continue end

            for slot = 1, transport.freeSlots do
                local unitIdx = loadedCount + 1
                if unitIdx > #infantry then break end
                local unit = infantry[unitIdx]
                -- Önce porta hareket et
                if unit.tile ~= portTile then
                    local path = PreviewPath_naval.ComputePath(unit.tile, portTile, allowed)
                    if path then
                        local ok = pcall(function()
                            game.ReplicatedStorage.Player.MoveTroop:FireServer(path)
                        end)
                        if ok then
                            print(("[NAVAL] %s → %s (port)"):format(unit.troopName, transport.city.Name))
                            task.wait(0.5)
                        end
                    end
                end
                -- Gemiye yükle
                local loadOk = pcall(function()
                    LoadDivisionOnShip:FireServer(transport.ship)
                end)
                if loadOk then
                    navalState.usedArmies[unit.model] = true
                    loadedCount = loadedCount + (1)
                    print(("[NAVAL] Loaded %s onto %s"):format(unit.troopName, transport.ship.Name))
                    task.wait(0.3)
                end
            end
            -- Gemi dolu veya yükledik — limandan çık
            if loadedCount > 0 then
                task.wait(1)
                local exitOk, exitErr = pcall(function()
                    return TryExitPortWithFleet:InvokeServer(transport.city, {transport.ship})
                end)
                if exitOk then
                    print(("[NAVAL] Fleet exited %s → heading to %s"):format(
                        transport.city.Name, targetTile.Name))
                    navalState.phase = "sailing"
                else
                    warn("[NAVAL] Exit failed:", tostring(exitErr))
                end
            end
        end
        -- Phase 2: Denizde olan transport'lar hedef kıyısına varınca MoveTroop
        -- Gemi hedef tile'a komşu sea tile'ına gelince iniş yap
        task.spawn(function()
            local enemyHex = enemyCountry and enemyCountry:GetAttribute("color"):ToHex() or ""
            -- Hedef tile'a komşu sea tile'ı
            local landingSeaTile = getSeaTileAdjacentTo(targetTile)
            if not landingSeaTile then
                warn("[NAVAL] Hedef tile'a komşu sea tile yok")
                return
            end
            -- Çıkartma yeri — hedef capital veya en yakın düşman kıyı tile'ı
            -- MoveTroop ile denizden karaas geçiş: deniz → düşman tile
            local landingAllowed = {}
            for k, v in pairs(allowed) do landingAllowed[k] = v end
            -- Buradaki MoveTroop çağrısı gemi kıyıya yanaştığında tetiklenir
            -- Oyunda gemi otomatik hareket eder, biz sadece unload zamanını bekleriz
            print("[NAVAL] Fleet sailing — invasion will complete automatically when ships arrive")
        end)
    end
    -- ═══════════════════════════════════════════════════════
    -- AUTO DIPLOMACY
    -- Justify war against weak neighbors, then declare war
    -- Auto peace when outmatched
    -- ═══════════════════════════════════════════════════════
    local TryJustifyWar  = game:GetService("ReplicatedStorage").Diplomacy.TryJustifyWar
    local TryDeclareWar  = game:GetService("ReplicatedStorage").Diplomacy.TryDeclareWar
    local TrySendTreaty  = game:GetService("ReplicatedStorage").Diplomacy.TrySendTreaty
    local Countries      = game:GetService("ReplicatedStorage"):WaitForChild("Countries")
    local dipState = {
        lastJustifyAt   = 0,
        lastDeclareAt   = 0,
        lastPeaceAt     = 0,
        justifying      = {},  -- countryName → true if justification in progress
    }

    local function autoMissileTick(snap) end  -- forward declare, defined below
    local function autoRealDipTick(snap)
        if not State.AutoDiplomacy then return end
        local country = snap.country
        local myColor = country:GetAttribute("color")
        local myHex   = myColor and myColor:ToHex() or ""
        local money   = snap.economy.money
        local Map     = workspace.Map
        -- Power assessment: total attack power of all our armies
        local myPower = 0
        for _, tile in ipairs((tileCache.byHex[myHex] or {})) do
            local m = tile:FindFirstChildWhichIsA("Model")
            if m then
                local h = numAttr(m,"health"); local a = numAttr(m,"attack")
                myPower = myPower + h * a
            end
        end

        local dip = country:FindFirstChild("Diplomacy")
        if not dip then return end
        -- ── AUTO PEACE: if we are losing badly, send peace treaty ──
        if os.clock() - dipState.lastPeaceAt > 60 then
            local enemies = dip:FindFirstChild("Enemies")
            if enemies then
                for _, e in ipairs(enemies:GetChildren()) do
                    if not e.Value then continue end
                    local eHex = e.Value:GetAttribute("color"):ToHex()
                    local enemyPower = 0
                    for _, tile in ipairs((tileCache.byHex[eHex] or {})) do
                        local m = tile:FindFirstChildWhichIsA("Model")
                        if m then
                            local h = numAttr(m,"health"); local a = numAttr(m,"attack")
                            enemyPower = enemyPower + h * a
                        end
                    end
                    -- Enemy is 2.5x stronger → request peace
                    if enemyPower > myPower * 2.5 then
                        local eFolder = Countries:FindFirstChild(e.Value.Name)
                        if eFolder then
                            pcall(function()
                                TrySendTreaty:InvokeServer(eFolder, "Peace")
                            end)
                            print("[DIP] Peace requested with", e.Value.Name, "— outmatched")
                            dipState.lastPeaceAt = os.clock()
                        end
                    end
                end
            end
        end
        -- ── AUTO JUSTIFY: find weak neighbor not at war with us ──
        if os.clock() - dipState.lastJustifyAt < 45 then return end

        -- PP check
        local pp = country:GetAttribute("politicalPower") or 0
        if pp < 35 then return end  -- need at least 35 PP for justification

        -- Find weakest country bordering us that we're not at war with
        local bestTarget = nil
        local bestScore  = math.huge
        for _, eCountry in ipairs(Countries:GetChildren()) do
            local eColor = eCountry:GetAttribute("color")
            if not eColor then continue end
            local eHex = eColor:ToHex()
            if eHex == myHex then continue end
            -- Already at war?
            local alreadyEnemy = false
            local enemies = dip:FindFirstChild("Enemies")
            if enemies then
                for _, e in ipairs(enemies:GetChildren()) do
                    if e.Value and e.Value == eCountry then alreadyEnemy = true; break end
                end
            end
            if alreadyEnemy then continue end

            -- Already justifying?
            if dipState.justifying[eCountry.Name] then continue end
            -- Is this country neighboring us?
            local isNeighbor = false
            for _, tile in ipairs((tileCache.byHex[eHex] or {})) do
                local ns = PreviewPath.neighbours[tile]
                if ns then
                    for _, n in ipairs(ns) do
                        if not n.Name:match("^Sea") and n.Color:ToHex() == myHex then
                            isNeighbor = true; break
                        end
                    end
                end
                if isNeighbor then break end
            end
            if not isNeighbor then continue end
            -- Their power
            local ePower = 0
            local eTiles = #(tileCache.byHex[eHex] or {})
            for _, tile in ipairs((tileCache.byHex[eHex] or {})) do
                local m = tile:FindFirstChildWhichIsA("Model")
                if m then
                    local h = numAttr(m,"health"); local a = numAttr(m,"attack")
                    ePower = ePower + h * a
                end
            end
            -- Only target weaker countries (we have 1.5x their power)
            if myPower < ePower * 1.5 then continue end

            -- Score: fewer tiles + less power = easier target
            local score = ePower + eTiles * 10
            if score < bestScore then
                bestScore  = score
                bestTarget = eCountry
            end
        end
        if bestTarget then
            local ok, err = pcall(function()
                return TryJustifyWar:InvokeServer(bestTarget)
            end)
            if ok then
                dipState.justifying[bestTarget.Name] = true
                dipState.lastJustifyAt = os.clock()
                print("[DIP] Justifying war against:", bestTarget.Name)
            else
                print("[DIP] Justify failed:", tostring(err))
            end
        end
        -- ── AUTO DECLARE: if justification complete, declare war ──
        if os.clock() - dipState.lastDeclareAt < 30 then return end
        local justF = dip:FindFirstChild("Justification")
        if justF then
            for _, just in ipairs(justF:GetChildren()) do
                local progress = just:GetAttribute("progress") or 0
                if progress >= 1 then
                    local targetFolder = Countries:FindFirstChild(just.Name)
                    if targetFolder then
                        local ok2 = pcall(function()
                            TryDeclareWar:InvokeServer(targetFolder)
                        end)
                        if ok2 then
                            dipState.justifying[just.Name] = nil
                            dipState.lastDeclareAt = os.clock()
                            print("[DIP] War declared on:", just.Name)
                        end
                    end
                end
            end
        end
    end
    -- ═══════════════════════════════════════════════════════
    -- AUTO MISSILE LAUNCH
    -- Fires missiles at enemy capitals/high-value tiles
    -- Prioritizes: capital > urban > high army density
    -- ═══════════════════════════════════════════════════════
    local LaunchMissileRF = game:GetService("ReplicatedStorage").TileProjects.LaunchMissile
    local lastMissileAt   = 0
    local function autoMissileTick(snap)
        if not State.AutoMissile then return end
        if os.clock() - lastMissileAt < 20 then return end -- cooldown

        local country = snap.country
        local myHex   = snap.myColorHex
        local Map     = workspace.Map
        -- Find our missile silos with ammo
        local siloTiles = {}
        local cities = country:FindFirstChild("Cities")
        if cities then
            for _, city in ipairs(cities:GetChildren()) do
                local tileName = tostring(city:GetAttribute("tileName") or "")
                local tile = Map:FindFirstChild(tileName)
                if not tile then continue end
                if not tile:GetAttribute("hasMissileSilo") then continue end
                -- Check ammo: get missile item name based on silo level
                local siloLevel = tile:GetAttribute("missileSiloLevel") or 1
                local prodF     = country:FindFirstChild("ProductionItems")
                local ammo      = 0
                if prodF then
                    -- Missile item names: "Ballistic Missiles I", "II", "III"
                    local tiers  = {"Ballistic Missiles I", "Ballistic Missiles II", "Ballistic Missiles III"}
                    local itemName = tiers[math.clamp(siloLevel, 1, 3)]
                    local item   = prodF:FindFirstChild(itemName)
                    if item then ammo = item:GetAttribute("stock") or 0 end
                end
                if ammo > 0 then
                    table.insert(siloTiles, {tile = tile, ammo = ammo, level = siloLevel})
                end
            end
        end

        if #siloTiles == 0 then return end

        -- Find best target tile (enemy capital first, then urban, then army dense)
        local bestTarget = nil
        local bestScore  = -math.huge
        for hex, eCountry in pairs(snap.enemyColors or {}) do
            -- Check silo range
            local maxRange = 0
            local techsF = country:FindFirstChild("Techs")
            if techsF then
                -- GetSiloRange equivalent: base range per level
                local SILO_RANGES = {60, 120, 200}
                for _, st in ipairs(siloTiles) do
                    maxRange = math.max(maxRange, SILO_RANGES[math.clamp(st.level, 1, 3)])
                end
            end
            for _, tile in ipairs((tileCache.byHex[hex] or {})) do
                -- Score target
                local score = 0
                if tile:GetAttribute("isCapital") then score = score + 500 end
                if tile:GetAttribute("hasCity")   then score = score + 100 end
                local m = tile:FindFirstChildWhichIsA("Model")
                if m then
                    -- High HP army = good target
                    score = score + (numAttr(m, "health") * numAttr(m, "attack")) * 2
                end
                -- Range check: distance from nearest silo
                local inRange = false
                for _, st in ipairs(siloTiles) do
                    local dist = (st.tile.Position - tile.Position).Magnitude
                    if dist <= maxRange * 10 then  -- stud conversion estimate
                        inRange = true; break
                    end
                end
                if not inRange then continue end
                if score > bestScore then
                    bestScore  = score
                    bestTarget = tile
                end
            end
        end

        if not bestTarget then return end

        -- Collect silo tiles array (as expected by server)
        local siloArr = {}
        for _, st in ipairs(siloTiles) do table.insert(siloArr, st.tile) end
        local ok, result = pcall(function()
            return LaunchMissileRF:InvokeServer(siloArr, bestTarget, false)  -- false = missile, not nuke
        end)

        if ok and result then
            lastMissileAt = os.clock()
            print("[MSL] Missile launched at:", bestTarget.Name)
        elseif not ok then
            warn("[MSL] Launch failed:", tostring(result))
        end
    end
    -- ═══════════════════════════════════════════════════════
    -- AUTO MISSILE SILO BUILDER
    -- ═══════════════════════════════════════════════════════
    local PurchaseMissileSiloRE = ReplicatedStorage:WaitForChild("TileProjects"):WaitForChild("PurchaseMissileSilo")
    local lastSiloAt = 0
    local function getSiloLevel(tile)
        if tile:GetAttribute("hasMissileSilo") ~= true then return 0 end
        local lv = tile:GetAttribute("missileSiloLevel")
        return type(lv) == "number" and math.clamp(math.floor(lv), 1, 3) or 1
    end
    local function getSiloQueue(tile)
        local q = tile:GetAttribute("missileSiloBuildQueue")
        if type(q) == "number" then return math.max(0, math.floor(q)) end
        if tile:GetAttribute("missileSiloBuildStart") then return 1 end
        return 0
    end
    local function getSiloCost(country, nextLevel)
        local techs = country:FindFirstChild("Techs")
        if not techs then return 15000 end
        local base = techs:GetAttribute("missileSiloPrice") or 15000
        local perLv = techs:GetAttribute("missileSiloPricePerLevel") or 10000
        return base + (math.clamp(nextLevel, 1, 3) - 1) * perLv
    end
    local function getSiloTechLevel(country)
        -- Ballistic Missiles I/II/III araştırma seviyesi
        local techs = country:FindFirstChild("Techs")
        if not techs then return 0 end
        local maxLv = 0
        for i = 1, 3 do
            local names = {"Ballistic Missiles I", "Ballistic Missiles II", "Ballistic Missiles III"}
            local nd = techs:FindFirstChild(names[i])
            if nd and nd:GetAttribute("progress") == 1 then maxLv = i end
        end
        return maxLv
    end
    -- Tile score: front'tan uzak, capital'a yakın, iç tile'lar tercihli
    local function scoreSiloTile(tile, myHex, frontTiles, protectedTiles)
        local score = 0
        -- Front tile'ı değilse +50 (silo front'ta olmamalı — vurulur)
        if not frontTiles[tile] then score = score + 50 end
        -- Protected (capital çevresi) ise +30
        if protectedTiles[tile] then score = score + 30 end
        -- Terrain: mountain/hills tercihli (savunma)
        local terrain = tile:GetAttribute("terrain") or ""
        if terrain == "mountain" then score = score + 20
        elseif terrain == "hills" then score = score + 10 end
        return score
    end
    local function autoSiloTick(snap)
        if not State.AutoSilo then return end
        if os.clock() - lastSiloAt < 8 then return end -- her 8s max 1 build

        local country = snap.country
        local money = snap.economy.money
        local myHex = snap.myColorHex
        local techLevel = getSiloTechLevel(country)
        if techLevel == 0 then return end -- hiç silo tech araştırılmamış
        -- Front ve protected tile'ları bul
        local frontTiles = snap.frontTiles
        local protectedTiles = {}
        local cf = country:FindFirstChild("Cities")
        if cf then
            for _, city in ipairs(cf:GetChildren()) do
                if city:GetAttribute("isCapital") then
                    local tileName = tostring(city:GetAttribute("tileName") or "")
                    local t = Map:FindFirstChild(tileName)
                    if t then protectedTiles[t] = true end
                end
            end
        end
        -- Kendi tile'larını tara, silo build edilebilecekleri bul
        local candidates = {}
        for _, tile in ipairs(Map:GetChildren()) do
            if tile.Name:match("^Sea") then continue end
            if tile.Color:ToHex() ~= myHex then continue end

            local curLevel = getSiloLevel(tile)
            local queueCount = getSiloQueue(tile)
            local nextLevel = curLevel + queueCount + 1
            -- Max level veya zaten build queue dolu
            if nextLevel > 3 then continue end
            -- Tech seviyesi yeterli mi?
            if techLevel < nextLevel then continue end
            -- Zaten build'de mi?
            if tile:GetAttribute("missileSiloBuildStart") and queueCount >= 1 then continue end

            local cost = getSiloCost(country, nextLevel)
            if money - cost < 20000 then continue end -- 20k reserve
            local score = scoreSiloTile(tile, myHex, frontTiles, protectedTiles)
            table.insert(candidates, {tile = tile, cost = cost, nextLevel = nextLevel, score = score})
        end

        if #candidates == 0 then return end

        -- En iyi tile'ı seç: score yüksek, mevcut level düşük önce
        table.sort(candidates, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.nextLevel < b.nextLevel
        end)
        local best = candidates[1]
        local ok, err = pcall(function()
            PurchaseMissileSiloRE:FireServer(best.tile)
        end)

        if ok then
            lastSiloAt = os.clock()
            print(("[SILO] Build queued: %s → Level %d ($%d)"):format(
                best.tile.Name, best.nextLevel, best.cost))
        else
            warn("[SILO] FireServer error:", tostring(err))
        end
    end
    -- ═══ AUTO PLANE DEPLOYMENT ════════════════════════════════
    local planeDeployed = {}
    local function getEnemyHexes(country)
        local hexes = {}
            local dip = country:FindFirstChild("Diplomacy")
        if not dip then return hexes end
        local enemies = dip:FindFirstChild("Enemies")
        if not enemies then return hexes end
        for _, e in ipairs(enemies:GetChildren()) do
            if e.Value then
                local col = e.Value:GetAttribute("color")
                if col then hexes[col:ToHex()] = true end
            end
        end
        return hexes
    end
    local function getMyAirfields(country)
        local result = {}
        local cities = country:FindFirstChild("Cities")
        if not cities then return result end
        for _, city in ipairs(cities:GetChildren()) do
            local af = city:FindFirstChild("Airfield")
            if not af then continue end
            local tileName = tostring(city:GetAttribute("tileName") or "")
            local mapTile = Map:FindFirstChild(tileName)
            if not mapTile then continue end
            local pdRaw = af:GetAttribute("planeData")
            if not pdRaw then continue end
            local pdOk, pd = pcall(HttpService.JSONDecode, HttpService, pdRaw)
            if not pdOk then continue end
            local hasPlanes = false
            for _, v in pairs(pd) do if v > 0 then hasPlanes = true; break end end
            if not hasPlanes then continue end
            table.insert(result, { mapTile = mapTile, airfield = af, planeData = pd })
        end
        return result
    end
    local function getEnemyAirTiles(enemyHexes)
        local seen, result = {}, {}
        for _, tile in ipairs(Map:GetChildren()) do
            if tile.Name:match("^Sea") then continue end
            local tHex = tile.Color:ToHex()
            if not enemyHexes[tHex] then continue end
            local region = tile:GetAttribute("airRegion")
            if not region or seen[region] then continue end
            local airTile = AirMap:FindFirstChild(region)
            if airTile then seen[region] = true; table.insert(result, airTile) end
        end
        return result
    end
    local function buildPlaneObj(pd)
        if CommonTypes then
            local obj = CommonTypes.PlaneData.new()
            for k, v in pairs(pd) do if obj[k] ~= nil then obj[k] = v end end
            return obj
        end
        return pd
    end
    local function autoPlanesTick(snap)
        if not State.AutoPlanes then return end
        local country = snap.country
        local enemyHexes = getEnemyHexes(country)
        if not next(enemyHexes) then return end
        local airfields = getMyAirfields(country)
        if #airfields == 0 then return end
        local enemyAirTiles = getEnemyAirTiles(enemyHexes)
        if #enemyAirTiles == 0 then return end
        for _, af in ipairs(airfields) do
            for _, targetAirTile in ipairs(enemyAirTiles) do
                local key = af.mapTile.Name .. "_" .. targetAirTile.Name
                if planeDeployed[key] then continue end
                local planeObj = buildPlaneObj(af.planeData)
                local dOk, res = pcall(function()
                    return TryDeployPlanes:InvokeServer(af.mapTile, targetAirTile, planeObj)
                end)
                if dOk and res then
                    planeDeployed[key] = true
                    print(("[AIR] ✓ %s → %s"):format(af.mapTile.Name, targetAirTile.Name))
                    break -- airfield başına 1 hedef yeter
                end
                task.wait(0.3)
            end
        end
    end
    -- Savaş değişince cache temizle
    task.spawn(function()
        while true do
            local country = getCountry()
            if country then
                local dip = country:FindFirstChild("Diplomacy")
                if dip then
                    local enemies = dip:FindFirstChild("Enemies")
                    if enemies then
                        enemies.ChildAdded:Connect(function() planeDeployed = {} end)
                        enemies.ChildRemoved:Connect(function() planeDeployed = {} end)
                    end
                end
            end
            task.wait(10)
        end
    end)
    -- ═══ MEVCUT TERRAIN / TACTICAL ═══════════════════════════
    local TERRAIN_DEF    = { mountain = 4, hills = 2, forest = 1, urban = 1 }
    local ATTACK_RATIO   = 1.1  -- agresif: %10 üstünlük yeterli (eski: 1.4)
    local SURROUND_BONUS = 0.4  -- encirclement bonus artırıldı (eski: 0.25)
    local MAX_ACTIONS    = 30   -- 12→30 hamle per tick
    local CAPITAL_RING   = 1    -- daha dar capital guard → daha fazla ordu front'a
    local TILE_CACHE_TTL = 5
    local PATH_YIELD     = 4
    local MULTI_TARGET   = 4    -- aynı anda max kaç düşmana saldır
    local tileCache = { byHex = {}, lastBuild = 0 }
    local function rebuildCache()
        if os.clock() - tileCache.lastBuild < TILE_CACHE_TTL then return end
        tileCache.byHex = {}
        for _, tile in ipairs(Map:GetChildren()) do
            if tile.Name:match("^Sea") then continue end
            local hex = tile.Color:ToHex()
            if not tileCache.byHex[hex] then tileCache.byHex[hex] = {} end
            table.insert(tileCache.byHex[hex], tile)
        end
        tileCache.lastBuild = os.clock()
    end
    local function uPow(m, tile, role)
        if not m then return 0 end
        local h = numAttr(m,"health"); local a = numAttr(m,"attack"); local d = numAttr(m,"defense"); local e = numAttr(m,"experience")
        local em = 1 + e*0.15; local td = tile and (TERRAIN_DEF[tile:GetAttribute("terrain")] or 0) or 0
        if role == "attack" then return h*a*em elseif role == "defend" then return h*(d+td)*em else return h*(a+d+td)*em end
    end
    local function buildProtected(country)
        local p = {}; local cf = country:FindFirstChild("Cities"); if not cf then return p end
        for _, city in ipairs(cf:GetChildren()) do
            if not city:GetAttribute("isCapital") then continue end
            local root = Map:FindFirstChild(tostring(city:GetAttribute("tileName"))); if not root then continue end
            local frontier = {root}; local visited = {[root]=true}; p[root] = true
            for _ = 1, CAPITAL_RING do
                local nf = {}
                for _, tile in pairs(frontier) do
                    local ns = PreviewPath.neighbours[tile]; if not ns then continue end
                    for _, n in pairs(ns) do if not n.Name:match("^Sea") and not visited[n] then visited[n]=true; p[n]=true; table.insert(nf,n) end end
                end
                frontier = nf
            end
        end; return p
    end
    local function buildAllowed(country, enemyHexes, myHex)
        local a = {[myHex]=true}; local dip = country:FindFirstChild("Diplomacy")
        if dip then for _, fn in ipairs({"Allies","Puppets"}) do local f = dip:FindFirstChild(fn); if f then for _, m in ipairs(f:GetChildren()) do if m.Value then a[m.Value:GetAttribute("color"):ToHex()]=true end end end end end
        for hex in pairs(enemyHexes) do a[hex]=true end; return a
    end
    local function encBonus(t, myHex)
        local ns = PreviewPath.neighbours[t]; if not ns then return 1 end
        local c = 0; for _, n in pairs(ns) do if not n.Name:match("^Sea") and n.Color:ToHex()==myHex then c = c + 1 end end
        return c>=3 and 2 or c==2 and 1.3 or 1
    end
    local function findRes(from, myHex, myColor, used, prot)
        local frontier={from}; local visited={[from]=true}; local best={score=-1,tile=nil,model=nil}
        for _ = 1, 2 do
            local nf={}
            for _, tile in pairs(frontier) do
                local ns = PreviewPath.neighbours[tile]; if not ns then continue end
                for _, n in pairs(ns) do
                    if n.Name:match("^Sea") or visited[n] or n.Color:ToHex()~=myHex or prot[n] then continue end
                    visited[n]=true; table.insert(nf,n)
                    local m = n:FindFirstChildWhichIsA("Model")
                    if m and m:GetAttribute("color")==myColor and m:GetAttribute("state")=="Idle" and not used[m] then
                        local s=uPow(m,n,"attack"); if s>best.score then best={score=s,tile=n,model=m} end
                    end
                end
            end; frontier=nf
        end; return best.tile, best.model
    end
    -- ═══════════════════════════════════════════════════════════════
    -- SOI LIVE SCANNER API — Real-time army intelligence
    -- Works for ANY country. Exposed via getgenv()._SOI
    -- Updates every 2 seconds in background
    -- ═══════════════════════════════════════════════════════════════
    local RS_scan    = game:GetService("ReplicatedStorage")
    local ArmyCm_s   = require(RS_scan.Common.ArmyCommon)
    local TM_s       = ArmyCm_s.terrainModifiers
    local Map_s      = workspace:WaitForChild("Map")
    local PreviewPath_s = require(LocalPlayer.PlayerScripts.PlayerControls.PreviewPath)
    local function _troopCls(m)
        if not m then return "Infantry" end
        local tn = m:GetAttribute("troopName") or ""
        if tn:find("Tank") and not tn:find("Anti") then return "Tanks"
        elseif tn:find("Anti") then return "AntiTank" else return "Infantry" end
    end
    local function _terrCoef(terrain, cls, stat)
        local t = TM_s[terrain]
        if not t then return 1 end
        if stat == "atk" then
            return (cls=="Tanks" and t.TanksAttackCoef) or (cls=="AntiTank" and t.AntiTankAttackCoef) or t.InfantryAttackCoef or 1
        elseif stat == "def" then
            return (cls=="Tanks" and t.TanksDefenseCoef) or (cls=="AntiTank" and t.AntiTankDefenseCoef) or t.InfantryDefenseCoef or 1
        elseif stat == "spd" then
            return (cls=="Tanks" and t.TanksSpeedCoef) or (cls=="AntiTank" and t.AntiTankSpeedCoef) or t.InfantrySpeedCoef or 1
        end
        return 1
    end
    local function _atkPow(m, tile)
        if not m then return 0 end
        local h=m:GetAttribute("health") or 0
        local a=m:GetAttribute("attack") or 0
        local exp=m:GetAttribute("experience") or 0
        local cls=_troopCls(m)
        local terrain=tile and (tile:GetAttribute("terrain") or "none") or "none"
        return h*a*_terrCoef(terrain,cls,"atk")*(1+exp*0.15)
    end
    local function _defPow(m, tile)
        if not m then return 0 end
        local h=m:GetAttribute("health") or 0
        local d=m:GetAttribute("defense") or 0
        local exp=m:GetAttribute("experience") or 0
        local cls=_troopCls(m)
        local terrain=tile and (tile:GetAttribute("terrain") or "none") or "none"
        return h*d*_terrCoef(terrain,cls,"def")*(1+exp*0.15)
    end
    -- Main scan function — works for any country
    local function scanCountry(country)
        if not country then return nil end
        local myColor = country:GetAttribute("color")
        local myHex   = myColor and myColor:ToHex() or ""
        local dip = country:FindFirstChild("Diplomacy")
        local enemyHexes = {}
        local atWar = false
        if dip then
            local ef = dip:FindFirstChild("Enemies")
            if ef then for _, e in ipairs(ef:GetChildren()) do
                if e.Value then
                    enemyHexes[e.Value:GetAttribute("color"):ToHex()] = e.Value
                    atWar = true
                end
            end end
        end
        local result = {
            country     = country.Name,
            atWar       = atWar,
            timestamp   = os.clock(),
            -- Army counts
            total       = 0,
            idle        = 0,
            moving      = 0,
            waiting     = 0,
            onFront     = 0,
            -- Power
            atkPow      = 0,
            defPow      = 0,
            enemyAtkPow = 0,
            enemyDefPow = 0,
            enemyCount  = 0,
            -- Composition
            infantry    = 0,
            tanks       = 0,
            antitank    = 0,
            -- Front
            frontTiles  = 0,
            coveredFront= 0,
            exposedFront= 0,
            coverage    = 0,
            -- Tiles
            myTiles     = 0,
            enemyTiles  = 0,
            -- Derived
            powerRatio  = 0,
            strategy    = "BALANCED",
            -- Individual armies for tactical use
            armies      = {},
            enemyArmies = {},
            exposedTiles= {},
        }
        -- Scan map
        for _, tile in ipairs(Map_s:GetChildren()) do
            if tile.Name:match("^Sea") then continue end
            local tHex = tile.Color:ToHex()
            local m = tile:FindFirstChildWhichIsA("Model")
            if tHex == myHex then
                result.myTiles = result.myTiles + 1
                -- Front check
                local ns = PreviewPath_s.neighbours[tile]
                local isFront, threat = false, 0
                if ns then
                    for _, n in ipairs(ns) do
                        if not n.Name:match("^Sea") and enemyHexes[n.Color:ToHex()] then
                            isFront = true
                            local nm = n:FindFirstChildWhichIsA("Model")
                            threat = threat + (nm and _atkPow(nm,n) or 30)
                        end
                    end
                end
                if isFront then
                    result.frontTiles = result.frontTiles + 1
                    if m then result.coveredFront = result.coveredFront + 1
                    else
                        result.exposedFront = result.exposedFront + 1
                        table.insert(result.exposedTiles, {tile=tile, threat=threat})
                    end
                end
                -- Army stats
                if m then
                    result.total = result.total + 1
                    local st  = m:GetAttribute("state") or "Idle"
                    local cls = _troopCls(m)
                    local ap  = _atkPow(m, tile)
                    local dp  = _defPow(m, tile)
                    if st=="Idle"    then result.idle    = result.idle    + 1 end
                    if st=="Moving"  then result.moving  = result.moving  + 1 end
                    if st=="Waiting" then result.waiting = result.waiting + 1 end
                    if isFront       then result.onFront = result.onFront + 1 end
                    if cls=="Tanks"    then result.tanks    = result.tanks    + 1 end
                    if cls=="AntiTank" then result.antitank = result.antitank + 1 end
                    if cls=="Infantry" then result.infantry = result.infantry + 1 end
                    result.atkPow = result.atkPow + ap
                    result.defPow = result.defPow + dp
                    table.insert(result.armies, {
                        tile=tile, model=m, state=st, cls=cls,
                        atk=ap, def=dp, isFront=isFront, threat=threat,
                        locked=isFront and threat>0 and st=="Idle",
                    })
                end
            elseif enemyHexes[tHex] then
                result.enemyTiles = result.enemyTiles + 1
                if m then
                    result.enemyCount = result.enemyCount + 1
                    local ap = _atkPow(m, tile)
                    local dp = _defPow(m, tile)
                    result.enemyAtkPow = result.enemyAtkPow + ap
                    result.enemyDefPow = result.enemyDefPow + dp
                    local ns2 = PreviewPath_s.neighbours[tile]
                    local enc, adjMine = 1.0, 0
                    if ns2 then
                        for _, n in ipairs(ns2) do
                            if not n.Name:match("^Sea") and n.Color:ToHex()==myHex then adjMine=adjMine+1 end
                        end
                        enc = adjMine==0 and 1 or adjMine==1 and 1.4 or adjMine==2 and 2.0 or adjMine==3 and 3.0 or 4.0
                    end
                    local st = m:GetAttribute("state") or "Idle"
                    local effDef = dp / enc
                    if m:GetAttribute("dieOnNextRetreat") then effDef = effDef * 0.04 end
                    if st=="Retreating" then effDef = effDef * 0.12 end
                    table.insert(result.enemyArmies, {
                        tile=tile, model=m, atk=ap, def=dp, effDef=effDef,
                        enc=enc, state=st, empty=false,
                        dying=m:GetAttribute("dieOnNextRetreat") or false,
                        isCapital=tile:GetAttribute("isCapital") or false,
                    })
                else
                    -- Empty enemy tile
                    local ns2 = PreviewPath_s.neighbours[tile]
                    local adjMine = 0
                    if ns2 then
                        for _, n in ipairs(ns2) do
                            if not n.Name:match("^Sea") and n.Color:ToHex()==myHex then adjMine=adjMine+1 end
                        end
                    end
                    if adjMine > 0 then
                        table.insert(result.enemyArmies, {
                            tile=tile, model=nil, atk=0, def=0, effDef=0,
                            enc=1, state="Empty", empty=true,
                            isCapital=tile:GetAttribute("isCapital") or false,
                        })
                    end
                end
            end
        end
        -- Derived stats
        result.coverage   = result.frontTiles>0 and (result.coveredFront/result.frontTiles) or 1
        result.powerRatio = result.enemyDefPow>0 and (result.atkPow/result.enemyDefPow) or 9
        -- Sort armies: locked front attackers first, then by atk
        table.sort(result.armies, function(a,b)
            if a.locked ~= b.locked then return a.locked end
            return a.atk > b.atk
        end)
        -- Sort enemy: empty/dying first, then weakest effDef
        table.sort(result.enemyArmies, function(a,b)
            if a.empty ~= b.empty then return a.empty end
            if a.dying ~= b.dying then return a.dying end
            if a.isCapital ~= b.isCapital then return a.isCapital end
            return a.effDef < b.effDef
        end)
        -- Sort exposed front tiles by threat
        table.sort(result.exposedTiles, function(a,b) return a.threat>b.threat end)
        -- Strategy
        local cov = result.coverage
        local pr  = result.powerRatio
        if cov < 0.70 then result.strategy = "FORTIFY"
        elseif pr > 2.0 then result.strategy = "CRUSH"
        elseif pr > 1.3 then result.strategy = "AGGRESSIVE"
        elseif pr > 0.8 then result.strategy = "BALANCED"
        else result.strategy = "DEFENSIVE" end

        return result
    end
    -- ═══════════════════════════════════════════════════════════════
    -- LIVE SCANNER — background loop, updates _SOI.data every 2s
    -- ═══════════════════════════════════════════════════════════════
    local SOI_API = {
        data      = nil,       -- latest scan result
        scanning  = true,
        version   = "5.4",
        scan      = scanCountry,  -- call manually: SOI_API.scan(country)
    }
    getgenv()._SOI = SOI_API
    -- HUD GUI — Rayfield'ın üstünde, her zaman görünür
    -- Remove a scanner panel left by an earlier run.
    local oldHUD = CoreGui:FindFirstChild("SOI_HUD")
    if oldHUD then oldHUD:Destroy() end

    -- Background scanner loop
    task.spawn(function()
        while true do
            local co2 = LocalPlayer:FindFirstChild("Country")
            if co2 and co2.Value then
                local ok, data = pcall(scanCountry, co2.Value)
                if ok and data then
                    SOI_API.data = data
                end
            end
            task.wait(2)
        end
    end)
    print("[SOI] Live Scanner active — getgenv()._SOI.data for full data")
    local function tacticalTickAsync(country)
        -- ═══════════════════════════════════════════════════════
        -- SMART TACTICAL AI v4.0 — Group-based attack
        -- Think first, move second.
        -- 1) Analyze full board
        -- 2) Plan optimal assignments (each army → best target)
        -- 3) Execute all moves simultaneously
        -- Key insight: attackerCount matters — send multiple armies
        -- to same target AT ONCE for coordinated kills
        -- ═══════════════════════════════════════════════════════
        local myColor = country:GetAttribute("color")
        local myHex   = myColor and myColor:ToHex() or ""

        local dip = country:FindFirstChild("Diplomacy")
        local enemyHexes = {}
        local allyHexes  = {}
        local atWar = false
        if dip then
            local ef = dip:FindFirstChild("Enemies")
            if ef then
                for _, e in ipairs(ef:GetChildren()) do
                    if e.Value then
                        enemyHexes[e.Value:GetAttribute("color"):ToHex()] = e.Value
                        atWar = true
                    end
                end
            end
            for _, fn in ipairs({"Allies","Puppets"}) do
                local f = dip:FindFirstChild(fn)
                if f then
                    for _, a in ipairs(f:GetChildren()) do
                        if a.Value then
                            allyHexes[a.Value:GetAttribute("color"):ToHex()] = true
                        end
                    end
                end
            end
        end
        if not atWar then return end
        local allowed = {[myHex]=true}
        for hex in pairs(allyHexes)  do allowed[hex] = true end
        for hex in pairs(enemyHexes) do allowed[hex] = true end

        local prot   = buildProtected(country)
        local pathN  = 0

        rebuildCache()
        local myTiles = tileCache.byHex[myHex] or {}
        local function yPath(from, to)
            pathN = pathN + 1
            if pathN % PATH_YIELD == 0 then task.wait() end
            return PreviewPath.ComputePath(from, to, allowed)
        end

        -- ── TERRAIN & POWER ────────────────────────────────────
        local RS_tc  = game:GetService("ReplicatedStorage")
        local ArmyCm = require(RS_tc.Common.ArmyCommon)
        local TM     = ArmyCm.terrainModifiers
        local function troopCls(m)
            if not m then return "Infantry" end
            local tn = m:GetAttribute("troopName") or ""
            if tn:find("Tank") and not tn:find("Anti") then return "Tanks"
            elseif tn:find("Anti") then return "AntiTank"
            else return "Infantry" end
        end
        local function tm(terrain, cls, stat)
            local t = TM[terrain]
            if not t then return 1 end
            if stat=="atk" then
                return cls=="Tanks" and (t.TanksAttackCoef or 1) or
                       cls=="AntiTank" and (t.AntiTankAttackCoef or 1) or
                       (t.InfantryAttackCoef or 1)
            else
                return cls=="Tanks" and (t.TanksDefenseCoef or 1) or
                       cls=="AntiTank" and (t.AntiTankDefenseCoef or 1) or
                       (t.InfantryDefenseCoef or 1)
            end
        end
        local function atkP(m, tile)
            if not m then return 0 end
            local h=m:GetAttribute("health") or 0
            local a=m:GetAttribute("attack") or 0
            local exp=m:GetAttribute("experience") or 0
            local cls=troopCls(m)
            local ter=tile and (tile:GetAttribute("terrain") or "none") or "none"
            return h * a * tm(ter,cls,"atk") * (1+exp*0.15)
        end
        local function defP(m, tile)
            if not m then return 0 end
            local h=m:GetAttribute("health") or 0
            local d=m:GetAttribute("defense") or 0
            local exp=m:GetAttribute("experience") or 0
            local cls=troopCls(m)
            local ter=tile and (tile:GetAttribute("terrain") or "none") or "none"
            return h * d * tm(ter,cls,"def") * (1+exp*0.15)
        end
        -- ── BOARD SCAN ─────────────────────────────────────────
        local idleArmies  = {}   -- {tile, model, atk, def, onFront}
        local enemyTargets = {}  -- {tile, model, def, enc, empty, isCapital, sv}
        local frontSet    = {}   -- tile → threat
        local capitalTile = nil
        local totalMyAtk  = 0
        -- Capital
        local cf = country:FindFirstChild("Cities")
        if cf then
            for _, city in ipairs(cf:GetChildren()) do
                if city:GetAttribute("isCapital") then
                    capitalTile = Map:FindFirstChild(tostring(city:GetAttribute("tileName") or ""))
                    break
                end
            end
        end
        -- My tiles
        for _, tile in ipairs(myTiles) do
            local m = tile:FindFirstChildWhichIsA("Model")
            local ns = PreviewPath.neighbours[tile]
            local isFront, threat = false, 0
            if ns then
                for _, n in ipairs(ns) do
                    if not n.Name:match("^Sea") and enemyHexes[n.Color:ToHex()] then
                        isFront = true
                        local nm = n:FindFirstChildWhichIsA("Model")
                        threat = threat + (nm and atkP(nm,n) or 30)
                    end
                end
            end
            if isFront then frontSet[tile] = threat end
            if m and m:GetAttribute("state")=="Idle" then
                local ap = atkP(m, tile)
                totalMyAtk = totalMyAtk + ap
                table.insert(idleArmies, {
                    tile    = tile,
                    model   = m,
                    atk     = ap,
                    def     = defP(m, tile),
                    onFront = isFront,
                    adjEnemy = isFront, -- directly adjacent to enemy
                })
            end
        end
        -- Enemy tiles
        local totalEnemyDef = 0
        for hex in pairs(enemyHexes) do
            for _, tile in ipairs(tileCache.byHex[hex] or {}) do
                local m  = tile:FindFirstChildWhichIsA("Model")
                local dp = m and defP(m,tile) or 0
                local ap = m and atkP(m,tile) or 0
                -- Encirclement
                local ns = PreviewPath.neighbours[tile]
                local enc, adjMine = 1.0, 0
                local adjToMe = false
                if ns then
                    for _, n in ipairs(ns) do
                        if not n.Name:match("^Sea") and n.Color:ToHex()==myHex then
                            adjMine = adjMine + 1
                            adjToMe = true
                        end
                    end
                    enc = adjMine==0 and 1 or adjMine==1 and 1.4 or
                          adjMine==2 and 2.0 or adjMine==3 and 3.0 or 4.0
                end
                -- Effective defense (weakened by encirclement, retreat, dying)
                local effDef = dp / enc
                local st = m and (m:GetAttribute("state") or "Idle") or "Empty"
                if m and m:GetAttribute("dieOnNextRetreat") then effDef = effDef * 0.04 end
                if st == "Retreating" then effDef = effDef * 0.12 end
                -- Strategic value
                local sv = 10
                local ter = tile:GetAttribute("terrain") or "none"
                local TSCORE = {mountain=40,hills=25,urban=30,forest=18,desert=10,none=8}
                sv = TSCORE[ter] or 8
                if tile:GetAttribute("isCapital") then sv = sv + 300 end
                if tile:GetAttribute("hasCity")   then sv = sv + 30 end
                sv = sv * enc  -- encircled tiles much more valuable
                totalEnemyDef = totalEnemyDef + dp
                -- Only include tiles adjacent to us (can actually attack)
                if adjToMe or (m == nil) then
                    table.insert(enemyTargets, {
                        tile     = tile,
                        model    = m,
                        def      = dp,
                        effDef   = effDef,
                        atk      = ap,
                        enc      = enc,
                        empty    = (m == nil),
                        isCapital= tile:GetAttribute("isCapital") == true,
                        sv       = sv,
                        adjToMe  = adjToMe,
                        dying    = m and m:GetAttribute("dieOnNextRetreat") or false,
                        retreating = st == "Retreating",
                    })
                end
            end
        end
        -- Sort: empty first, dying second, then by value/difficulty ratio
        table.sort(enemyTargets, function(a, b)
            if a.empty ~= b.empty then return a.empty end
            if a.dying ~= b.dying then return a.dying end
            if a.retreating ~= b.retreating then return a.retreating end
            if a.isCapital ~= b.isCapital then return a.isCapital end
            -- Value per unit of difficulty
            local ra = a.sv / math.max(a.effDef, 1)
            local rb = b.sv / math.max(b.effDef, 1)
            return ra > rb
        end)
        table.sort(idleArmies, function(a, b) return a.atk > b.atk end)
        -- ── STRATEGIC MODE ─────────────────────────────────────
        local frontCount, coveredFront = 0, 0
        for tile, _ in pairs(frontSet) do
            frontCount = frontCount + 1
            if tile:FindFirstChildWhichIsA("Model") then coveredFront = coveredFront + 1 end
        end
        local coverage   = frontCount > 0 and (coveredFront/frontCount) or 1.0
        local powerRatio = totalEnemyDef > 0 and (totalMyAtk/totalEnemyDef) or 9.0
        local strategy
        if coverage < 0.50 then
            strategy = "FORTIFY"
        elseif powerRatio > 2.0 then
            strategy = "CRUSH"
        elseif powerRatio > 1.2 then
            strategy = "AGGRESSIVE"
        elseif powerRatio > 0.7 then
            strategy = "BALANCED"
        else
            strategy = "DEFENSIVE"
        end
        -- ── THINK: PLAN ASSIGNMENTS ────────────────────────────
        -- For each target, calculate minimum armies needed to kill
        -- Then assign armies greedily from strongest to weakest target

        local used    = {}
        local actions = 0
        local plan    = {}  -- list of {army, targetTile, path, priority}
        -- ┌─ STEP 1: Capital always defended ───────────────────
        if capitalTile and not capitalTile:FindFirstChildWhichIsA("Model") then
            local best = {score=-1, model=nil, path=nil}
            for _, a in ipairs(idleArmies) do
                if used[a.model] then continue end
                if a.tile == capitalTile then continue end
                -- prefer defensive armies for capital
                local path = yPath(a.tile, capitalTile)
                if path and a.def > best.score then
                    best = {score=a.def, model=a.model, path=path}
                end
            end
            if best.model then
                table.insert(plan, {model=best.model, path=best.path, priority=1000})
                used[best.model] = true
                actions = actions + 1
            end
        end
        -- ┌─ STEP 2: Fill exposed front tiles (ALWAYS) ─────────
        -- Sort by threat descending
        local exposedFront = {}
        for tile, threat in pairs(frontSet) do
            if not tile:FindFirstChildWhichIsA("Model") then
                table.insert(exposedFront, {tile=tile, threat=threat})
            end
        end
        table.sort(exposedFront, function(a,b) return a.threat > b.threat end)
        for _, ef in ipairs(exposedFront) do
            if actions >= MAX_ACTIONS then break end
            -- Find nearest non-front, non-locked army
            local best = {dist=math.huge, model=nil, path=nil}
            for _, a in ipairs(idleArmies) do
                if used[a.model] then continue end
                if capitalTile and a.tile==capitalTile then continue end
                -- Don't pull a front army away if it's the only defender
                if a.onFront and a.adjEnemy then
                    -- Only pull if another army is adjacent to cover
                    local hasBackup = false
                    local ns = PreviewPath.neighbours[a.tile]
                    if ns then
                        for _, n in ipairs(ns) do
                            if n.Color:ToHex()==myHex then
                                local nm = n:FindFirstChildWhichIsA("Model")
                                if nm and not used[nm] then hasBackup=true; break end
                            end
                        end
                    end
                    if not hasBackup then continue end
                end
                local path = yPath(a.tile, ef.tile)
                if path and #path < best.dist then
                    best = {dist=#path, model=a.model, path=path}
                end
            end
            if best.model then
                table.insert(plan, {model=best.model, path=best.path, priority=500+ef.threat})
                used[best.model] = true
                actions = actions + 1
            else
                -- No path to exposed tile — find nearest front tile instead
                local best2 = {dist=math.huge, model=nil, path=nil}
                for _, a in ipairs(idleArmies) do
                    if used[a.model] then continue end
                    if capitalTile and a.tile==capitalTile then continue end
                    if a.onFront then continue end  -- already on front
                    -- Find any front tile to move toward
                    for ftile, _ in pairs(frontSet) do
                        if ftile:FindFirstChildWhichIsA("Model") then continue end
                        local path = yPath(a.tile, ftile)
                        if path and #path < best2.dist then
                            best2 = {dist=#path, model=a.model, path=path}
                        end
                    end
                end
                if best2.model then
                    table.insert(plan, {model=best2.model, path=best2.path, priority=400})
                    used[best2.model] = true
                    actions = actions + 1
                end
            end
        end
        if strategy == "FORTIFY" then
            -- In FORTIFY: still attack dying/retreating enemies nearby
            for _, target in ipairs(enemyTargets) do
                if actions >= MAX_ACTIONS then break end
                if not (target.dying or target.retreating or target.empty) then continue end
                for _, a in ipairs(idleArmies) do
                    if used[a.model] then continue end
                    if not a.adjEnemy then continue end  -- only front armies
                    local path = yPath(a.tile, target.tile)
                    if path then
                        table.insert(plan, {model=a.model, path=path, priority=200})
                        used[a.model] = true
                        actions = actions + 1
                        break
                    end
                end
            end
            for _, p in ipairs(plan) do safeFire(MoveTroop, p.path) end
            return
        end
        -- ┌─ STEP 3: ATTACK PLANNING ────────────────────────────
        -- For each target: calculate how many armies we need
        -- Send exactly that many — no more, no less
        -- This creates coordinated simultaneous attacks

        local targetAssignments = {}  -- targetTile → {armies assigned}

        for _, target in ipairs(enemyTargets) do
            if actions >= MAX_ACTIONS then break end
            local needed = {}  -- armies assigned to this target
            local totalAssignedAtk = 0

            -- How much attack do we need?
            -- Empty tile: just 1 army
            -- Active defender: need enough to win in reasonable time
            -- Formula: win if totalAtk > effDef * 1.0 (equal = eventual win)
            local atkNeeded = target.empty and 0 or target.effDef * 0.9
            -- Find armies that can reach this target
            -- Prefer armies already adjacent (onFront + adjEnemy near target)
            local candidates = {}
            for _, a in ipairs(idleArmies) do
                if used[a.model] then continue end
                if capitalTile and a.tile==capitalTile then continue end
                -- DEFENSIVE: only attack from front
                if strategy=="DEFENSIVE" and not a.onFront then continue end
                local path = yPath(a.tile, target.tile)
                if not path then continue end

                local pathLen = #path
                -- Prefer adjacent armies (path length 1-2)
                local adjacency_bonus = pathLen <= 2 and 100 or 0
                local score = a.atk + adjacency_bonus - pathLen * 5

                table.insert(candidates, {army=a, path=path, pathLen=pathLen, score=score})
            end

            if #candidates == 0 then continue end
            -- Sort candidates: adjacent first, then strongest
            table.sort(candidates, function(a,b) return a.score > b.score end)

            -- Assign armies until we have enough attack power
            for _, cand in ipairs(candidates) do
                if totalAssignedAtk >= atkNeeded and #needed > 0 then break end
                if used[cand.army.model] then continue end
                -- Don't overload: max 3 armies per target
                if #needed >= 3 then break end
                table.insert(needed, cand)
                totalAssignedAtk = totalAssignedAtk + cand.army.atk
                used[cand.army.model] = true
                actions = actions + 1
            end
            if #needed > 0 then
                for _, cand in ipairs(needed) do
                    table.insert(plan, {
                        model = cand.army.model,
                        path  = cand.path,
                        priority = target.sv + totalAssignedAtk
                    })
                end
                targetAssignments[target.tile] = needed
            end
        end
        -- ┌─ STEP 4: Develop remaining armies ──────────────────
        -- Any idle army not assigned yet → push toward best front target
        local frontTargets = {}
        for hex in pairs(enemyHexes) do
            local bestSV, bestTile = -1, nil
            for _, tile in ipairs(tileCache.byHex[hex] or {}) do
                local ns2 = PreviewPath.neighbours[tile]
                if not ns2 then continue end
                local adj = false
                for _, n in ipairs(ns2) do
                    if not n.Name:match("^Sea") and n.Color:ToHex()==myHex then adj=true; break end
                end
                if not adj then continue end
                local sv = tile:GetAttribute("isCapital") and 300 or 50
                if sv > bestSV then bestSV=sv; bestTile=tile end
            end
            if bestTile then table.insert(frontTargets, {tile=bestTile, sv=bestSV, hex=hex}) end
        end
        table.sort(frontTargets, function(a,b) return a.sv>b.sv end)
        for _, a in ipairs(idleArmies) do
            if actions >= MAX_ACTIONS then break end
            if used[a.model] then continue end
            if capitalTile and a.tile==capitalTile then continue end
            if prot[a.tile] and not frontSet[a.tile] then continue end
            local best = {score=-math.huge, path=nil}
            for _, ft in ipairs(frontTargets) do
                local path = yPath(a.tile, ft.tile)
                if path then
                    local sc = ft.sv - #path * 3
                    if sc > best.score then best={score=sc, path=path} end
                end
            end
            if best.path then
                table.insert(plan, {model=a.model, path=best.path, priority=10})
                used[a.model] = true
                actions = actions + 1
            end
        end
        -- ┌─ EXECUTE: All moves at once ─────────────────────────
        -- Sort by priority (highest first)
        table.sort(plan, function(a,b) return a.priority > b.priority end)
        for _, p in ipairs(plan) do
            safeFire(MoveTroop, p.path)
        end
    end
            local function buildSnapshot()
        local country=getCountry(); if not country then return nil end
        local atWar=false; local dip=country:FindFirstChild("Diplomacy"); local enemyColors={}
        if dip then local ef=dip:FindFirstChild("Enemies"); if ef then for _,e in ipairs(ef:GetChildren()) do if e.Value then atWar=true; enemyColors[e.Value:GetAttribute("color"):ToHex()]=e.Value end end end end
        local myColor=country:GetAttribute("color"); local myHex=myColor and myColor:ToHex() or ""
        local myUnits,enemyUnits,frontTiles={},{},{}
        for _,tile in ipairs(Map:GetChildren()) do
            if tile.Name:match("^Sea") then continue end
            local tHex=tile.Color:ToHex(); local model=tile:FindFirstChildWhichIsA("Model")
            if model then
                local mHex=(model:GetAttribute("color") and model:GetAttribute("color"):ToHex()) or ""
                local tn=model:GetAttribute("troopName") or ""; local cls=tn:find("Tank") and "Tanks" or tn:find("Anti") and "AntiTank" or "Infantry"
                local u={tile=tile,model=model,health=numAttr(model,"health"),attack=numAttr(model,"attack"),defense=numAttr(model,"defense"),state=model:GetAttribute("state"),class=cls}
                if mHex==myHex then table.insert(myUnits,u) elseif enemyColors[tHex] then table.insert(enemyUnits,u) end
            end
            if tHex==myHex then local ns=PreviewPath.neighbours[tile]; if ns then for _, n in pairs(ns) do if not n.Name:match("^Sea") and enemyColors[n.Color:ToHex()] then frontTiles[tile]=true; break end end end end
        end
        return {atWar=atWar,country=country,myColorHex=myHex,myColor=myColor,enemyColors=enemyColors,economy={money=numAttr(country,"money"),manpower=numAttr(country,"manpower")},myUnits=myUnits,enemyUnits=enemyUnits,frontTiles=frontTiles}
    end
    local lastFacAt=0
    local function autoFactoryTick(snap)
        if os.clock()-lastFacAt<10 then return end
        local c=snap.country; local money=snap.economy.money; local manpower=snap.economy.manpower
        local citiesF=c:FindFirstChild("Cities"); if not citiesF then return end
        local techs=c:FindFirstChild("Techs"); local mpCost=numAttr(techs,"factoryManpowerPrice",100); local reserve=snap.atWar and 25000 or 6000
        local ecoF=c:FindFirstChild("Economy"); local cgIncome=numAttr(ecoF,"consumerGoodsTaxIncome")
        local prodF=c:FindFirstChild("ProductionItems"); local cgIt=prodF and prodF:FindFirstChild("Consumer Goods")
        local marginal=cgIncome*math.max(cgIt and numAttr(cgIt,"factoriesValue") or 0.3,0.05)
        local bestCity,bestCost=nil,math.huge
        for _,city in ipairs(citiesF:GetChildren()) do
            local maxFac=numAttr(city,"maxFactories"); if maxFac<=0 then continue end
            if numAttr(city,"factories")>=maxFac or city:GetAttribute("factoryBuildStart") then continue end
            local tile=Map:FindFirstChild(tostring(city:GetAttribute("tileName")))
            if tile and snap.frontTiles[tile] then continue end
            local cost=numAttr(techs,"factoryPrice",1000)*(1+numAttr(city,"factories")*numAttr(techs,"factoryPriceMultiplier",0.25)+numAttr(c,"factories")*numAttr(techs,"factoryTotalPriceMultiplier",0.1))
            if cost<bestCost then bestCost=cost; bestCity=city end
        end
        if not bestCity or money-bestCost<reserve or manpower-mpCost<10000 then return end
        if bestCost/math.max(marginal,0.01)>150 and money-bestCost<reserve*2 then return end
        safeFire(PurchaseFactory,bestCity); lastFacAt=os.clock()
    end
    local SUPPLY_P={"Infantry Equipment","Anti-Tank","Tank Parts","Fuel"}
    local SUP_CLS={Infantry="Infantry Equipment",AntiTank="Anti-Tank",Tanks="Tank Parts"}
    local sliderSt,refillM={},{}
    local function applySlider(item,target)
        local name=item.Name; local now=os.clock(); local ss=sliderSt[name]
        if not ss then ss={lastAt=0,votes=0,lastDir=0}; sliderSt[name]=ss end
        local delta=target-numAttr(item,"factoriesValue")
        if math.abs(delta)<0.02 then if ss.votes>0 then ss.votes = votes - 1 end; return end
        local dir=delta>0 and 1 or -1; if dir~=ss.lastDir then ss.votes=1; ss.lastDir=dir else ss.votes = votes + 1 end
        if ss.votes>=3 and now-ss.lastAt>=8 then safeFire(SetProductionPct,item,math.clamp(target,0,1)); ss.lastAt=now; ss.votes=0 end
    end
    local function autoProductionTick(snap)
        local c=snap.country; local prodF=c:FindFirstChild("ProductionItems"); if not prodF then return end
        local items={}; for _,it in ipairs(prodF:GetChildren()) do items[it.Name]=it end
        if not snap.atWar then
            local unman=0; for name, it in pairs(items) do if name~="Consumer Goods" and not table.find(SUPPLY_P,name) then unman = unman + numAttr(it,"factoriesValue") end end
            for _, name in pairs(SUPPLY_P) do if items[name] then applySlider(items[name],0) end end
            if items["Consumer Goods"] then applySlider(items["Consumer Goods"],math.clamp(1-unman,0,1)) end; return
        end
        local classes={}; for _, u in pairs(snap.myUnits) do if u.class then classes[u.class]=true end end
        local armyF=c:FindFirstChild("Army"); local clsF=armyF and armyF:FindFirstChild("Classes")
        if clsF then for _,cl in ipairs(clsF:GetChildren()) do if numAttr(cl,"target")>0 then classes[cl.Name]=true end end end
        local desired,supTotal={},0
        for _, name in pairs(SUPPLY_P) do
            local it=items[name]; if not it then continue end
            local wanted=name=="Fuel" and classes.Tanks==true or false
            if not wanted then for cls, sup in pairs(SUP_CLS) do if sup==name and classes[cls] then wanted=true end end end
            local stock=numAttr(it,"stock"); local maxSt=numAttr(it,"maxStock",20); local cons=numAttr(it,"consumption")
            local refilling=refillM[name]
            if refilling then if stock>=maxSt*0.95 then refillM[name]=false; refilling=false end elseif stock<maxSt*0.7 then refillM[name]=true; refilling=true end
            local target=0
            if wanted and refilling then local curSh=numAttr(it,"factoriesValue"); local prod=numAttr(it,"production"); local need=cons*1.25+(maxSt-stock)*0.05; target=(curSh>0.005 and prod>0) and math.clamp(curSh*need/prod,0,1) or 0.08 end
            desired[name]=target; supTotal = supTotal + target
        end
        if supTotal>0.7 then local excess=supTotal-0.7; for i=#SUPPLY_P,1,-1 do local name=SUPPLY_P[i]; local s=desired[name] or 0; if excess<=0 then break end; local cut=math.min(s,excess); desired[name]=s-cut; excess = excess - cut end; supTotal=0.7 end
        local unman=0; for name, it in pairs(items) do if name~="Consumer Goods" and not table.find(SUPPLY_P,name) then unman = unman + numAttr(it,"factoriesValue") end end
        for name, share in pairs(desired) do if items[name] then applySlider(items[name],share) end end
        if items["Consumer Goods"] then applySlider(items["Consumer Goods"],math.clamp(1-supTotal-unman,0,1)) end
    end
    local ROMAN={I=1,V=5,X=10}
    local function romanToNum(s) local t,p=0,0; for i=#s,1,-1 do local v=ROMAN[s:sub(i,i)] or 0; if v<p then t = t - v else t = t + v; p=v end end; return t end
    local function baseName(n) return (n:gsub("%s+[IVX]+$","")) end
    local function tierOf(n) local r=n:match("%s([IVX]+)$"); return r and romanToNum(r) or 0 end
    local function techDone(nd) return nd:GetAttribute("progress")==1 end
    local function techInProg(nd) local p=nd:GetAttribute("progress"); return type(p)=="number" and p>0 and p<1 end
    local function prereqMet(country,techName)
        local spec=ResearchCommon.techs and ResearchCommon.techs[techName]
        if not spec or not spec.required then return true end
        for _, rn in pairs(spec.required) do
            local nd=country.Techs:FindFirstChild(rn)
            if not nd or not techDone(nd) then return false end
        end
        return true
    end
    -- ═══════════════════════════════════════════════════════
    -- SMART RESEARCH ENGINE
    -- Para durumu, savaş fazı, düşman kompozisyonu,
    -- tech sinerji zinciri, ROI analizi ile karar verir
    -- ═══════════════════════════════════════════════════════
    -- Tech kategorileri ve öncelikleri
    local TECH_CATEGORY = {
        -- Savaş techleri
        ["Infantry Equipment"]       = "infantry",
        ["Infantry Attack Equipment"]= "infantry",
        ["Infantry Armor"]           = "infantry",
        ["Support Equipment"]        = "infantry",
        ["Anti-Tank"]                = "antitank",
        ["Tank Parts"]               = "armor",
        ["Tank Turret"]              = "armor",
        ["Mechanization"]            = "armor",
        ["Fighter"]                  = "air",
        ["CAS"]                      = "air",
        ["Bomber"]                   = "air",
        ["Anti Air"]                 = "air",
        ["Destroyer"]                = "naval",
        ["Battleship"]               = "naval",
        ["Submarine"]                = "naval",
        ["Transport Ship"]           = "naval",
        ["Shipyard"]                 = "naval",
        -- Ekonomi techleri
        ["Industry"]                 = "economy",
        ["Underground Industry"]     = "economy",
        ["Housing"]                  = "economy",
        ["Fortifications"]           = "defense",
        -- Özel
        ["Intelligence"]             = "intel",
        ["Ballistic Missiles"]       = "missile",
        ["Uranium Mining"]           = "nuke",
        ["Uranium Enrichment"]       = "nuke",
        ["Nuke"]                     = "nuke",
        ["Nuclear Protection"]       = "nuke",
    }
    local function getTechCategory(techName)
        local base = baseName(techName)
        return TECH_CATEGORY[base] or "other"
    end

    -- ROI: Bu tech'in getirisi ne kadar?
    -- Düşük tier + düşük fiyat + yüksek etki = yüksek ROI
    local function calcROI(nd, price, tier, category, snap, money)
        local roi = 0

        -- Temel: düşük fiyat = yüksek ROI (daha fazla tech alabiliriz)
        roi = roi + math.max(0, 500 - price) * 0.1
        -- Tier: düşük tier önce (sinerji zinciri için)
        roi = roi + (4 - math.min(tier, 4)) * 40
        -- Savaş fazı bonusları
        if snap.atWar then
            -- Aktif savaşta: askeri tech çok değerli
            if category == "infantry" then roi = roi + 120 end
            if category == "antitank" then
                -- Düşmanda tank varsa anti-tank kritik
                local tankRatio = snap.enemyUnits and
                    (function()
                        local t, tot = 0, 0
                        for _, u in pairs(snap.enemyUnits) do
                            tot = tot + 1
                            if u.class == "Tanks" then t = t + 1 end
                        end
                        return tot > 0 and t/tot or 0
                    end)() or 0
                roi = roi + tankRatio * 200
            end
            if category == "armor" then
                local infRatio = snap.enemyUnits and
                    (function()
                        local t, tot = 0, 0
                        for _, u in pairs(snap.enemyUnits) do
                            tot = tot + 1
                            if u.class == "Infantry" then t = t + 1 end
                        end
                        return tot > 0 and t/tot or 0
                    end)() or 0
                roi = roi + infRatio * 150
            end
            if category == "air"     then roi = roi + 80  end
            if category == "defense" then roi = roi + 60  end
            if category == "economy" then roi = roi + 20  end -- savaşta ekonomi az öncelik
        else
            -- Barışta: ekonomi ve altyapı önce
            if category == "economy" then roi = roi + 180 end
            if category == "defense" then roi = roi + 100 end
            if category == "infantry" then roi = roi + 60 end
            if category == "intel"   then roi = roi + 70  end
        end
        -- Preset bonusu
        for _, sel in pairs(State.ResearchBases) do
            local selBase = baseName(sel)
            local ndBase  = baseName(nd.Name)
            if selBase == ndBase then roi = roi + 800 end
        end
        -- Para durumuna göre: az para = ucuz tech önce
        local moneyRatio = money / math.max(price, 1)
        if moneyRatio < 3 then
            -- Az para: en ucuz tech'i al, hızlıca araştır
            roi = roi + math.max(0, 300 - price) * 0.3
        elseif moneyRatio > 10 then
            -- Çok para: yüksek tier ve değerli tech'leri al
            roi = roi + tier * 30
        end
        -- Sinerji: bu tech başka bir tech'in prereq'u mu?
        -- prereq'u olan tech: araştırılınca daha fazla kapı açılır
        if ResearchCommon.techs then
            local opensDoors = 0
            for tName, tSpec in pairs(ResearchCommon.techs) do
                if tSpec.required then
                    for _, req in ipairs(tSpec.required) do
                        if req == nd.Name then
                            opensDoors = opensDoors + 1
                            break
                        end
                    end
                end
            end
            roi = roi + opensDoors * 25 -- her kapı açılan tech +25
        end
        -- Speed: research hız tech'leri varsa daha hızlı biter
        local techsF = snap.country:FindFirstChild("Techs")
        local resSpeed = techsF and techsF:GetAttribute("researchSpeedMultiplier") or 1
        roi = roi * resSpeed -- araştırma hızı yüksekse tüm tech'ler daha değerli

        return roi
    end
    -- Para yönetimi: ne kadar harcayabiliriz?
    local function calcBudget(money, snap)
        local atWar = snap.atWar
        -- Savaşta: ordu bakımı için reserve
        -- Barışta: fabrika inşası için reserve
        local reserve = atWar and 30000 or 15000
        -- Çok fazla para varsa daha agresif harca
        if money > 200000 then reserve = reserve * 0.5 end
        local available = math.max(0, money - reserve)
        -- Max tek seferde paranın %60'ını harca
        return math.min(available, money * 0.6)
    end
    local lastResBuyAt = 0
    local function autoResearchTick(snap)
        local c = snap.country
        local techsF = c:FindFirstChild("Techs")
        if not techsF then return end

        local money = snap.economy.money
        -- Slot durumu
        local free, slotted = 0, {}
        local slotsF = c:FindFirstChild("ResearchSlots")
        if slotsF then
            for _, sl in ipairs(slotsF:GetChildren()) do
                if sl:IsA("ObjectValue") then
                    if sl.Value == nil then free = free + 1
                    else slotted[sl.Value] = true end
                end
            end
        end

        if free <= 0 then return end
        -- Önce: satın alınmış ama araştırılmamış tech'leri başlat (ücretsiz)
        for _, nd in ipairs(techsF:GetChildren()) do
            if free <= 0 then break end
            if nd:GetAttribute("purchased") == true and
               not techDone(nd) and not techInProg(nd) and not slotted[nd] then
                safeFire(StartResearch, nd)
                free = free - 1
                slotted[nd] = true
                print("[RES] Starting purchased:", nd.Name)
            end
        end
        if free <= 0 then return end

        -- Cooldown: çok hızlı satın alma engeli
        if os.clock() - lastResBuyAt < 8 then return end

        -- Budget hesapla
        local budget = calcBudget(money, snap)
        if budget <= 0 then return end

        -- Araştırılabilir tech'leri topla (prereq karşılanmış, yapılmamış)
        local candidates = {}
        local bestPerBase = {}
        for _, nd in ipairs(techsF:GetChildren()) do
            if techDone(nd) or techInProg(nd) or slotted[nd] then continue end
            if nd:GetAttribute("purchased") == true then continue end
            if not prereqMet(c, nd.Name) then continue end

            local price = nd:GetAttribute("price") or math.huge
            if price > budget then continue end -- parası yok
            local tier     = tierOf(nd.Name)
            local base     = baseName(nd.Name)
            local category = getTechCategory(nd.Name)
            local roi      = calcROI(nd, price, tier, category, snap, money)
            -- Her base'den en iyi tier'ı seç (önce düşük tier — sinerji)
            local cur = bestPerBase[base]
            if not cur or tier < cur.tier or (tier == cur.tier and roi > cur.roi) then
                bestPerBase[base] = {
                    node     = nd,
                    tier     = tier,
                    price    = price,
                    roi      = roi,
                    base     = base,
                    category = category,
                }
            end
        end
        -- Kandidatları ROI'ya göre sırala
        for _, e in pairs(bestPerBase) do
            table.insert(candidates, e)
        end
        table.sort(candidates, function(a, b)
            if math.abs(a.roi - b.roi) > 50 then return a.roi > b.roi end
            if a.tier ~= b.tier then return a.tier < b.tier end
            return a.price < b.price
        end)

        if #candidates == 0 then return end
        -- En iyi tech'leri al (budget dolana kadar)
        local spent = 0
        for _, cand in ipairs(candidates) do
            if free <= 0 then break end
            if spent + cand.price > budget then continue end

            local paid = safeInvoke(TryPurchaseTech, cand.node)
            if not paid then continue end
            safeFire(StartResearch, cand.node)
            spent   = spent + cand.price
            free    = free - 1
            slotted[cand.node] = true
            lastResBuyAt = os.clock()

            print(("[RES] Bought: %s (T%d) $%d ROI:%.0f"):format(
                cand.node.Name, cand.tier, cand.price, cand.roi))
        end
    end
    local WAR_KW={"attack","fighter","bomber","tank","fleet","naval","military","draft","uranium","atomic","defense","missile","artillery","infantry","armor","combat","war","blitz"}
    local ECO_KW={"factory","productivity","research speed","cost","industry","economy","trade","housing","mobilization","output","civil"}
    local function classifyFocus(f)
        local text=string.lower(f.Name); local lines=decodeJ(f:GetAttribute("effectLines")); if lines then for _, l in pairs(lines) do text..=" "..string.lower(l) end end
        local tt=f:GetAttribute("tooltipDescription"); if tt then text..=" "..string.lower(tt) end
        local ws,es=0,0; for _, kw in pairs(WAR_KW) do if text:find(kw,1,true) then ws = ws + 1 end end; for _, kw in pairs(ECO_KW) do if text:find(kw,1,true) then es = es + 1 end end
        if ws>es then return "War" elseif es>ws then return "Economy" end; return "Neutral"
    end
    local function autoGovernmentTick(snap)
        local c=snap.country; local gov=c:FindFirstChild("Government"); if not gov then return end
        local focuses=gov:FindFirstChild("Focuses"); if not focuses then return end
        local current=decodeJ(gov:GetAttribute("currentFocuses")) or {}; local eligible={}
        for _,f in ipairs(focuses:GetChildren()) do
            if f:GetAttribute("progress")~=1 and not table.find(current,f.Name) then
                local req=decodeJ(f:GetAttribute("required")) or {}; local ok=true
                for _, rn in pairs(req) do local rf=focuses:FindFirstChild(rn); if not rf or rf:GetAttribute("progress")~=1 then ok=false; break end end
                if ok then table.insert(eligible,f) end
            end
        end
        if #eligible==0 then return end
        local wantCat=State.GovernmentMode=="Economy" and "Economy" or "War"; local rank={Neutral=2}; rank[wantCat]=1
        table.sort(eligible,function(a,b) local ra=rank[classifyFocus(a)] or 3; local rb=rank[classifyFocus(b)] or 3; if ra~=rb then return ra<rb end; return numAttr(a,"ppCost")<numAttr(b,"ppCost") end)
        safeInvoke(TryStartFocus,eligible[1])
    end
    local function autoArmyTick(snap)
        local c=snap.country; local army=c:FindFirstChild("Army"); if not army then return end
        local clsF=army:FindFirstChild("Classes"); if not clsF then return end
        local target=State.ArmySpawnFocus=="Tank" and "Tanks" or "Infantry"
        for _,cl in ipairs(clsF:GetChildren()) do if cl.Name==target then safeInvoke(TryIncreaseTarget,cl) end end
    end
    -- Active tactical thread'leri track et -- toggle kapanınca hepsini kill et
    local activeTacticalThreads = {}
    local function cancelTacticalThreads()
        for _, thread in ipairs(activeTacticalThreads) do
            pcall(task.cancel, thread)
        end
        activeTacticalThreads = {}
    end
    task.spawn(function()
        local tacticalRunning = false
        while true do
            if State.SmartMovement then
                -- Mutex: bir önceki tick bitmeden yenisi başlasın
                if not tacticalRunning then
                    local co2 = LocalPlayer:FindFirstChild("Country")
                    if co2 and co2.Value then
                        tacticalRunning = true
                        local thread = task.spawn(function()
                            pcall(tacticalTickAsync, co2.Value)
                            tacticalRunning = false
                        end)
                        table.insert(activeTacticalThreads, thread)
                    end
                end
                -- Biten thread'leri temizle
                local alive = {}
                for _, t in ipairs(activeTacticalThreads) do
                    if coroutine.status(t) ~= "dead" then
                        table.insert(alive, t)
                    end
                end
                activeTacticalThreads = alive
            else
                tacticalRunning = false
                if #activeTacticalThreads > 0 then
                    cancelTacticalThreads()
                end
            end
            task.wait(4)  -- 2s → 4s: daha az çakışma
        end
    end)
    local lastNatAt = 0
    task.spawn(function()
        while true do
            if os.clock() - lastNatAt >= 3 then -- 5→3 saniye
                lastNatAt = os.clock()
                local ok, snap = pcall(buildSnapshot)
                if ok and snap then
                    latestSnapshot = snap
                    if State.AutoFactory    then pcall(autoFactoryTick,    snap) end
                    if State.AutoProduction then pcall(autoProductionTick,  snap) end
                    if State.AutoGovernment then pcall(autoGovernmentTick,  snap) end
                    if State.AutoArmy       then pcall(autoArmyTick,        snap) end
                    if State.AutoResearch   then pcall(autoResearchTick,    snap) end
                    if State.AutoDiplomacy  then pcall(autoRealDipTick,     snap) end
                    if State.AutoMissile    then pcall(autoMissileTick,     snap) end
                    if State.AutoSilo       then pcall(autoSiloTick,        snap) end
                    if State.AutoNaval      then pcall(autoNavalTick,       snap) end
                    if State.AutoPlanes     then pcall(autoPlanesTick,      snap) end
                end
            end
            task.wait(1)
        end
    end)
    -- Black-and-gold native Roblox menu.
    local gold = Color3.fromRGB(211, 175, 87)
    local black = Color3.fromRGB(12, 12, 13)
    local panel = Color3.fromRGB(23, 23, 24)
    local ink = Color3.fromRGB(241, 234, 216)
    local muted = Color3.fromRGB(160, 153, 135)
    local function make(class, props, parent)
        local obj = Instance.new(class)
        for k, v in pairs(props) do obj[k] = v end
        obj.Parent = parent
        return obj
    end
    local function round(obj, radius)
        make("UICorner", {CornerRadius = UDim.new(0, radius)}, obj)
    end
    local function text(parent, value, size, color)
        return make("TextLabel", {Text = value, BackgroundTransparency = 1, TextWrapped = true,
            TextSize = size, Font = Enum.Font.Gotham, TextColor3 = color,
            TextXAlignment = Enum.TextXAlignment.Left}, parent)
    end
    local old = CoreGui:FindFirstChild("AmirkingGoldUI")
    if old then old:Destroy() end
    local gui = make("ScreenGui", {Name = "AmirkingGoldUI", ResetOnSpawn = false,
        DisplayOrder = 9000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling}, CoreGui)
    local root = make("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(720, 470), BackgroundColor3 = black, BorderSizePixel = 0,
        ClipsDescendants = true}, gui)
    round(root, 16)
    make("UIStroke", {Color = gold, Thickness = 1, Transparency = 0.25}, root)
    local scale = make("UIScale", {Scale = 1}, root)
    local function fit()
        local v = gui.AbsoluteSize
        scale.Scale = math.min(1, math.max(0.1, math.min((v.X - 24) / 720, (v.Y - 24) / 470)))
        root.Position = UDim2.fromScale(0.5, 0.5)
    end
    fit(); gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    local top = make("Frame", {Size = UDim2.new(1, 0, 0, 72), BackgroundColor3 = panel,
        BorderSizePixel = 0, Active = true}, root)
    local logo = text(top, "AK", 26, gold)
    logo.Position = UDim2.fromOffset(22, 17); logo.Size = UDim2.fromOffset(50, 36); logo.Font = Enum.Font.GothamBold
    local title = text(top, "AMIRKING HUB", 20, ink)
    title.Position = UDim2.fromOffset(85, 14); title.Size = UDim2.fromOffset(450, 27); title.Font = Enum.Font.GothamBold
    local sub = text(top, "УПРАВЛЕНИЕ И АВТОМАТИЗАЦИЯ", 10, gold)
    sub.Position = UDim2.fromOffset(85, 43); sub.Size = UDim2.fromOffset(450, 18)
    make("Frame", {BackgroundColor3 = gold, BackgroundTransparency = 0.65, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 71), Size = UDim2.new(1, 0, 0, 1)}, top)
    local close = make("TextButton", {Text = "×", TextSize = 28, TextColor3 = gold,
        BackgroundTransparency = 1, Position = UDim2.new(1, -52, 0, 15), Size = UDim2.fromOffset(36, 36)}, top)
    close.Activated:Connect(function() root.Visible = false end)
    local sidebar = make("ScrollingFrame", {BackgroundTransparency = 1, BorderSizePixel = 0,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 2, ScrollBarImageColor3 = gold, Position = UDim2.fromOffset(14, 88),
        Size = UDim2.new(0, 164, 1, -136)}, root)
    make("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, sidebar)
    local foot = text(root, "AK  /  ЧЁРНОЕ ЗОЛОТО", 10, muted)
    foot.Position = UDim2.new(0, 22, 1, -30); foot.Size = UDim2.fromOffset(170, 16)
    local Rayfield = {}
    local tabs = {}
    function Rayfield:IsVisible() return root.Visible end
    function Rayfield:SetVisibility(v) root.Visible = v == true end
    function Rayfield:CreateWindow(_) return self end
    function Rayfield:Notify(config)
        local toast = make("Frame", {AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -12),
            Size = UDim2.new(0.8, 0, 0, 94), BackgroundColor3 = panel, BorderSizePixel = 0}, gui)
        make("UISizeConstraint", {MaxSize = Vector2.new(390, 94)}, toast)
        round(toast, 12); make("UIStroke", {Color = gold, Transparency = 0.4}, toast)
        local h = text(toast, config.Title or "amirking hub", 13, gold)
        h.Position = UDim2.fromOffset(14, 8); h.Size = UDim2.new(1, -28, 0, 24)
        local b = text(toast, config.Content or "", 12, ink)
        b.Position = UDim2.fromOffset(14, 34); b.Size = UDim2.new(1, -28, 0, 48)
        task.delay(config.Duration or 4, function() toast:Destroy() end)
    end
    local function invoke(fn, v)
        if fn then local ok, err = pcall(fn, v); if not ok then warn("[amirking hub] " .. tostring(err)) end end
    end
    function Rayfield:CreateTab(name, _)
        local page = make("ScrollingFrame", {Name = name, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = UDim2.fromOffset(194, 88), Size = UDim2.new(1, -210, 1, -106),
            CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 3, ScrollBarImageColor3 = gold, Visible = false}, root)
        make("UIPadding", {PaddingRight = UDim.new(0, 9), PaddingBottom = UDim.new(0, 14)}, page)
        make("UIListLayout", {Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder}, page)
        local nav = make("TextButton", {Text = name, TextSize = 13, Font = Enum.Font.GothamMedium,
            TextColor3 = muted, BackgroundColor3 = black, BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 44), LayoutOrder = #tabs + 1}, sidebar)
        round(nav, 9)
        local tab = {page = page, nav = nav, order = 0}
        table.insert(tabs, tab)
        local function selectTab()
            for _, t in ipairs(tabs) do
                t.page.Visible = t == tab
                t.nav.TextColor3 = t == tab and gold or muted
                t.nav.BackgroundColor3 = t == tab and Color3.fromRGB(47, 41, 26) or black
            end
        end
        nav.Activated:Connect(selectTab)
        if #tabs == 1 then selectTab() end
        local function row(height)
            tab.order = tab.order + 1
            local f = make("Frame", {Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = panel,
                BorderSizePixel = 0, LayoutOrder = tab.order}, page)
            round(f, 10); return f
        end
        function tab:CreateSection(value)
            local f = row(30); f.BackgroundTransparency = 1
            local l = text(f, value, 12, gold); l.Font = Enum.Font.GothamBold; l.Size = UDim2.fromScale(1, 1)
        end
        function tab:CreateLabel(value)
            local f = row(0); f.AutomaticSize = Enum.AutomaticSize.Y
            make("UIPadding", {PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
                PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14)}, f)
            local l = text(f, value, 11, muted)
            l.Size = UDim2.new(1, 0, 0, 0); l.AutomaticSize = Enum.AutomaticSize.Y
            return {Set = function(_, value) l.Text = tostring(value) end}
        end
        function tab:CreateToggle(config)
            local f = row(58)
            local l = text(f, config.Name, 13, ink)
            l.Position = UDim2.fromOffset(15, 0); l.Size = UDim2.new(1, -94, 1, 0)
            local track = make("Frame", {Position = UDim2.new(1, -66, 0.5, -13),
                Size = UDim2.fromOffset(48, 26), BorderSizePixel = 0}, f); round(track, 13)
            local knob = make("Frame", {Size = UDim2.fromOffset(18, 18), BorderSizePixel = 0}, track); round(knob, 9)
            local hit = make("TextButton", {Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1)}, f)
            local value = config.CurrentValue == true
            local function paint()
                local info = TweenInfo.new(0.16)
                TweenService:Create(track, info, {BackgroundColor3 = value and gold or Color3.fromRGB(65, 63, 57)}):Play()
                TweenService:Create(knob, info, {Position = UDim2.fromOffset(value and 26 or 4, 4),
                    BackgroundColor3 = value and black or Color3.fromRGB(190, 184, 170)}):Play()
            end
            paint()
            hit.Activated:Connect(function() value = not value; paint(); invoke(config.Callback, value) end)
        end
        function tab:CreateDropdown(config)
            local f = row(0); f.AutomaticSize = Enum.AutomaticSize.Y
            make("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, f)
            local header = make("TextButton", {Text = "", BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, 66), LayoutOrder = 0}, f)
            local h = text(header, config.Name, 11, muted)
            h.Position = UDim2.fromOffset(15, 8); h.Size = UDim2.new(1, -30, 0, 20)
            local selected = config.CurrentOption and config.CurrentOption[1] or config.Options[1]
            local v = text(header, selected .. "  ▾", 13, gold)
            v.Position = UDim2.fromOffset(15, 30); v.Size = UDim2.new(1, -30, 0, 25)
            local options, opened = {}, false
            local function show(state)
                opened = state; for _, opt in ipairs(options) do opt.Visible = state end
            end
            for i, option in ipairs(config.Options) do
                local choice = option
                local b = make("TextButton", {Text = choice, TextSize = 12, Font = Enum.Font.Gotham,
                    TextColor3 = ink, BackgroundColor3 = Color3.fromRGB(32, 31, 27), BorderSizePixel = 0,
                    Size = UDim2.new(1, 0, 0, 36), LayoutOrder = i, Visible = false}, f)
                table.insert(options, b)
                b.Activated:Connect(function() v.Text = choice .. "  ▾"; show(false); invoke(config.Callback, {choice}) end)
            end
            header.Activated:Connect(function() show(not opened) end)
        end
        return tab
    end

    local Window = Rayfield:CreateWindow()

    local StatusTab = Window:CreateTab("Статус", 0)
    StatusTab:CreateSection("Состояние страны")
    local statusCountry = StatusTab:CreateLabel("Страна: ожидание данных…")
    local statusWar = StatusTab:CreateLabel("Война: —")
    local statusMoney = StatusTab:CreateLabel("Деньги: —")
    local statusManpower = StatusTab:CreateLabel("Людские ресурсы: —")
    local statusArmy = StatusTab:CreateLabel("Армия: —")
    StatusTab:CreateSection("Активные функции")
    local statusFeatures = StatusTab:CreateLabel("Нет включённых функций")
    local featureNames = {
        {"AutoFactory", "Строительство заводов"},
        {"AutoProduction", "Распределение производства"},
        {"AutoGovernment", "Государственные фокусы"},
        {"AutoArmy", "Набор войск"},
        {"SmartMovement", "Управление войсками"},
        {"AutoDiplomacy", "Дипломатия"},
        {"AutoMissile", "Запуск ракет"},
        {"AutoNaval", "Морской десант"},
        {"AutoPlanes", "Развёртывание авиации"},
        {"AutoSilo", "Строительство шахт"},
        {"AutoResearch", "Исследования"},
    }
    task.spawn(function()
        while gui.Parent do
            if StatusTab.page.Visible and root.Visible then
                local country = getCountry()
                local snap = latestSnapshot
                if country and snap and snap.country == country then
                    statusCountry:Set("Страна: " .. country.Name)
                    local enemies = {}
                    for _, enemy in pairs(snap.enemyColors) do table.insert(enemies, enemy.Name) end
                    table.sort(enemies)
                    statusWar:Set(snap.atWar and ("Война: да\nПротивники: " .. table.concat(enemies, ", ")) or "Война: нет")
                    statusMoney:Set(string.format("Деньги: %.0f", snap.economy.money))
                    statusManpower:Set(string.format("Людские ресурсы: %.0f", snap.economy.manpower))
                    local infantry, tanks, anti = 0, 0, 0
                    for _, unit in ipairs(snap.myUnits) do
                        if unit.class == "Tanks" then tanks = tanks + 1
                        elseif unit.class == "AntiTank" then anti = anti + 1
                        else infantry = infantry + 1 end
                    end
                    statusArmy:Set(string.format("Войск: %d\nПехота: %d · Танки: %d · ПТО: %d", #snap.myUnits, infantry, tanks, anti))
                else
                    statusCountry:Set(country and ("Страна: " .. country.Name .. " · ожидание данных…") or "Страна не выбрана")
                    statusWar:Set("Война: —"); statusMoney:Set("Деньги: —")
                    statusManpower:Set("Людские ресурсы: —"); statusArmy:Set("Армия: —")
                end
                local enabled = {}
                for _, feature in ipairs(featureNames) do
                    if State[feature[1]] then table.insert(enabled, "● " .. feature[2]) end
                end
                statusFeatures:Set(#enabled > 0 and table.concat(enabled, "\n") or "Нет включённых функций")
            end
            task.wait(2)
        end
    end)

    -- Floating menu button, independent of the Rayfield window.
    local UserInputService = game:GetService("UserInputService")
    local oldButton = CoreGui:FindFirstChild("AmirkingMenuButton")
    if oldButton then oldButton:Destroy() end

    local buttonGui = Instance.new("ScreenGui")
    buttonGui.Name = "AmirkingMenuButton"
    buttonGui.ResetOnSpawn = false
    buttonGui.DisplayOrder = 10000
    buttonGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    buttonGui.Parent = CoreGui

    local menuButton = Instance.new("TextButton")
    menuButton.Name = "ToggleMenu"
    menuButton.Size = UDim2.fromOffset(58, 58)
    menuButton.Position = UDim2.new(0, 18, 0.5, -29)
    menuButton.BackgroundColor3 = Color3.fromRGB(17, 16, 13)
    menuButton.Text = "AK"
    menuButton.TextColor3 = Color3.fromRGB(240, 218, 160)
    menuButton.TextSize = 23
    menuButton.Font = Enum.Font.GothamBold
    menuButton.AutoButtonColor = true
    menuButton.Active = true
    menuButton.Parent = buttonGui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = menuButton
    local border = Instance.new("UIStroke")
    border.Color = Color3.fromRGB(211, 175, 87)
    border.Thickness = 2
    border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    border.Parent = menuButton

    local dragging = false
    local moved = false
    local dragInput, dragStart, startPosition
    local function clampButton(x, y)
        local size = buttonGui.AbsoluteSize
        return math.clamp(x, 0, math.max(0, size.X - 58)),
               math.clamp(y, 0, math.max(0, size.Y - 58))
    end
    menuButton.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if dragging then return end
        dragging = true
        moved = false
        dragInput = input
        dragStart = input.Position
        startPosition = menuButton.AbsolutePosition - buttonGui.AbsolutePosition
    end)
    local inputChanged = UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        local touch = dragInput.UserInputType == Enum.UserInputType.Touch
        if touch and input ~= dragInput then return end
        if not touch and input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local delta = input.Position - dragStart
        if delta.Magnitude > 8 then moved = true end
        if moved then
            local x, y = clampButton(startPosition.X + delta.X, startPosition.Y + delta.Y)
            menuButton.Position = UDim2.fromOffset(x, y)
        end
    end)
    local inputEnded = UserInputService.InputEnded:Connect(function(input)
        if not dragging or input ~= dragInput then return end
        dragging = false
        if moved then return end
        if type(Rayfield.SetVisibility) ~= "function" or type(Rayfield.IsVisible) ~= "function" then
            warn("[amirking hub] Библиотека меню не поддерживает переключение видимости")
            return
        end
        Rayfield:SetVisibility(not Rayfield:IsVisible())
    end)
    buttonGui.Destroying:Connect(function()
        inputChanged:Disconnect()
        inputEnded:Disconnect()
    end)

    local AutoTab = Window:CreateTab("Экономика", 0)
    AutoTab:CreateToggle({ Name = "Автостроительство заводов",      CurrentValue = false, Flag = "AutoFactory",  Callback = function(v) State.AutoFactory    = v end })
    AutoTab:CreateToggle({ Name = "Автораспределение производства", CurrentValue = false, Flag = "AutoProd",     Callback = function(v) State.AutoProduction  = v end })
    AutoTab:CreateSection("Правительство")
    AutoTab:CreateDropdown({ Name = "Приоритет правительства", Options = { "Военный", "Экономический" }, CurrentOption = { "Военный" }, MultipleOptions = false, Flag = "GovMode",
        Callback = function(opts) State.GovernmentMode = (opts[1] == "Экономический") and "Economy" or "War" end })
    AutoTab:CreateToggle({ Name = "Автовыбор государственных фокусов",   CurrentValue = false, Flag = "AutoGov",      Callback = function(v) State.AutoGovernment  = v end })
    AutoTab = Window:CreateTab("Армия", 0)
    AutoTab:CreateSection("Армия")
    AutoTab:CreateDropdown({ Name = "Тип набираемых войск", Options = { "Пехота", "Танки" }, CurrentOption = { "Пехота" }, MultipleOptions = false, Flag = "ArmySpawn",
        Callback = function(opts) State.ArmySpawnFocus = (opts[1] == "Танки") and "Tank" or "Infantry" end })
    AutoTab:CreateToggle({ Name = "Автонабор войск",         CurrentValue = false, Flag = "AutoArmy",     Callback = function(v) State.AutoArmy        = v end })
    AutoTab:CreateSection("Тактика")
    AutoTab:CreateToggle({ Name = "Умное управление войсками", CurrentValue = false, Flag = "SmartMove", Callback = function(v)
        State.SmartMovement = v
        if not v then cancelTacticalThreads() end
    end })
    AutoTab:CreateLabel("Оценка боя по здоровью · Захват пустых клеток · Совместные атаки · Защита столицы · До 30 действий за цикл")
    -- ═══ AIR FORCE SECTION ════════════════════════════════════
    AutoTab = Window:CreateTab("Дипломатия", 0)
    AutoTab:CreateSection("Дипломатия")
    AutoTab:CreateToggle({
        Name = "Автодипломатия",
        CurrentValue = false,
        Flag = "AutoDip",
        Callback = function(v)
            State.AutoDiplomacy = v
            if v then dipState.justifying = {} end
            print("[DIP] Auto Diplomacy " .. (v and "enabled" or "disabled"))
        end
    })
    AutoTab:CreateLabel("Подготовка войн со слабыми соседями · Объявление войны · Предложение мира при превосходстве врага в 2,5 раза")
    AutoTab = Window:CreateTab("Вооружение", 0)
    local weaponsTab = AutoTab
    AutoTab:CreateSection("Ракеты")
    AutoTab:CreateToggle({
        Name = "Автозапуск ракет",
        CurrentValue = false,
        Flag = "AutoMissile",
        Callback = function(v)
            State.AutoMissile = v
            print("[MSL] Auto Missile Launch " .. (v and "enabled" or "disabled"))
        end
    })
    AutoTab:CreateLabel("Удары по столицам и важным целям · Нужны шахта и ракеты · Интервал 20 секунд")
    AutoTab:CreateSection("Морской десант")
    AutoTab:CreateToggle({
        Name         = "Автоматический морской десант",
        CurrentValue = false,
        Flag         = "AutoNaval",
        Callback     = function(v)
            State.AutoNaval = v
            if v then
                navalState.phase = "idle"
                navalState.usedArmies = {}
                print("[NAVAL] Auto Naval Invasion enabled")
            end
        end
    })
    AutoTab:CreateLabel("Погрузка сильной пехоты в транспорты · Нужны транспортные корабли в порту · Движение и высадка недописаны")
    AutoTab = Window:CreateTab("Авиация", 0)
    AutoTab:CreateSection("Авиация")
    AutoTab:CreateToggle({
        Name         = "Авторазвёртывание авиации",
        CurrentValue = false,
        Flag         = "AutoPlanes",
        Callback     = function(v)
            State.AutoPlanes = v
            if v then
                planeDeployed = {}
                print("[AIR] Auto Plane Deployment enabled")
            end
        end
    })
    AutoTab:CreateLabel("Отправка самолётов с аэродромов в воздушные регионы противника")
    AutoTab = weaponsTab
    AutoTab:CreateSection("Ракетные шахты")
    AutoTab:CreateToggle({
        Name         = "Автостроительство ракетных шахт",
        CurrentValue = false,
        Flag         = "AutoSilo",
        Callback     = function(v)
            State.AutoSilo = v
            print("[SILO] Auto Missile Silo Builder " .. (v and "enabled" or "disabled"))
        end
    })
    AutoTab:CreateLabel("Строительство и улучшение шахт вдали от фронта · Нужна технология баллистических ракет · Резерв 20 000")
    local ResTab = Window:CreateTab("Исследования", 0)
    ResTab:CreateToggle({ Name = "Автоисследования", CurrentValue = false, Flag = "AutoResearch", Callback = function(v) State.AutoResearch = v end })
    ResTab:CreateSection("Приоритет исследований")
    ResTab:CreateDropdown({
        Name = "Выбрать направление", Options = { "Упор на пехоту", "Упор на танки", "Упор на авиацию", "Упор на флот", "Ядерная программа" },
        CurrentOption = { "Упор на пехоту" }, MultipleOptions = false, Flag = "ResearchPreset",
        Callback = function(opts) applyPreset(opts[1]); Rayfield:Notify({ Title = "◈ Исследования ◈", Content = opts[1] .. " — выбрано направлений: " .. #State.ResearchBases .. "", Duration = 3 }) end,
    })
    ResTab:CreateSection("Информация")
    ResTab:CreateLabel("Пехота: снаряжение · Атака · Броня · ПТО · Поддержка · Укрепления · Промышленность")
    ResTab:CreateLabel("Танки: детали · Башни · Механизация · ПТО · Поддержка · Промышленность")
    ResTab:CreateLabel("Выбранные направления получают +800 к приоритету.")
    applyPreset("Упор на пехоту")
    Rayfield:Notify({ Title = "◈ amirking hub v5.3 ◈", Content = "Автоматизация: тактика · Исследования · Десант · Шахты · Авиация", Duration = 6 })
    print("amirking hub v5.3 — HP-based tactical AI + Naval + Silo + Planes.")
end

startMainScript()
