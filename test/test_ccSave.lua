-- Tests de ccSave. Chaque cas reproduit une panne qui casse reellement
-- ccQuarry aujourd'hui.

local H = require("harness")
local mock = require("ccMock")
local ccSave = require("ccSave")

local PATH = "quarry.save"

H.case("aller-retour, et les booleens restent des booleens", function()
	mock.install()

	local ok = ccSave.write(PATH, {
		curseur = 42,
		alternate = true,
		termine = false,
		nom = "quarry",
	}, { version = 1 })
	H.ok(ok, "ecriture")

	local data = ccSave.read(PATH, { version = 1 })
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

	local data, err = ccSave.read(PATH, { version = 1 })
	H.isNil(data, "donnees")
	H.eq(err, "absent", "raison")
	H.eq(ccSave.exists(PATH), false, "exists")
end)

H.case("panne en pleine ecriture : l'ancienne sauvegarde survit", function()
	mock.install()
	H.ok(ccSave.write(PATH, { etape = 1 }, { version = 1 }), "premiere ecriture")

	-- Le turtle est detruit apres 20 octets ecrits dans le temporaire.
	mock.failWriteAfter(PATH .. ".tmp", 20)
	local ok, err = ccSave.write(PATH, { etape = 2 }, { version = 1 })
	H.eq(ok, false, "ecriture interrompue")
	H.contains(err, "ecriture", "raison")

	-- C'est le point critique : l'ancien code aurait laisse quarry.save tronque,
	-- et le reboot suivant aurait plante sur savedValues[15].
	local data = ccSave.read(PATH, { version = 1 })
	H.eq(data.etape, 1, "l'ecriture ratee n'a pas touche l'original")
end)

H.case("perte de donnees silencieuse : la relecture de controle la rattrape", function()
	mock.install()
	H.ok(ccSave.write(PATH, { etape = 1 }, { version = 1 }), "premiere ecriture")

	-- Ici aucune erreur n'est levee : l'ecriture est acquittee, mais le fichier
	-- est tronque. Sans la relecture de controle, ccSave remplacerait une
	-- sauvegarde valide par un fichier illisible.
	mock.truncateOnClose(PATH .. ".tmp", 15)
	local ok, err = ccSave.write(PATH, { etape = 2 }, { version = 1 })
	H.eq(ok, false, "ecriture refusee")
	H.contains(err, "verification", "raison")

	local data = ccSave.read(PATH, { version = 1 })
	H.eq(data.etape, 1, "l'original est intact")
	H.eq(fs.exists(PATH .. ".tmp"), false, "le temporaire douteux est supprime")
end)

H.case("fichier corrompu : erreur propre au lieu d'un plantage", function()
	mock.install()
	mock.putFile(PATH, "{ version = 1, data = { etape =")   -- tronque

	local data, err = ccSave.read(PATH, { version = 1 })
	H.isNil(data, "donnees")
	H.eq(err, "corrompu", "raison")
end)

H.case("panne entre le delete et le move : reprise depuis le temporaire", function()
	mock.install()
	H.ok(ccSave.write(PATH, { etape = 7 }, { version = 1 }), "ecriture")

	-- On rejoue exactement l'etat laisse par une coupure dans cette fenetre :
	-- le temporaire est complet, le fichier principal a deja ete supprime.
	mock.putFile(PATH .. ".tmp", mock.getFile(PATH))
	fs.delete(PATH)

	local data = ccSave.read(PATH, { version = 1 })
	H.eq(data.etape, 7, "donnees recuperees")
	H.ok(fs.exists(PATH), "le fichier principal est restaure")
	H.eq(fs.exists(PATH .. ".tmp"), false, "le temporaire est consomme")
end)

H.case("migration du format ccQuarry actuel (indices numeriques)", function()
	mock.install()

	-- Format produit par ccQuarry.lua aujourd'hui : 16 indices numeriques,
	-- coordonnees en nombres, drapeaux en chaines via tostring().
	mock.putFile(PATH, textutils.serialize({
		[1] = 3, [2] = 5, [3] = -12, [4] = 1,
		[5] = 3, [6] = 5, [7] = -12, [8] = 1,
		[9] = 15, [10] = 15, [11] = -63,
		[12] = "true", [13] = "false", [14] = "false",
		[15] = "false", [16] = "false",
	}))

	local data, err = ccSave.read(PATH, {
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
	})

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

	local data, err = ccSave.read(PATH, { version = 1 })
	H.isNil(data, "donnees")
	H.contains(err, "aucune migration", "raison")
end)

H.case("sauvegarde plus recente que le script : refus explicite", function()
	mock.install()
	H.ok(ccSave.write(PATH, { etape = 1 }, { version = 4 }), "ecriture v4")

	local data, err = ccSave.read(PATH, { version = 1 })
	H.isNil(data, "donnees")
	H.contains(err, "version 4", "raison")
end)

H.case("delete nettoie aussi le temporaire", function()
	mock.install()
	H.ok(ccSave.write(PATH, { etape = 1 }, { version = 1 }), "ecriture")
	mock.putFile(PATH .. ".tmp", "residu")

	ccSave.delete(PATH)
	H.eq(fs.exists(PATH), false, "fichier principal")
	H.eq(fs.exists(PATH .. ".tmp"), false, "temporaire")
	H.eq(ccSave.exists(PATH), false, "exists")
end)
