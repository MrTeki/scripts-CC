-- ccNet : côté turtle du pilotage à distance.
--
-- Sert le protocole que le contrôleur de poche de ccRemote.lua parle DÉJÀ,
-- « ccRemoteProtocol », mais sous une forme non bloquante.
--
-- C'est le vrai manque aujourd'hui. ccRemote.lua contient les deux moitiés :
-- `if turtle ~= nil then ... end` répond depuis la turtle, le reste est le
-- contrôleur. Mais la moitié turtle tourne dans un `while true` qui ne rend
-- jamais la main, donc elle est incompatible avec ccQuarry. D'où le dialecte
-- séparé de ccQuarry (« CCQuarryPortable » en réception, « CCQuarry » en
-- émission), que rien n'émet ni n'écoute.
--
-- Ici, poll() traite AU PLUS un message et rend la main immédiatement. La
-- machine à états l'appelle entre deux transitions.
--
-- RÈGLE STRUCTURANTE, identique à celle de ccUi : ce module ne touche jamais
-- au turtle de sa propre initiative. La moitié turtle de ccRemote exécutait
-- `turtle[response.method](response.args)` directement à la réception, ce qui,
-- pendant une carrière, ferait bouger la turtle sous les pieds de la machine à
-- états. Ici une commande est mise en file, et l'appelant décide quand et si
-- elle s'exécute.
--
-- Protocole servi (inchangé, pour rester compatible avec le contrôleur) :
--   "searchTurtle"          -> { success, message = "I'm a turtle !", ...télémétrie }
--   "refresh"               -> { success, message = "OO", ...télémétrie }
--   { method, args }        -> mis en file, réponse immédiate avec la télémétrie
--
-- Une seule divergence assumée : fuelLevel et fuelLimit sont TOUJOURS envoyés
-- sous forme de nombres. La moitié turtle de ccRemote transmettait la chaîne
-- "unlimited" telle quelle, et le contrôleur la passait à drawBar, qui en fait
-- une division. Le drapeau fuelUnlimited porte l'information sans casser
-- l'affichage.

local ccUtil = require("ccUtil")
local ccFuel = require("ccFuel")

local M = { _VERSION = 1 }

local PROTOCOL = "ccRemoteProtocol"

local state

-- ---------------------------------------------------------------------------
-- Ouverture
-- ---------------------------------------------------------------------------

function M.reset()
	state = {
		protocol = PROTOCOL,
		side = nil,
		telemetry = nil,   -- fonction fournie par l'appelant
		handlers = {},     -- commandes personnalisées
		queue = {},        -- commandes reçues, en attente d'exécution
	}
end

--- Ouvre le modem s'il y en a un.
-- @return true, ou false + raison
function M.open(o)
	o = o or {}
	if o.protocol then state.protocol = o.protocol end

	local side = ccUtil.findPeripheral("modem")
	if not side then return false, "no_modem" end

	rednet.open(side)
	state.side = side
	return true
end

function M.isOpen() return state.side ~= nil end

function M.close()
	if state.side then rednet.close(state.side) end
	state.side = nil
end

function M.protocol() return state.protocol end

--- Fournisseur de télémétrie propre au script (progression, état, cible...).
-- Le résultat est fusionné dans chaque réponse.
function M.setTelemetry(fn) state.telemetry = fn end

--- Enregistre une commande nommée. Le gestionnaire ne doit rien exécuter de
-- bloquant : il sert à valider et à répondre, pas à agir.
function M.on(name, handler) state.handlers[name] = handler end

-- ---------------------------------------------------------------------------
-- Télémétrie
-- ---------------------------------------------------------------------------

local function baseTelemetry()
	local data = {
		epoch = os.epoch("utc"),
		fuelUnlimited = ccFuel.isUnlimited(),
	}

	-- Toujours des nombres : voir la note d'en-tête.
	if data.fuelUnlimited then
		data.fuelLevel, data.fuelLimit = 1, 1
	else
		data.fuelLevel, data.fuelLimit = ccFuel.level(), ccFuel.limit()
	end

	if turtle then
		local items = {}
		for slot = 1, 16 do items[slot] = turtle.getItemDetail(slot) end
		data.itemList = items
		data.selectedSlot = turtle.getSelectedSlot()
		data.selectedItem = turtle.getItemDetail(turtle.getSelectedSlot())
		data.inspect = {
			front = turtle.inspect(),
			up = turtle.inspectUp(),
			down = turtle.inspectDown(),
		}
	end

	if state.telemetry then
		for k, v in pairs(state.telemetry() or {}) do data[k] = v end
	end
	return data
end

M.telemetry = baseTelemetry

-- ---------------------------------------------------------------------------
-- File de commandes
-- ---------------------------------------------------------------------------

--- Retire et renvoie la commande la plus ancienne, ou nil.
-- @return { name, args, from }
function M.popCommand()
	return table.remove(state.queue, 1)
end

function M.pending() return #state.queue end

function M.clearQueue() state.queue = {} end

-- ---------------------------------------------------------------------------
-- Réception
-- ---------------------------------------------------------------------------

--- Traite un message DÉJÀ reçu, tel que le livre l'événement rednet_message.
-- Indispensable quand l'appelant a sa propre boucle d'événements : une fois
-- l'événement consommé par os.pullEvent, rednet.receive ne le reverra jamais.
-- @return nom de la commande, ou nil si le message ne nous concerne pas
function M.handleMessage(id, message, protocol)
	if not state.side then return nil end
	if protocol ~= nil and protocol ~= state.protocol then return nil end

	local data, name

	if message == "searchTurtle" then
		name = "searchTurtle"
		data = { success = true, message = "I'm a turtle !" }

	elseif message == "refresh" then
		name = "refresh"
		data = { success = true, message = "OO" }

	elseif type(message) == "table" and message.method then
		name = message.method
		local handler = state.handlers[name]
		if handler then
			local ok, success, text = pcall(handler, message.args, id)
			data = { success = ok and success ~= false, message = ok and text or tostring(success) }
		else
			-- Mise en file : l'exécution appartient à la machine à états.
			state.queue[#state.queue + 1] = { name = name, args = message.args, from = id }
			data = { success = true, message = "queued: " .. name }
		end

	else
		name = nil
		data = { success = false, message = "unknown request" }
	end

	for k, v in pairs(baseTelemetry()) do
		if data[k] == nil then data[k] = v end
	end
	rednet.send(id, data, state.protocol)
	return name
end

--- Traite au plus UN message en attente, puis rend la main.
-- Pour les appelants qui n'ont pas leur propre boucle d'événements.
-- @return nom de la commande reçue, ou nil si rien n'est arrivé
function M.poll()
	if not state.side then return nil end

	local id, message, protocol = rednet.receive(state.protocol)
	if not id then return nil end
	return M.handleMessage(id, message, protocol)
end

M.reset()

return M
