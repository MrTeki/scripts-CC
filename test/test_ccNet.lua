-- Tests de ccNet, côté turtle du pilotage à distance.

local H = require("harness")
local mock = require("ccMock")
local ccNet = require("ccNet")

local PROTO = "ccRemoteProtocol"

local function fresh(o)
	mock.install()
	ccNet.reset()
	if not (o and o.noModem) then
		mock.addPeripheral("left", "modem")
		ccNet.open()
	end
	if o and o.unlimited then mock.getTurtle().unlimitedFuel = true end
end

local function lastSent()
	local sent = mock.rednetSent()
	return sent[#sent]
end

-- ---------------------------------------------------------------------------
-- Ouverture
-- ---------------------------------------------------------------------------

H.case("open trouve le modem et l'ouvre", function()
	fresh()
	H.eq(ccNet.isOpen(), true, "ouvert")
	H.eq(mock.rednetIsOpen(), true, "rednet ouvert")
	H.eq(ccNet.protocol(), PROTO, "protocole de ccRemote")
end)

H.case("sans modem : no_modem, et poll ne fait rien", function()
	fresh({ noModem = true })
	local ok, reason = ccNet.open()
	H.eq(ok, false, "échec")
	H.eq(reason, "no_modem", "raison")
	H.isNil(ccNet.poll(), "poll inoffensif")
end)

H.case("poll rend la main immédiatement quand rien n'arrive", function()
	-- La moitié turtle de ccRemote bloquait dans un while true, ce qui la rend
	-- inutilisable conjointement avec une carrière.
	fresh()
	H.isNil(ccNet.poll(), "aucun message")
	H.eq(#mock.rednetSent(), 0, "aucune réponse émise")
end)

-- ---------------------------------------------------------------------------
-- Compatibilité avec le contrôleur existant
-- ---------------------------------------------------------------------------

H.case("searchTurtle reçoit la réponse attendue par ccRemote", function()
	fresh()
	mock.rednetInject(7, "searchTurtle", PROTO)

	H.eq(ccNet.poll(), "searchTurtle", "commande")
	local reply = lastSent()
	H.eq(reply.id, 7, "destinataire")
	H.eq(reply.protocol, PROTO, "protocole")
	-- Chaîne testée telle quelle par le contrôleur, à ccRemote.lua:140.
	H.eq(reply.message.message, "I'm a turtle !", "message d'appairage")
	H.eq(reply.message.success, true, "succès")
end)

H.case("refresh renvoie la télémétrie", function()
	fresh()
	mock.setSlot(3, "minecraft:coal", 12)
	mock.rednetInject(7, "refresh", PROTO)

	H.eq(ccNet.poll(), "refresh", "commande")
	local data = lastSent().message
	H.eq(data.message, "OO", "message")
	H.ok(data.epoch, "horodatage")
	H.eq(data.itemList[3].name, "minecraft:coal", "inventaire")
	H.eq(data.selectedSlot, 1, "slot sélectionné")
	H.ok(data.inspect, "inspection")
end)

H.case("le carburant est toujours transmis en nombre", function()
	-- ccRemote transmettait la chaîne "unlimited" telle quelle, et le
	-- contrôleur la passait à drawBar, qui en fait une division.
	fresh({ unlimited = true })
	mock.rednetInject(7, "refresh", PROTO)
	ccNet.poll()

	local data = lastSent().message
	H.eq(type(data.fuelLevel), "number", "niveau numérique")
	H.eq(type(data.fuelLimit), "number", "plafond numérique")
	H.eq(data.fuelUnlimited, true, "drapeau")
	H.ok(data.fuelLevel / data.fuelLimit <= 1, "division possible")
end)

H.case("un message d'un autre protocole est ignoré", function()
	fresh()
	mock.rednetInject(7, "searchTurtle", "unAutreProtocole")
	H.isNil(ccNet.poll(), "ignoré")
	H.eq(#mock.rednetSent(), 0, "aucune réponse")
end)

-- ---------------------------------------------------------------------------
-- File de commandes
-- ---------------------------------------------------------------------------

H.case("une commande est mise en file, jamais exécutée sur-le-champ", function()
	-- ccRemote appelait turtle[method](args) à la réception. Pendant une
	-- carrière, cela ferait bouger la turtle sous les pieds de la machine à
	-- états, au milieu d'un déplacement.
	fresh()
	local avant = mock.getTurtle().x
	mock.rednetInject(7, { method = "forward" }, PROTO)

	H.eq(ccNet.poll(), "forward", "commande reçue")
	H.eq(mock.getTurtle().x, avant, "la turtle n'a PAS bougé")
	H.eq(ccNet.pending(), 1, "une commande en attente")

	local cmd = ccNet.popCommand()
	H.eq(cmd.name, "forward", "nom")
	H.eq(cmd.from, 7, "émetteur")
	H.eq(ccNet.pending(), 0, "file vidée")
end)

H.case("la réponse à une commande en file confirme la prise en compte", function()
	fresh()
	mock.rednetInject(7, { method = "pause" }, PROTO)
	ccNet.poll()

	local data = lastSent().message
	H.eq(data.success, true, "succès")
	H.contains(data.message, "queued", "message")
end)

H.case("les commandes sont dépilées dans l'ordre d'arrivée", function()
	fresh()
	mock.rednetInject(7, { method = "pause" }, PROTO)
	mock.rednetInject(7, { method = "resume" }, PROTO)
	mock.rednetInject(8, { method = "abort" }, PROTO)
	ccNet.poll() ccNet.poll() ccNet.poll()

	H.eq(ccNet.pending(), 3, "trois en attente")
	H.eq(ccNet.popCommand().name, "pause", "première")
	H.eq(ccNet.popCommand().name, "resume", "deuxième")
	H.eq(ccNet.popCommand().name, "abort", "troisième")
	H.isNil(ccNet.popCommand(), "file vide")
end)

H.case("un gestionnaire enregistré répond sans passer par la file", function()
	fresh()
	local vu = nil
	ccNet.on("status", function(args) vu = args return true, "en cours" end)
	mock.rednetInject(7, { method = "status", args = "detaille" }, PROTO)

	H.eq(ccNet.poll(), "status", "commande")
	H.eq(vu, "detaille", "arguments transmis")
	H.eq(ccNet.pending(), 0, "rien en file")
	H.eq(lastSent().message.message, "en cours", "réponse du gestionnaire")
end)

H.case("un gestionnaire qui plante ne fait pas tomber ccNet", function()
	fresh()
	ccNet.on("boom", function() error("panne interne") end)
	mock.rednetInject(7, { method = "boom" }, PROTO)

	H.eq(ccNet.poll(), "boom", "commande traitée")
	H.eq(lastSent().message.success, false, "échec signalé")
end)

-- ---------------------------------------------------------------------------
-- Télémétrie applicative
-- ---------------------------------------------------------------------------

H.case("setTelemetry enrichit chaque réponse", function()
	fresh()
	ccNet.setTelemetry(function()
		return { etat = "MINAGE", progression = 0.42, restant = 1250 }
	end)
	mock.rednetInject(7, "refresh", PROTO)
	ccNet.poll()

	local data = lastSent().message
	H.eq(data.etat, "MINAGE", "état")
	H.eq(data.progression, 0.42, "progression")
	H.eq(data.restant, 1250, "blocs restants")
	H.eq(data.message, "OO", "les champs du protocole sont préservés")
end)

H.case("la télémétrie applicative n'écrase pas les champs du protocole", function()
	fresh()
	ccNet.setTelemetry(function() return { message = "detourne", success = false } end)
	mock.rednetInject(7, "searchTurtle", PROTO)
	ccNet.poll()

	local data = lastSent().message
	H.eq(data.message, "I'm a turtle !", "message d'appairage préservé")
	H.eq(data.success, true, "succès préservé")
end)
