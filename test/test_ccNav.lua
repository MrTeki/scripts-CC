-- Tests de ccNav.
--
-- Plusieurs cas ne valent que par le fait qu'ils SE TERMINENT : avec le code
-- d'origine, ils bouclaient indéfiniment. Le harnais n'a pas de délai maximum,
-- donc une régression sur ces cas fige la suite au lieu de l'échouer.

local H = require("harness")
local mock = require("ccMock")
local ccNav = require("ccNav")

--- Monde vide, turtle en (0,0,0) direction 0.
local function fresh(opts)
	mock.install()
	if opts and opts.fuel ~= nil then mock.getTurtle().fuel = opts.fuel end
	if opts and opts.unlimited then mock.getTurtle().unlimitedFuel = true end
	ccNav.reset(opts and opts.nav or nil)
end

-- ---------------------------------------------------------------------------
-- Mouvement simple
-- ---------------------------------------------------------------------------

H.case("forward en terrain libre met à jour la position et consomme du carburant", function()
	fresh({ fuel = 10 })

	H.ok(ccNav.forward(), "mouvement")
	local p = ccNav.position()
	H.eq(p.x, 1, "x")
	H.eq(p.y, 0, "y")
	H.eq(p.z, 0, "z")
	H.eq(mock.getTurtle().fuel, 9, "carburant")
	H.eq(ccNav.stats().moves, 1, "compteur de mouvements")
end)

H.case("up et down suivent la convention Z verticale", function()
	fresh()

	H.ok(ccNav.up(), "montée")
	H.eq(ccNav.position().z, 1, "z après up")
	H.ok(ccNav.down(), "descente")
	H.ok(ccNav.down(), "seconde descente")
	H.eq(ccNav.position().z, -1, "z après deux down")
	H.eq(mock.getTurtle().z, -1, "position réelle du turtle")
end)

H.case("back recule sans changer de direction", function()
	fresh()
	ccNav.forward()

	H.ok(ccNav.back(), "recul")
	H.eq(ccNav.position().x, 0, "x")
	H.eq(ccNav.position().dir, 0, "direction inchangée")
end)

-- ---------------------------------------------------------------------------
-- Obstacles
-- ---------------------------------------------------------------------------

H.case("gravier qui retombe : la séquence entière est retentée", function()
	fresh()
	-- Colonne de gravier devant : chaque dig en fait retomber un nouveau dans
	-- la case visée. C'est la course qui mettait done = true dans Forwards().
	mock.setBlock(1, 0, 0, { name = "minecraft:gravel", falling = true })
	mock.setBlock(1, 0, 1, { name = "minecraft:gravel", falling = true })
	mock.setBlock(1, 0, 2, { name = "minecraft:gravel", falling = true })

	H.ok(ccNav.forward({ tries = 4 }), "traversée")
	H.eq(ccNav.position().x, 1, "x")
	H.eq(ccNav.stats().dug, 3, "trois blocs creusés")
end)

H.case("colonne de gravier de hauteur maximale : la turtle en vient à bout", function()
	-- 384 = hauteur du monde depuis la 1.18 (Y de -64 à 319), donc la plus
	-- haute colonne que le moteur autorise. Avec l'ancien compteur unique à 8
	-- tentatives, la turtle butait dès 8 blocs.
	fresh()
	for z = 0, 383 do
		mock.setBlock(1, 0, z, { name = "minecraft:sand", falling = true })
	end

	H.ok(ccNav.forward(), "traversée avec les réglages par défaut")
	H.eq(ccNav.position().x, 1, "x")
	H.eq(ccNav.stats().dug, 384, "384 blocs creusés")
end)

H.case("maxDig borne les blocs qui repoussent", function()
	-- Générateur de cobble : chaque dig réussit, indéfiniment. Sans plafond
	-- absolu, la boucle ne rendrait jamais la main, puisque creuser compte
	-- comme un progrès.
	fresh()
	mock.setBlock(1, 0, 0, { name = "minecraft:cobblestone", regenerates = true })

	local ok, reason = ccNav.forward({ maxDig = 20 })
	H.eq(ok, false, "échec")
	H.eq(reason, "blocked", "raison")
	H.eq(ccNav.stats().dug, 20, "arrêt au plafond")
end)

H.case("gravier : plafond insuffisant, échec net plutôt que boucle", function()
	fresh()
	mock.setBlock(1, 0, 0, { name = "minecraft:gravel", falling = true })
	mock.setBlock(1, 0, 1, { name = "minecraft:gravel", falling = true })
	mock.setBlock(1, 0, 2, { name = "minecraft:gravel", falling = true })

	local ok, reason = ccNav.forward({ maxDig = 2 })
	H.eq(ok, false, "échec")
	H.eq(reason, "blocked", "raison")
	H.eq(ccNav.position().x, 0, "position inchangée")
end)

H.case("un dig réussi ne consomme pas le budget d'essais stériles", function()
	-- La séparation des deux compteurs : 5 blocs de gravier passent alors que
	-- le budget d'essais stériles n'est que de 2.
	fresh()
	for z = 0, 4 do
		mock.setBlock(1, 0, z, { name = "minecraft:gravel", falling = true })
	end

	H.ok(ccNav.forward({ tries = 2 }), "traversée")
	H.eq(ccNav.stats().dug, 5, "cinq blocs creusés")
end)

H.case("bedrock : unbreakable, avec le nom du bloc", function()
	fresh()
	mock.setBlock(1, 0, 0, { name = "minecraft:bedrock", unbreakable = true })

	local ok, reason, bloc = ccNav.forward()
	H.eq(ok, false, "échec")
	H.eq(reason, "unbreakable", "raison")
	H.eq(bloc, "minecraft:bedrock", "nom du bloc")
end)

H.case("bedrock au-dessus : up échoue au lieu de boucler", function()
	-- `while detectUp() and digUp() do end` sortait sur le dig en échec,
	-- detectUp() restait vrai, et GoUp bouclait indéfiniment.
	fresh()
	mock.setBlock(0, 0, 1, { name = "minecraft:bedrock", unbreakable = true })

	local ok, reason, bloc = ccNav.up()
	H.eq(ok, false, "échec")
	H.eq(reason, "unbreakable", "raison")
	H.eq(bloc, "minecraft:bedrock", "nom du bloc")
end)

H.case("dig désactivé : blocked, avec le nom du bloc", function()
	fresh()
	mock.setBlock(1, 0, 0, "minecraft:stone")

	local ok, reason, bloc = ccNav.forward({ dig = false })
	H.eq(ok, false, "échec")
	H.eq(reason, "blocked", "raison")
	H.eq(bloc, "minecraft:stone", "nom du bloc")
	H.ok(mock.getBlock(1, 0, 0), "le bloc est intact")
end)

H.case("entité : attaquée puis dépassée", function()
	fresh()
	mock.spawnEntity(1, 0, 0, 2)

	H.ok(ccNav.forward({ tries = 4 }), "passage")
	H.eq(ccNav.position().x, 1, "x")
	H.eq(ccNav.stats().attacks, 2, "deux attaques")
end)

H.case("entité increvable : echec net plutôt que boucle", function()
	fresh()
	mock.spawnEntity(1, 0, 0, 1000)

	local ok, reason = ccNav.forward({ tries = 5 })
	H.eq(ok, false, "échec")
	H.eq(reason, "entity", "raison")
end)

-- ---------------------------------------------------------------------------
-- Carburant
-- ---------------------------------------------------------------------------

H.case("panne sèche : no_fuel immédiat, sans attaquer le vide", function()
	-- LE blocage historique : forward() échouait, detect() était faux, donc
	-- ccQuarry appelait attack() indéfiniment. Que ce test se termine est la
	-- preuve de la correction.
	fresh({ fuel = 0 })

	local ok, reason = ccNav.forward()
	H.eq(ok, false, "échec")
	H.eq(reason, "no_fuel", "raison")
	H.eq(ccNav.stats().attacks, 0, "aucune attaque")
	H.eq(ccNav.position().x, 0, "position inchangée")
end)

H.case("carburant illimité : aucune comparaison chaîne / nombre", function()
	-- turtle.getFuelLevel() renvoie "unlimited" quand le serveur désactive le
	-- carburant. Les comparaisons brutes de ccQuarry plantaient alors.
	fresh({ unlimited = true })

	H.eq(ccNav.fuelLevel(), math.huge, "niveau normalisé")
	H.ok(ccNav.forward(), "mouvement")
	H.ok(ccNav.goTo({ x = 3, y = 3, z = 0 }), "trajet")
end)

H.case("garde canMove : denied, sans mouvement", function()
	fresh()
	ccNav.configure({ canMove = function() return false end })

	local ok, reason = ccNav.forward()
	H.eq(ok, false, "échec")
	H.eq(reason, "denied", "raison")
	H.eq(mock.getTurtle().x, 0, "le turtle n'a pas bougé")
end)

H.case("onChange reçoit la position après chaque mouvement réussi", function()
	fresh()
	local vues = {}
	ccNav.configure({ onChange = function(p) vues[#vues + 1] = p.x .. "," .. p.y .. "," .. p.z end })

	ccNav.forward()
	ccNav.up()
	H.eq(#vues, 2, "deux notifications")
	H.eq(vues[1], "1,0,0", "après forward")
	H.eq(vues[2], "1,0,1", "après up")
end)

-- ---------------------------------------------------------------------------
-- Rotation
-- ---------------------------------------------------------------------------

H.case("onChange se déclenche AUSSI sur les rotations", function()
	-- Bug observé en jeu : au rechargement de la partie, la turtle repartait
	-- avec un cap faux. Le crochet s'appelait onMove et ne voyait que les
	-- déplacements ; les rotations changeaient dir sans rien notifier, donc
	-- sans être sauvegardées. En quittant la partie, le jeu n'accorde qu'un
	-- tick à la turtle : tout changement non notifié est perdu.
	fresh()
	local caps = {}
	ccNav.configure({ onChange = function(p) caps[#caps + 1] = p.dir end })

	ccNav.turnRight()
	ccNav.turnRight()
	ccNav.turnLeft()

	H.eq(#caps, 3, "une notification par rotation")
	H.eq(caps[1], 1, "après le premier quart de tour")
	H.eq(caps[2], 2, "après le second")
	H.eq(caps[3], 1, "après le retour à gauche")
end)

H.case("le cap notifié correspond toujours au cap réel", function()
	-- L'invariant qui compte pour la reprise : ce qui est notifié -- donc
	-- sauvegardé -- ne doit jamais differer de l'orientation physique.
	fresh()
	local dernier
	ccNav.configure({ onChange = function(p) dernier = p.dir end })

	for _, t in ipairs({ "R", "R", "L", "L", "L", "R" }) do
		if t == "R" then ccNav.turnRight() else ccNav.turnLeft() end
		H.eq(dernier, mock.getTurtle().dir, "cap notifié après " .. t)
	end

	ccNav.turnTo(3)
	H.eq(dernier, mock.getTurtle().dir, "cap notifié après turnTo")

	ccNav.turnAround()
	H.eq(dernier, mock.getTurtle().dir, "cap notifié après demi-tour")
end)

H.case("setPosition notifie, pour que le recalage soit enregistré", function()
	fresh()
	local vues = 0
	ccNav.configure({ onChange = function() vues = vues + 1 end })

	ccNav.setPosition({ x = 3, y = 4, z = -5, dir = 2 })
	H.eq(vues, 1, "recalage notifié")
end)

H.case("la direction suivie ne diverge jamais de la direction réelle", function()
	-- Downwards écrivait lastDir avant de décrémenter dir ; Upwards associait
	-- turtle.turnLeft() à dir + 1. Ici rotation et comptabilité sont dans la
	-- même fonction, donc l'invariant tient à chaque étape.
	fresh()
	local sequence = { "R", "R", "L", "R", "L", "L", "L", "R", "R", "R" }
	for _, t in ipairs(sequence) do
		if t == "R" then ccNav.turnRight() else ccNav.turnLeft() end
		H.eq(ccNav.position().dir, mock.getTurtle().dir, "après " .. t)
	end
end)

H.case("turnTo : les 16 paires convergent, direction réelle comprise", function()
	for from = 0, 3 do
		for to = 0, 3 do
			fresh()
			for _ = 1, from do ccNav.turnRight() end
			H.eq(ccNav.position().dir, from, "mise en place " .. from)

			ccNav.turnTo(to)
			local label = "de " .. from .. " vers " .. to
			H.eq(ccNav.position().dir, to, label .. " : direction suivie")
			H.eq(mock.getTurtle().dir, to, label .. " : direction réelle")
			H.ok(ccNav.stats().turns - from <= 2, label .. " : 2 rotations au plus")
		end
	end
end)

H.case("turnAround fait bien un demi-tour", function()
	fresh()
	ccNav.turnAround()
	H.eq(ccNav.position().dir, 2, "direction suivie")
	H.eq(mock.getTurtle().dir, 2, "direction réelle")
end)

-- ---------------------------------------------------------------------------
-- Trajet
-- ---------------------------------------------------------------------------

H.case("goTo atteint la cible et son orientation", function()
	fresh()

	H.ok(ccNav.goTo({ x = 4, y = 3, z = -2, dir = 3 }), "trajet")
	local p = ccNav.position()
	H.eq(p.x, 4, "x") H.eq(p.y, 3, "y") H.eq(p.z, -2, "z") H.eq(p.dir, 3, "direction")
	H.eq(mock.getTurtle().x, 4, "x réel")
	H.eq(mock.getTurtle().z, -2, "z réel")
end)

H.case("goTo revient à l'origine depuis n'importe où", function()
	fresh()
	ccNav.goTo({ x = 5, y = 5, z = -5 })

	H.ok(ccNav.goTo({ x = 0, y = 0, z = 0, dir = 2 }), "retour")
	H.eq(ccNav.position().x, 0, "x")
	H.eq(ccNav.position().y, 0, "y")
	H.eq(ccNav.position().z, 0, "z")
	H.eq(ccNav.position().dir, 2, "direction")
end)

H.case("goTo bloqué par du bedrock : échec net plutôt que boucle", function()
	-- GoXY bouclait indéfiniment dès qu'un bloc non creusé se présentait, en
	-- particulier devant l'origine, où tForward refusait de creuser.
	fresh()
	for z = -1, 1 do
		mock.setBlock(1, 0, z, { name = "minecraft:bedrock", unbreakable = true })
	end

	local ok, reason, bloc = ccNav.goTo({ x = 5, y = 0, z = 0 })
	H.eq(ok, false, "échec")
	H.eq(reason, "unbreakable", "raison")
	H.eq(bloc, "minecraft:bedrock", "nom du bloc")
end)

H.case("goTo respecte l'ordre des axes", function()
	fresh()
	-- En ordre zxy, la montée est faite avant tout déplacement horizontal.
	local trace = {}
	ccNav.configure({ onChange = function(p) trace[#trace + 1] = p.z end })
	ccNav.goTo({ x = 2, y = 0, z = 3 }, { order = "zxy" })

	H.eq(trace[1], 1, "premier mouvement en Z")
	H.eq(trace[3], 3, "Z atteint avant l'horizontale")
	H.eq(ccNav.position().x, 2, "x final")
end)

-- ---------------------------------------------------------------------------
-- Creusement direct
-- ---------------------------------------------------------------------------

H.case("dig dégage une colonne de gravier, dans le budget", function()
	fresh()
	mock.setBlock(0, 0, 1, { name = "minecraft:gravel", falling = true })
	mock.setBlock(0, 0, 2, { name = "minecraft:gravel", falling = true })

	H.ok(ccNav.dig("up"), "dégagement")
	H.isNil(mock.getBlock(0, 0, 1), "case libérée")
end)

H.case("dig sur une case déjà vide réussit sans rien faire", function()
	fresh()
	H.ok(ccNav.dig("forward"), "succès")
	H.eq(ccNav.stats().dug, 0, "aucun bloc creusé")
end)

-- ---------------------------------------------------------------------------
-- GPS
-- ---------------------------------------------------------------------------

H.case("gpsPosition convertit la verticale monde en Z local", function()
	fresh()
	mock.setGps(100, 64, 200)      -- monde : wy = 64 est la verticale
	ccNav.goTo({ x = 3, y = 7, z = -5 })

	local p = ccNav.gpsPosition()
	H.eq(p.x, 103, "x <- wx")
	H.eq(p.y, 207, "y <- wz")
	H.eq(p.z, 59, "z <- wy")
end)

H.case("gpsPosition renvoie nil sans constellation", function()
	fresh()
	H.isNil(ccNav.gpsPosition(), "pas de GPS")
end)

H.case("gpsHeading retrouve le cap dans les 4 directions", function()
	for dir = 0, 3 do
		fresh()
		mock.setGps(0, 0, 0)
		mock.getTurtle().dir = dir      -- cap réel inconnu de ccNav

		local found = ccNav.gpsHeading()
		H.eq(found, dir, "cap depuis " .. dir)
		H.eq(mock.getTurtle().x, 0, "revenu en x")
		H.eq(mock.getTurtle().y, 0, "revenu en y")
		H.eq(mock.getTurtle().dir, dir, "orientation restaurée")
	end
end)

H.case("gpsHeading pivote vers une case libre sans rien casser", function()
	-- Le turtle est dans un couloir : bloqué devant et derrière, libre sur les
	-- côtés. C'est la situation normale au fond d'une carrière.
	fresh()
	mock.setGps(0, 0, 0)
	mock.getTurtle().dir = 0
	mock.setBlock(1, 0, 0, "minecraft:stone")     -- devant
	mock.setBlock(-1, 0, 0, "minecraft:stone")    -- derrière

	H.eq(ccNav.gpsHeading(), 0, "cap")
	H.eq(mock.getTurtle().x, 0, "revenu en x")
	H.eq(mock.getTurtle().y, 0, "revenu en y")
	H.eq(mock.getTurtle().dir, 0, "orientation restaurée")
	H.ok(mock.getBlock(1, 0, 0), "le bloc devant est intact")
	H.ok(mock.getBlock(-1, 0, 0), "le bloc derrière est intact")
	H.eq(ccNav.stats().dug, 0, "aucun bloc creusé")
end)

H.case("gpsHeading refuse de creuser sans autorisation explicite", function()
	fresh()
	mock.setGps(0, 0, 0)
	for _, p in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		mock.setBlock(p[1], p[2], 0, "minecraft:stone")
	end

	local dir, reason = ccNav.gpsHeading()
	H.isNil(dir, "aucun cap")
	H.contains(reason, "aucune case libre", "raison")
	H.eq(mock.getTurtle().dir, 0, "orientation restaurée")

	-- Avec l'autorisation, elle creuse et se repère.
	H.eq(ccNav.gpsHeading({ dig = true }), 0, "cap avec dig autorisé")
end)

H.case("calibrate recale la position suivie sur le GPS", function()
	fresh()
	mock.setGps(1000, 64, 2000)
	-- Le turtle a été déplacé sans que ccNav le sache (reboot, dérive).
	local t = mock.getTurtle()
	t.x, t.y, t.z = 12, -3, -40

	H.ok(ccNav.calibrate({ x = 1000, y = 2000, z = 64 }), "recalage")
	local p = ccNav.position()
	H.eq(p.x, 12, "x") H.eq(p.y, -3, "y") H.eq(p.z, -40, "z")
end)
