-- Tests de ccSave. Chaque cas reproduit une panne qui casse réellement
-- ccQuarry aujourd'hui.

local H = require("harness")
local mock = require("ccMock")
local ccSave = require("ccSave")

local PATH = "quarry.save"

--- Store standard, en version 1 sans migration.
local function store()
	return ccSave.store(PATH, { version = 1 })
end

H.case("aller-retour, et les booléens restent des booléens", function()
	mock.install()
	local s = store()

	H.ok(s.write({
		curseur = 42,
		alternate = true,
		termine = false,
		nom = "quarry",
	}), "écriture")

	local data = s.read()
	H.eq(data.curseur, 42, "curseur")
	H.eq(data.nom, "quarry", "nom")
	-- L'ancien code sauvegardait tostring(alternate) et relisait == "true".
	H.eq(data.alternate, true, "alternate")
	H.eq(type(data.alternate), "boolean", "type de alternate")
	H.eq(data.termine, false, "termine")
	H.eq(type(data.termine), "boolean", "type de termine")
end)

H.case("sauvegarde absente : nil et raison, pas de plantage", function()
	mock.install()
	local s = store()

	local data, err = s.read()
	H.isNil(data, "données")
	H.eq(err, "absent", "raison")
	H.eq(s.exists(), false, "exists")
end)

H.case("panne en pleine écriture : l'ancienne sauvegarde survit", function()
	mock.install()
	local s = store()
	H.ok(s.write({ etape = 1 }), "première écriture")

	-- Le turtle est détruit après 20 octets écrits dans le temporaire.
	mock.failWriteAfter(PATH .. ".tmp", 20)
	local ok, err = s.write({ etape = 2 })
	H.eq(ok, false, "écriture interrompue")
	H.contains(err, "écriture", "raison")

	-- C'est le point critique : l'ancien code aurait laissé quarry.save tronqué,
	-- et le reboot suivant aurait planté sur savedValues[15].
	local data = s.read()
	H.eq(data.etape, 1, "l'écriture ratée n'a pas touché l'original")
end)

H.case("perte de données silencieuse : la relecture de contrôle la rattrape", function()
	mock.install()
	local s = store()
	H.ok(s.write({ etape = 1 }), "première écriture")

	-- Ici aucune erreur n'est levée : l'écriture est acquittée, mais le fichier
	-- est tronqué. Sans la relecture de contrôle, ccSave remplacerait une
	-- sauvegarde valide par un fichier illisible.
	mock.truncateOnClose(PATH .. ".tmp", 15)
	local ok, err = s.write({ etape = 2 })
	H.eq(ok, false, "écriture refusée")
	H.contains(err, "vérification", "raison")

	local data = s.read()
	H.eq(data.etape, 1, "l'original est intact")
	H.eq(fs.exists(PATH .. ".tmp"), false, "le temporaire douteux est supprimé")
end)

H.case("fichier corrompu : erreur propre au lieu d'un plantage", function()
	mock.install()
	mock.putFile(PATH, "{ version = 1, data = { etape =")   -- tronqué

	local data, err = store().read()
	H.isNil(data, "données")
	H.eq(err, "corrompu", "raison")
end)

H.case("panne entre le delete et le move : reprise depuis le temporaire", function()
	mock.install()
	local s = store()
	H.ok(s.write({ etape = 7 }), "écriture")

	-- On rejoue exactement l'état laissé par une coupure dans cette fenêtre :
	-- le temporaire est complet, le fichier principal a déjà été supprimé.
	mock.putFile(PATH .. ".tmp", mock.getFile(PATH))
	fs.delete(PATH)

	local data = s.read()
	H.eq(data.etape, 7, "données récupérées")
	H.ok(fs.exists(PATH), "le fichier principal est restauré")
	H.eq(fs.exists(PATH .. ".tmp"), false, "le temporaire est consommé")
end)

H.case("migration du format ccQuarry actuel (indices numériques)", function()
	mock.install()

	-- Format produit par ccQuarry.lua aujourd'hui : 16 indices numériques,
	-- coordonnées en nombres, drapeaux en chaînes via tostring().
	mock.putFile(PATH, textutils.serialize({
		[1] = 3, [2] = 5, [3] = -12, [4] = 1,
		[5] = 3, [6] = 5, [7] = -12, [8] = 1,
		[9] = 15, [10] = 15, [11] = -63,
		[12] = "true", [13] = "false", [14] = "false",
		[15] = "false", [16] = "false",
	}))

	local data, err = ccSave.store(PATH, {
		version = 1,
		migrations = {
			[0] = function(old)
				return {
					cur    = { x = old[1], y = old[2],  z = old[3],  dir = old[4] },
					last   = { x = old[5], y = old[6],  z = old[7],  dir = old[8] },
					target = { x = old[9], y = old[10], z = old[11] },
					alternate        = old[12] == "true",
					needFuel         = old[13] == "true",
					needClearInv     = old[14] == "true",
					done             = old[15] == "true",
					enderChestPlaced = old[16] == "true",
				}
			end,
		},
	}).read()

	H.isNil(err, "erreur")
	H.eq(data.cur.x, 3, "cur.x")
	H.eq(data.cur.dir, 1, "cur.dir")
	H.eq(data.target.z, -63, "target.z")
	H.eq(data.alternate, true, "alternate")
	H.eq(type(data.alternate), "boolean", "type de alternate")
	H.eq(data.done, false, "done")
end)

H.case("migration manquante : refus explicite", function()
	mock.install()
	mock.putFile(PATH, textutils.serialize({ [1] = 3 }))

	local data, err = store().read()
	H.isNil(data, "données")
	H.contains(err, "aucune migration", "raison")
end)

H.case("sauvegarde plus récente que le script : refus explicite", function()
	mock.install()
	H.ok(ccSave.store(PATH, { version = 4 }).write({ etape = 1 }), "écriture v4")

	local data, err = store().read()
	H.isNil(data, "données")
	H.contains(err, "version 4", "raison")
end)

H.case("delete nettoie aussi le temporaire", function()
	mock.install()
	local s = store()
	H.ok(s.write({ etape = 1 }), "écriture")
	mock.putFile(PATH .. ".tmp", "résidu")

	s.delete()
	H.eq(fs.exists(PATH), false, "fichier principal")
	H.eq(fs.exists(PATH .. ".tmp"), false, "temporaire")
	H.eq(s.exists(), false, "exists")
end)
