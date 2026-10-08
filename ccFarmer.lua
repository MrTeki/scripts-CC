-- ccFarmer : turtle fermière pour un champ 9x9 avec coffre central
-- Installation : source d'eau au centre du champ, coffre posé sur l'eau,
-- turtle posée au-dessus du coffre. Sa direction au premier lancement
-- devient la direction de référence (dir 0).

------------------------------------------------------------
-- Configuration
------------------------------------------------------------
local RADIUS         = 4          -- champ de (2*RADIUS+1)², 4 => 9x9
local TOUR_INTERVAL  = 20 * 60    -- secondes entre deux tournées
local FUEL_MIN       = 200        -- en dessous : recharge avant de partir
local FUEL_TARGET    = 1000       -- niveau visé lors d'une recharge
local FUEL_ALERT     = 16         -- alerte si le coffre contient moins de N items de fuel
local MIN_FREE_SLOTS = 2          -- slots libres requis avant de récolter (ex. blé + graines)
local MOVE_TRIES     = 5          -- essais avant d'afficher "bloqué"
local RETRY_DELAY    = 2          -- secondes entre deux essais / vérifications
local SAVE_FILE      = "ccfarmer.dat"
local STARTUP        = 'shell.run("ccFarmer")\n'

local args = { ... }

-- bloc => âge mature et item à replanter
local CROPS = {
  ["minecraft:wheat"]     = { age = 7, seed = "minecraft:wheat_seeds" },
  ["minecraft:carrots"]   = { age = 7, seed = "minecraft:carrot" },
  ["minecraft:potatoes"]  = { age = 7, seed = "minecraft:potato" },
  ["minecraft:beetroots"] = { age = 3, seed = "minecraft:beetroot_seeds" },
}

-- items acceptés comme fuel dans le coffre
local FUELS = {
  ["minecraft:coal"]       = true,
  ["minecraft:charcoal"]   = true,
  ["minecraft:coal_block"] = true,
}

------------------------------------------------------------
-- État
------------------------------------------------------------
-- dir : 0 = devant (+y), 1 = droite (+x), 2 = derrière (-y), 3 = gauche (-x)
local DX = { [0] = 0, 1, 0, -1 }
local DY = { [0] = 1, 0, -1, 0 }

local state = {
  x = 0, y = 0, dir = 0,
  inTour = false, idx = 1, outward = true,
  lastSeed = nil, tours = 0, stats = {},
  nextTourAt = nil,   -- os.epoch("utc") en ms ; survit aux redémarrages
}
local flags   = { paused = false, runNow = false, quit = false }
local ui      = { status = "Demarrage", alert = nil, fuelLow = false }
local buttons = {}
local QUIT    = {}   -- valeur d'erreur sentinelle pour un arrêt propre

------------------------------------------------------------
-- Sauvegarde (écriture atomique)
------------------------------------------------------------
local function save()
  local tmp = SAVE_FILE .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(textutils.serialize(state))
  f.close()
  if fs.exists(SAVE_FILE) then fs.delete(SAVE_FILE) end
  fs.move(tmp, SAVE_FILE)
end

local function load()
  for _, path in ipairs({ SAVE_FILE, SAVE_FILE .. ".tmp" }) do
    if fs.exists(path) then
      local f = fs.open(path, "r")
      local data = textutils.unserialize(f.readAll())
      f.close()
      if type(data) == "table" and type(data.x) == "number"
         and type(data.y) == "number" and type(data.dir) == "number" then
        for k, v in pairs(data) do state[k] = v end
        state.stats = state.stats or {}
        return true
      end
    end
  end
  return false
end

------------------------------------------------------------
-- Fichier de démarrage (reprise après rechargement du chunk)
------------------------------------------------------------
local function startupContent()
  if not fs.exists("startup.lua") then return nil end
  local f = fs.open("startup.lua", "r")
  local content = f.readAll()
  f.close()
  return content
end

local function installStartup()
  local current = startupContent()
  if current == STARTUP then return end
  if current then
    if not fs.exists("startup.old") then fs.move("startup.lua", "startup.old") end
    fs.delete("startup.lua")
  end
  local f = fs.open("startup.lua", "w")
  f.write(STARTUP)
  f.close()
end

local function removeStartup()
  -- On ne retire que le nôtre.
  if startupContent() == STARTUP then fs.delete("startup.lua") end
  if not fs.exists("startup.lua") and fs.exists("startup.old") then
    fs.move("startup.old", "startup.lua")
  end
end

------------------------------------------------------------
-- Utilitaires
------------------------------------------------------------
local function setStatus(text) ui.status = text end

local function fuelLevel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

-- Point de contrôle : gère la pause et l'arrêt demandé
local function checkpoint()
  while flags.paused and not flags.quit do sleep(0.5) end
  if flags.quit then error(QUIT) end
end

local function countFree()
  local n = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then n = n + 1 end
  end
  return n
end

local function freeSlot()
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then return s end
  end
end

local function findItem(name)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == name then return s end
  end
end

local function getChest()
  local c = peripheral.wrap("bottom")
  if c and c.list then return c end
end

------------------------------------------------------------
-- Parcours en spirale
------------------------------------------------------------
local function buildSpiral(radius)
  local total = (2 * radius + 1) ^ 2 - 1
  local cells = {}
  local x, y, d, len = 0, 0, 0, 1
  while true do
    for _ = 1, 2 do
      for _ = 1, len do
        x, y = x + DX[d], y + DY[d]
        cells[#cells + 1] = { x = x, y = y }
        if #cells == total then return cells end
      end
      d = (d + 1) % 4
    end
    len = len + 1
  end
end

local spiral = buildSpiral(RADIUS)

local function cellAt(i)
  if state.outward then return spiral[i] end
  return spiral[#spiral + 1 - i]
end

------------------------------------------------------------
-- Déplacements
------------------------------------------------------------
local function turnRight()
  checkpoint()
  turtle.turnRight()
  state.dir = (state.dir + 1) % 4
  save()
end

local function turnLeft()
  checkpoint()
  turtle.turnLeft()
  state.dir = (state.dir + 3) % 4
  save()
end

local function face(d)
  local diff = (d - state.dir) % 4
  if diff == 1 then turnRight()
  elseif diff == 2 then turnRight() turnRight()
  elseif diff == 3 then turnLeft() end
end

-- Avance d'une case ; ne creuse jamais, réessaie en cas d'obstacle
local function forward()
  local tries = 0
  while true do
    checkpoint()
    if turtle.forward() then
      state.x = state.x + DX[state.dir]
      state.y = state.y + DY[state.dir]
      save()
      ui.alert = nil
      return
    end
    tries = tries + 1
    if fuelLevel() == 0 then
      ui.alert = "Plus de fuel !"
    elseif tries >= MOVE_TRIES then
      ui.alert = ("Bloque en (%d,%d)"):format(state.x, state.y)
    end
    sleep(RETRY_DELAY)
  end
end

local function goTo(tx, ty)
  while state.x ~= tx do
    face(tx > state.x and 1 or 3)
    forward()
  end
  while state.y ~= ty do
    face(ty > state.y and 0 or 2)
    forward()
  end
end

------------------------------------------------------------
-- Coffre : dépôt et fuel
------------------------------------------------------------
-- Vide tout l'inventaire ; attend tant que le coffre ne peut pas tout prendre
local function deposit()
  while true do
    checkpoint()
    if not getChest() then
      setStatus("Coffre introuvable sous la turtle")
    else
      for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d then
          turtle.select(s)
          turtle.dropDown()
          local dropped = d.count - turtle.getItemCount(s)
          if dropped > 0 then
            state.stats[d.name] = (state.stats[d.name] or 0) + dropped
          end
        end
      end
      save()
      if countFree() == 16 then return end
      setStatus("Coffre plein : en attente")
    end
    sleep(RETRY_DELAY)
  end
end

local function chestFuelCount(c)
  local n = 0
  for _, it in pairs(c.list()) do
    if FUELS[it.name] then n = n + it.count end
  end
  return n
end

-- Amène un stack de fuel dans le slot 1 du coffre (suck prend dans l'ordre).
-- La turtle doit être vide : si le coffre est plein, elle garde le contenu
-- du slot 1 le temps de l'échange.
local function bringFuelToSlot1(c)
  local items = c.list()
  if items[1] and FUELS[items[1].name] then return true end
  local fuelSlot
  for s, it in pairs(items) do
    if FUELS[it.name] then fuelSlot = s break end
  end
  if not fuelSlot then return false end
  local self = peripheral.getName(c)
  local held = false
  if items[1] then
    local free
    for s = 2, c.size() do
      if not items[s] then free = s break end
    end
    if free then
      pcall(c.pushItems, self, 1, 64, free)
    else
      turtle.select(16)
      held = turtle.suckDown()
    end
  end
  local ok, moved = pcall(c.pushItems, self, fuelSlot, 64, 1)
  if held then turtle.dropDown() end   -- reprend la place libérée par le fuel
  turtle.select(1)
  return ok and moved > 0
end

-- Recharge depuis le coffre ; la turtle doit être vide (appel après deposit)
local function refuel()
  if fuelLevel() >= FUEL_MIN then return true end
  local c = getChest()
  if not c then return false end
  turtle.select(1)
  while fuelLevel() < FUEL_TARGET do
    if not bringFuelToSlot1(c) then break end
    if not turtle.suckDown(8) then break end
    while fuelLevel() < FUEL_TARGET and turtle.getItemCount(1) > 0 do
      if not turtle.refuel(1) then break end
    end
    if turtle.getItemCount(1) > 0 then
      turtle.dropDown()
      break
    end
  end
  return fuelLevel() >= FUEL_MIN
end

local function ensureFuel()
  while not refuel() do
    setStatus("Fuel insuffisant : en attente")
    for _ = 1, 5 do
      checkpoint()
      sleep(RETRY_DELAY)
    end
  end
  local c = getChest()
  if c then ui.fuelLow = chestFuelCount(c) < FUEL_ALERT end
end

------------------------------------------------------------
-- Travail d'une case
------------------------------------------------------------
-- Retourne false si la place manque pour récolter (retour au coffre nécessaire)
local function workCell()
  local ok, block = turtle.inspectDown()

  if not ok then
    -- case vide : replante la dernière graine récoltée
    if state.lastSeed then
      local s = findItem(state.lastSeed)
      if s then
        turtle.select(s)
        turtle.placeDown()
      end
    end
    return true
  end

  local crop = CROPS[block.name]
  if not crop or not block.state or (block.state.age or 0) < crop.age then
    return true   -- bloc inconnu ou culture immature : on ignore
  end

  if countFree() < MIN_FREE_SLOTS then return false end

  turtle.select(1)   -- le ramassage part du slot sélectionné : on complète les stacks existants
  if turtle.digDown() then
    state.lastSeed = crop.seed
    save()   -- un arrêt avant placeDown replantera la bonne graine
    local s = findItem(crop.seed)
    if s then
      turtle.select(s)
      turtle.placeDown()
    end
  end
  return true
end

local function returnTrip()
  local c = cellAt(state.idx)
  setStatus("Inventaire plein : retour au coffre")
  goTo(0, 0)
  deposit()
  ensureFuel()
  goTo(c.x, c.y)
end

local function runTour()
  flags.runNow = false   -- une demande faite pendant la tournée est satisfaite par celle-ci
  if not state.inTour then
    state.inTour, state.idx, state.lastSeed = true, 1, nil
    save()
  end
  while state.idx <= #spiral do
    local c = cellAt(state.idx)
    setStatus(("Tournee %d : case %d/%d"):format(state.tours + 1, state.idx, #spiral))
    goTo(c.x, c.y)
    checkpoint()
    if workCell() then
      state.idx = state.idx + 1
      save()
    else
      returnTrip()
    end
  end
  setStatus("Retour au coffre")
  goTo(0, 0)
  state.inTour = false
  state.outward = not state.outward
  state.tours = state.tours + 1
  state.nextTourAt = os.epoch("utc") + TOUR_INTERVAL * 1000
  save()
end

------------------------------------------------------------
-- Boucle principale (seule à commander la turtle)
------------------------------------------------------------
local function mainLoop()
  if state.inTour then
    runTour()        -- reprise après redémarrage
  else
    goTo(0, 0)
  end
  while true do
    deposit()
    -- Échéance sauvegardée : un redémarrage pendant l'attente ne relance pas
    -- de tournée. Sans échéance (premier lancement), on part tout de suite.
    setStatus("En attente de la prochaine tournee")
    while state.nextTourAt and os.epoch("utc") < state.nextTourAt
          and not flags.runNow do
      checkpoint()
      sleep(1)
    end
    ensureFuel()
    runTour()
  end
end

local function mainWrapper()
  local ok, err = pcall(mainLoop)
  if not ok and err ~= QUIT then error(err, 0) end
end

------------------------------------------------------------
-- Interface (ne fait que lire l'état et poser des drapeaux)
------------------------------------------------------------
local function shortName(name) return (name:gsub("^minecraft:", "")) end

local function draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  local function line(y, text, fg)
    term.setCursorPos(1, y)
    term.setTextColor(fg or colors.white)
    term.write(text:sub(1, w))
  end

  line(1, "ccFarmer", colors.lime)
  local tours = "Tournees: " .. state.tours
  term.setCursorPos(w - #tours + 1, 1)
  term.setTextColor(colors.lightGray)
  term.write(tours)

  line(2, (flags.paused and "PAUSE - " or "") .. ui.status,
       flags.paused and colors.orange or colors.white)
  local f = fuelLevel()
  line(3, "Fuel : " .. (f == math.huge and "illimite" or tostring(f)))

  local y = 4
  if ui.fuelLow then line(y, "! Reserve de fuel faible", colors.orange) y = y + 1 end
  if ui.alert then line(y, "! " .. ui.alert, colors.red) y = y + 1 end
  if state.nextTourAt and not state.inTour then
    local r = math.max(0, math.ceil((state.nextTourAt - os.epoch("utc")) / 1000))
    line(y, ("Prochaine tournee : %d:%02d"):format(math.floor(r / 60), r % 60), colors.lightGray)
    y = y + 1
  end

  y = y + 1
  line(y, "-- Recoltes deposees --", colors.yellow)
  local names = {}
  for name in pairs(state.stats) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    y = y + 1
    if y > h - 2 then break end
    local count = tostring(state.stats[name])
    line(y, shortName(name))
    term.setCursorPos(w - #count + 1, y)
    term.write(count)
  end

  buttons = {}
  local x = 1
  local function button(label, color, action)
    term.setCursorPos(x, h)
    term.setBackgroundColor(color)
    term.setTextColor(colors.black)
    term.write(" " .. label .. " ")
    buttons[#buttons + 1] = { x1 = x, x2 = x + #label + 1, y = h, action = action }
    x = x + #label + 3
    term.setBackgroundColor(colors.black)
  end
  button(flags.paused and "Reprendre" or "Pause", colors.orange,
         function() flags.paused = not flags.paused end)
  button("Tournee", colors.lime, function() flags.runNow = true end)
  button("Quitter", colors.red, function() flags.quit = true end)
end

local function drawLoop()
  while true do
    draw()
    sleep(0.5)
  end
end

local function eventLoop()
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then
      for _, btn in ipairs(buttons) do
        if c == btn.y and b >= btn.x1 and b <= btn.x2 then btn.action() end
      end
    elseif ev == "char" then
      if a == "p" then flags.paused = not flags.paused
      elseif a == "t" then flags.runNow = true
      elseif a == "q" then flags.quit = true end
    end
  end
end

------------------------------------------------------------
-- Démarrage
------------------------------------------------------------
if args[1] == "del" then
  for _, path in ipairs({ SAVE_FILE, SAVE_FILE .. ".tmp" }) do
    if fs.exists(path) then fs.delete(path) end
  end
  removeStartup()
  print("Etat oublie, redemarrage auto retire.")
  return
elseif args[1] ~= nil then
  print("ccFarmer       lance ou reprend la ferme")
  print("ccFarmer del   oublie l'etat et le redemarrage auto")
  return
end

if not load() then save() end
-- Relancé par startup à chaque rechargement du chunk ; seul « Quitter »
-- le retire. Ctrl+T laisse la reprise en place.
installStartup()
parallel.waitForAny(mainWrapper, eventLoop, drawLoop)
removeStartup()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("ccFarmer arrete. Etat sauvegarde dans " .. SAVE_FILE)
print("Redemarrage auto retire : relancer avec ccFarmer.")
