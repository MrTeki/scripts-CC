-- Harnais de test minimal. Aucune dependance : Lua 5.4 standard suffit.

local H = { cases = {} }

local function show(v)
	if type(v) == "string" then return string.format("%q", v) end
	return tostring(v)
end

H.show = show

function H.case(name, fn)
	H.cases[#H.cases + 1] = { name = name, fn = fn }
end

function H.eq(actual, expected, what)
	if actual ~= expected then
		error((what or "valeur") .. " : attendu " .. show(expected)
			.. ", obtenu " .. show(actual), 2)
	end
end

function H.ok(v, what)
	if not v then
		error((what or "condition") .. " : attendu vrai, obtenu " .. show(v), 2)
	end
end

function H.isNil(v, what)
	if v ~= nil then
		error((what or "valeur") .. " : attendu nil, obtenu " .. show(v), 2)
	end
end

function H.contains(s, needle, what)
	if type(s) ~= "string" or not s:find(needle, 1, true) then
		error((what or "message") .. " : " .. show(s)
			.. " ne contient pas " .. show(needle), 2)
	end
end

function H.run()
	local passed, failed = 0, 0
	for _, c in ipairs(H.cases) do
		local ok, err = pcall(c.fn)
		if ok then
			passed = passed + 1
			print("  ok      " .. c.name)
		else
			failed = failed + 1
			print("  ECHEC   " .. c.name)
			print("          " .. tostring(err))
		end
	end
	print()
	print(string.format("%d reussis, %d echecs, %d au total", passed, failed, #H.cases))
	return failed == 0
end

return H
