-- Tests de ccVec. Les cas exhaustifs encodent les bugs de direction relevés
-- dans ccQuarry : normalisation en effet de bord, rotation qui ne converge pas,
-- et turnLeft associé à dir + 1.

local H = require("harness")
local ccVec = require("ccVec")

H.case("normalize ramène toute valeur dans [0, 3]", function()
	H.eq(ccVec.normalize(0), 0, "0")
	H.eq(ccVec.normalize(3), 3, "3")
	-- Les valeurs que ccQuarry produisait réellement.
	H.eq(ccVec.normalize(4), 0, "4, produit par la boucle de GoTo")
	H.eq(ccVec.normalize(-1), 3, "-1, persisté en sauvegarde par Downwards")
	-- Save() ne corrigeait que d'un seul cran : au-delà, la valeur restait fausse.
	H.eq(ccVec.normalize(8), 0, "8")
	H.eq(ccVec.normalize(-8), 0, "-8")
	H.eq(ccVec.normalize(-5), 3, "-5")
end)

H.case("turnLeft vaut bien dir - 1, et turnRight dir + 1", function()
	-- Upwards() faisait turtle.turnLeft() puis dir = dir + 1. Le résultat final
	-- était juste par accident (un demi-tour est son propre inverse), mais
	-- l'état intermédiaire sauvegardé était à 180 degrés.
	H.eq(ccVec.turnLeft(0), 3, "turnLeft depuis 0")
	H.eq(ccVec.turnRight(0), 1, "turnRight depuis 0")
	H.eq(ccVec.turnLeft(3), 2, "turnLeft depuis 3")
	H.eq(ccVec.turnRight(3), 0, "turnRight depuis 3")
end)

H.case("turnLeft et turnRight sont inverses, sur les 4 directions", function()
	for dir = 0, 3 do
		H.eq(ccVec.turnRight(ccVec.turnLeft(dir)), dir, "aller-retour depuis " .. dir)
		H.eq(ccVec.turnLeft(ccVec.turnRight(dir)), dir, "retour-aller depuis " .. dir)
		H.eq(ccVec.turnLeft(ccVec.turnLeft(dir)), ccVec.turnAround(dir),
			"deux fois à gauche depuis " .. dir)
		H.eq(ccVec.turnRight(ccVec.turnRight(dir)), ccVec.turnAround(dir),
			"deux fois à droite depuis " .. dir)
	end
end)

H.case("turnsBetween : les 16 paires convergent, en 2 rotations au plus", function()
	for from = 0, 3 do
		for to = 0, 3 do
			local turns = ccVec.turnsBetween(from, to)
			local label = "de " .. from .. " vers " .. to

			H.ok(turns >= -1 and turns <= 2, label .. " : rotations bornées")

			-- On applique réellement les rotations et on vérifie l'arrivée.
			-- C'est ce que la boucle `while dir ~= toDir` de ccQuarry ne
			-- garantissait pas : avec dir = -1 elle oscillait indéfiniment.
			local d = from
			if turns >= 0 then
				for _ = 1, turns do d = ccVec.turnRight(d) end
			else
				for _ = 1, -turns do d = ccVec.turnLeft(d) end
			end
			H.eq(d, to, label .. " : arrivée")
		end
	end
end)

H.case("turnsBetween accepte les directions non normalisées", function()
	H.eq(ccVec.turnsBetween(-1, 0), 1, "depuis -1")
	H.eq(ccVec.turnsBetween(4, 3), -1, "depuis 4")
	H.eq(ccVec.turnsBetween(0, 8), 0, "vers 8")
end)

H.case("delta et ahead suivent la convention d'axes", function()
	local dx, dy = ccVec.delta(0) H.eq(dx, 1, "dir 0 : dx") H.eq(dy, 0, "dir 0 : dy")
	dx, dy = ccVec.delta(1) H.eq(dx, 0, "dir 1 : dx") H.eq(dy, 1, "dir 1 : dy")
	dx, dy = ccVec.delta(2) H.eq(dx, -1, "dir 2 : dx") H.eq(dy, 0, "dir 2 : dy")
	dx, dy = ccVec.delta(3) H.eq(dx, 0, "dir 3 : dx") H.eq(dy, -1, "dir 3 : dy")

	local p = ccVec.new(5, 5, -3, 1)
	local q = ccVec.ahead(p, 4)
	H.eq(q.x, 5, "x inchangé")
	H.eq(q.y, 9, "y avancé de 4")
	H.eq(q.z, -3, "z inchangé")
	H.eq(q.dir, 1, "direction conservée")
end)

H.case("new normalise la direction fournie", function()
	H.eq(ccVec.new(0, 0, 0, -1).dir, 3, "-1")
	H.eq(ccVec.new(0, 0, 0, 5).dir, 1, "5")
	H.isNil(ccVec.new(1, 2, 3).dir, "direction omise")
end)

H.case("copy est indépendante de l'original", function()
	local p = ccVec.new(1, 2, 3, 0)
	local c = ccVec.copy(p)
	c.x, c.dir = 99, 2
	H.eq(p.x, 1, "x d'origine")
	H.eq(p.dir, 0, "direction d'origine")
	H.eq(c.x, 99, "x de la copie")
end)

H.case("equals, avec et sans la direction", function()
	local a = ccVec.new(1, 2, 3, 0)
	local b = ccVec.new(1, 2, 3, 2)
	H.eq(ccVec.equals(a, b), true, "sans la direction")
	H.eq(ccVec.equals(a, b, true), false, "avec la direction")
	H.eq(ccVec.equals(a, ccVec.new(1, 2, 4, 0), true), false, "z différent")
end)

H.case("manhattan compte les mouvements, y compris en Z négatif", function()
	local origine = ccVec.new(0, 0, 0)
	-- Le cas que ccQuarry recalculait à la main, avec un
	-- `if lastZ < 0 then relativeLastZ = -lastZ end` recopié cinq fois.
	H.eq(ccVec.manhattan(origine, ccVec.new(3, 5, -12)), 20, "vers le bas")
	H.eq(ccVec.manhattan(origine, ccVec.new(3, 5, 12)), 20, "vers le haut")
	H.eq(ccVec.manhattan(ccVec.new(2, 2, 2), ccVec.new(2, 2, 2)), 0, "sur place")
end)

H.case("add et sub", function()
	local a = ccVec.new(1, 2, 3, 1)
	local sum = ccVec.add(a, ccVec.new(10, 20, 30))
	H.eq(sum.x, 11, "x") H.eq(sum.y, 22, "y") H.eq(sum.z, 33, "z")
	H.eq(sum.dir, 1, "direction de a conservée")

	local diff = ccVec.sub(ccVec.new(10, 10, 10), ccVec.new(1, 2, 3))
	H.eq(diff.x, 9, "x") H.eq(diff.y, 8, "y") H.eq(diff.z, 7, "z")
end)

H.case("tostring", function()
	H.eq(ccVec.tostring(ccVec.new(1, 2, -3)), "1 2 -3", "sans direction")
	H.eq(ccVec.tostring(ccVec.new(1, 2, -3, 2)), "1 2 -3 2", "avec direction")
end)
