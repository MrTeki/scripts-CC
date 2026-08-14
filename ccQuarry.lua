--CCQuarry by Teki
local tArgs = { ... }
local monitor = term.current()
local sizeX,sizeY = monitor.getSize()
local messages
local savedValues
local savedFile
local filePath = "ccquarry.save"

local targetX = 0
local targetY = 0
local targetZ = 0
local curX = 0
local curY = 0
local curZ = 0
local dir = 0
local lastX = 0
local lastY = 0
local lastZ = 0
local lastDir = 0
local items = 0
local alternate = false
local needFuel = false
local needClearInventory = false
local done = false
local tPause = false

local fuelSlot = 0
local itemDetail
local enderChest = 0
local enderChestPlaced = false
local relativeLastZ = 0
local relativeTargetZ = 0
local blocsLeftInCurLvl = 0

local id, msg
local reponse = ""
local side
if peripheral.find("modem") == nil then
	side = nil
else
	local sides = peripheral.getNames()
	for i=1, #sides do
		if peripheral.getType(sides[i]) == "modem" then
			side = sides[i]
		end
	end
	rednet.open(side)
end

local fuelNames = {
	"Coalfuel Can", --	1520 IndustrialCraft
	"Lava", --	1000
	"Biofuel Can", --	520 IndustrialCraft
	"Coal Coke",	-- 320 RailCraft
	"Blaze Rod", --	120
	"Scrap", --	15 IndustrialCraft
	"Wooden Scaffolding", --	15 IndustrialCraft
	"Coal", --	80
	"Charcoal", --	80
	"Peat", --	80 Forestry
	"Wood Blocks", --	15
	--"Mushroom Blocks", --	15
	-- "Wooden Tools", --	10
	"Stick", --	5
	"Sugar Cane" --	0
}

monitor.clear()
monitor.setCursorPos(1,1)

local function roundTo(num, n)
  local mult = 10^(n or 0)
  return math.floor(num * mult + 0.5) / mult
end

function pmsg(msg)
	-- messages =  curX.." "..curY.." "..curZ.." "..dir.."\n"
	-- ..lastX.." "..lastY.." "..lastZ.." "..lastDir.."\n"
	-- ..targetX.." "..targetY.." "..targetZ.."\n"
	-- ..tonumber(alternate).." "..tonumber(needFuel).." "..tonumber(needClearInventory).." "..tonumber(done)
		
	--monitor.clear()
	monitor.setCursorPos(1,13)
	monitor.clearLine()
	monitor.write(msg)
	--monitor.scroll(1)

	--textutils.slowPrint(msg, 20)
end

function Save()
	--pmsg("Save ...")
	if dir > 3 then
		dir = dir - 4
	elseif dir < 0 then
		dir = dir + 4
	end
	
	savedFile = fs.open(filePath, "w")
	savedValues = {
		[1] = curX,
		[2] = curY,
		[3] = curZ,
		[4] = dir,
		[5] = lastX,
		[6] = lastY,
		[7] = lastZ,
		[8] = lastDir,
		[9] = targetX,
		[10] = targetY,
		[11] = targetZ,
		[12] = tostring(alternate),
		[13] = tostring(needFuel),
		[14] = tostring(needClearInventory),
		[15] = tostring(done),
		[16] = tostring(enderChestPlaced)
	}
	savedFile.write(textutils.serialize(savedValues))
	savedFile.flush()
	savedFile.close()
end

function FirstMove()
	if curZ > targetZ + 1 then
		if turtle.detectDown() then
			turtle.digDown()
		end
		if turtle.down() then
			curZ = curZ - 1
			lastZ = curZ
			Save()
			if curZ > targetZ then
				if turtle.detectDown() then
					turtle.digDown()
				end
			end
		end
	end
	if curZ < targetZ - 1 then
		if turtle.detectUp() then
			turtle.digUp()
		end
		if turtle.up() then
			curZ = curZ + 1
			lastZ = curZ
			Save()
			if curZ < targetZ then
				if turtle.detectUp() then
					turtle.digUp()
				end
			end
		end
	end
end

function SetStartup()
	if fs.exists("startup") then
		fs.move("startup","startup.old")
	end
	shell.run("pastebin get 1yr45aRW startup")
end

function WaitForRefuel()
	relativeLastZ = lastZ
	if lastZ < 0 then
		relativeLastZ = -lastZ
	end
	
	pmsg("Need fuel, going Home ...")
	GoTo(0,0,0,2)
	while  turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ)*2 + targetX+targetY do
		pmsg("Waiting for fuel ...")
		local myTimer = os.startTimer(5)
		while true do
			local event, timerID = os.pullEvent()
			if (event == "timer" and timerID == myTimer) or event == "turtle_inventory" then break end
		end
		Refuel()
	end
	Unload()
end

function Refuel()
	pmsg("Refueling ...")
	SearchEnderChest()
	relativeLastZ = lastZ
	if lastZ < 0 then
		relativeLastZ = -lastZ
	end
	
	if fuelSlot ~= nil and fuelSlot ~= 0 then
		turtle.select(fuelSlot)
		if turtle.refuel(1) then
			while turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ)*2 and turtle.getItemCount(fuelSlot) > 0 do
				turtle.refuel(1)
			end
			if turtle.getItemCount(fuelSlot) == 0 then
				fuelSlot = 0
			end
		else
			fuelSlot = 0
		end
	end
	
	for i=1, 16 do
		if fuelSlot == 0 and i ~= enderChest then
			turtle.select(i)
			if turtle.refuel(1) then
				while turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ)*2 and turtle.getItemCount(i) > 0 do
					turtle.refuel(1)
					pmsg(turtle.getFuelLevel() .. " " .. (lastX+lastY+relativeLastZ)*2)
				end
				if turtle.getItemCount(i) > 0 then
					fuelSlot = i
				else
					fuelSlot = 0
				end
			end
		end
	end
	
	if fuelSlot == 0 and enderChest ~= 0 and turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ)*2 then
		fuelSlot = 1
		while turtle.getItemCount(fuelSlot) > 0 and fuelSlot < 16 do
			fuelSlot = fuelSlot+1
		end
		if turtle.getItemCount(fuelSlot) > 0 then
			Unload()
		else
			if not enderChestPlaced then
				turtle.select(enderChest)
				if curZ < 0 or curZ < targetZ then
					turtle.placeUp()
				else
					turtle.placeDown()
				end
				enderChestPlaced = true
				Save()
			end
			turtle.select(fuelSlot)
			if curZ < 0 or curZ < targetZ then
				turtle.suckUp()
			else
				turtle.suckDown()
			end
			while turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ)*2 and turtle.getItemCount(fuelSlot) > 0 do
				if turtle.refuel(1) then
					-- if curZ < 0 or curZ < targetZ then
						-- turtle.suckUp()
					-- else
						-- turtle.suckDown()
					-- end
				else
					if curZ < 0 or curZ < targetZ then
						turtle.dropUp()
					else
						turtle.dropDown()
					end
				end
			end
			turtle.select(enderChest)
			if curZ < 0 or curZ < targetZ then
				turtle.digUp()
			else
				turtle.digDown()
			end
			enderChestPlaced = false
			Save()
		end
	end
end

function CheckFuel()
	pmsg("Fuel Check ...")
	relativeLastZ = lastZ
	if lastZ < 0 then
		relativeLastZ = -lastZ
	end
	
	if turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ+1) then
		Refuel()
	end
	
	if not needFuel and turtle.getFuelLevel() <= (lastX+lastY+relativeLastZ+1) then
		needFuel = true
		WaitForRefuel()
	elseif needFuel then
		needFuel = false
		GoTo(lastX,lastY,lastZ,lastDir)
	end
end

function Unload()
	pmsg("Unloading ...")
	SearchEnderChest()
	if enderChest ~= 0 then
		if not enderChestPlaced then
			turtle.select(enderChest)
			if curZ < 0 or curZ < targetZ then
				turtle.placeUp()
			else
				turtle.placeDown()
			end
			enderChestPlaced = true
			Save()
		end
	else
		Refuel()
		GoTo(0,0,0,2)
	end
	
	for i=1, 16 do
		if i ~= fuelSlot then
			turtle.select(i)
			itemDetail = turtle.getItemDetail()
			if itemDetail ~= nil and itemDetail.name ~= "EnderStorage:enderChest" and itemDetail.name ~= "enderstorage:ender_storage" and itemDetail.name ~= "enderstorage:ender_chest" then
				if enderChest ~= 0 then
					if curZ < 0 or curZ < targetZ then
						while turtle.getItemCount(i) > 0 and not turtle.dropUp() do
						end
					else
						while turtle.getItemCount(i) > 0 and not turtle.dropDown() do
						end
					end
				else
					while turtle.getItemCount(i) > 0 and not turtle.drop() do
					end
				end
			end
		end
	end
	
	if enderChest ~= 0 then
		turtle.select(enderChest)
		if curZ < 0 or curZ < targetZ then
			turtle.digUp()
		else
			turtle.digDown()
		end
		enderChestPlaced = false
		Save()
	end
	
	items = 0
	for i=1, 16 do
		if turtle.getItemCount(i) > 0 then
			items = items + 1
		end
	end
	
	if items > 2 then
		needClearInventory = true
	else
		needClearInventory = false
		
		if not done then
			CheckFuel()
			GoTo(lastX,lastY,lastZ,lastDir)
		else
			GoTo(0,0,0,0)
		end
	end
end

function CheckInventory()
	pmsg("Inventory Check ...")
	items = 0
	for i=1, 16 do
		if turtle.getItemCount(i) > 0 then
			items = items + 1
		end
	end
	
	if items > 14 or needClearInventory then
		needClearInventory = true
		while needClearInventory do
			Unload()
		end
	end
end

function SearchEnderChest()
	if enderChestPlaced then
		for i=1, 16 do
			turtle.select(i)
			if turtle.getItemCount(i) == 0 then
				enderChest = i
			end
		end
	else
		for i=1, 16 do
			turtle.select(i)
			itemDetail = turtle.getItemDetail()
			if itemDetail ~= nil then
				if itemDetail.name == "EnderStorage:enderChest" then
					enderChest = i
				elseif itemDetail.name == "enderstorage:ender_storage" then
					enderChest = i
				elseif itemDetail.name == "enderstorage:ender_chest" then
					enderChest = i
				end
			end
		end
	end
end

function tUp()
	if turtle.up() then
		curZ = curZ + 1
		Save()
	else
		while turtle.detectUp() and turtle.digUp() do
		end
		if not turtle.detectUp() then
			turtle.attackUp()
		end
	end
end

function tDown()
	if turtle.down() then
		curZ = curZ - 1
		Save()
	else
		while turtle.detectDown() and turtle.digDown() do
		end
		if not turtle.detectDown() then
			turtle.attackDown()
		end
	end
end

function tForward(toX, toY)
	if curZ < 0 or curZ < targetZ then
		while turtle.detectUp() and turtle.digUp() do
		end
	end
	if curZ > targetZ or curZ > 0 then
		while turtle.detectDown() and turtle.digDown() do
		end
	end
	if (curX == 0 and curY == 0 and curZ == 0) then
	else
		if (dir == 0 and curX < toX) or (dir == 2 and curX > 0) or (dir == 1 and curY < toY) or (dir == 3 and curY > 0) then
			while turtle.detect() and turtle.dig() do
			end
		end
	end
	
	if dir == 0 then
		if curX < toX then
			if turtle.forward() then
				curX = curX + 1
				Save()
			elseif not turtle.detect() then
				turtle.attack()
			end
		else
			if curY < toY then
				turtle.turnRight()
				dir = 1
				Save()
			else
				turtle.turnLeft()
				dir = 3
				Save()
			end
		end
	elseif dir == 1 then
		if curY < toY and curX == toX then
			if turtle.forward() then
				curY = curY + 1
				Save()
			elseif not turtle.detect() then
				turtle.attack()
			end
		else
			if curX < toX then
				turtle.turnLeft()
				dir = 0
				Save()
			else
				turtle.turnRight()
				dir = 2
				Save()
			end
		end
	elseif dir == 2 then
		if curX > toX and curY == toY then
			if turtle.forward() then
				curX = curX - 1
				Save()
			elseif not turtle.detect() then
				turtle.attack()
			end
		else
			if curY < toY then
				turtle.turnLeft()
				dir = 1
				Save()
			else
				turtle.turnRight()
				dir = 3
				Save()
			end
		end
	elseif dir == 3 then
		if curY > toY then
			if turtle.forward() then
				curY = curY - 1
				Save()
			elseif not turtle.detect() then
				turtle.attack()
			end
		else
			if curX < toX then
				turtle.turnRight()
				dir = 0
				Save()
			else
				turtle.turnLeft()
				dir = 2
				Save()
			end
		end
	end
end

function GoUp(toZ)
	toZ = tonumber(toZ)
	while curZ < toZ do
		tUp()
	end
end

function GoDown(toZ)
	toZ = tonumber(toZ)
	while curZ > toZ do
		tDown()
	end
end

function GoXY(toX, toY)
	toX = tonumber(toX)
	toY = tonumber(toY)
	while curX ~= toX or curY ~= toY do
		tForward(toX, toY)
	end
end

function GoTo(toX, toY, toZ, toDir)
	toX = tonumber(toX)
	toY = tonumber(toY)
	toZ = tonumber(toZ)
	toDir = tonumber(toDir)
	
	if targetZ > 0 then
		GoDown(toZ)
		GoXY(toX,toY)
		GoUp(toZ)
	else
		GoUp(toZ)
		GoXY(toX,toY)
		GoDown(toZ)
	end
	
	while dir ~= toDir do
		if not tPause then 
			if dir > toDir then
				if dir - toDir >= 2 then
					turtle.turnRight()
					dir = dir + 1
				else
					turtle.turnLeft()
					dir = dir - 1
				end
			elseif dir < toDir then
				if toDir - dir >= 2 then
					turtle.turnLeft()
					dir = dir - 1
				else
					turtle.turnRight()
					dir = dir + 1
				end
			end
			Save()
		else
			sleep(0)
		end
	end
end

function Forwards()
	if curZ < 0 or curZ < targetZ then
		if turtle.detectUp() then
			while turtle.detectUp() and turtle.digUp() do
			end
		end
	end
	if curZ > targetZ or curZ > 0 then
		if turtle.detectDown() then
			while turtle.detectDown() and turtle.digDown() do
			end
		end
	end
	if turtle.detect() then
		while turtle.detect() and turtle.dig() do
		end
	end
	if turtle.forward() then
		if dir == 0 then
			curX = curX + 1
		elseif dir == 1 then
			curY = curY + 1
		elseif dir == 2 then
			curX = curX -1
		elseif dir == 3 then
			curY = curY - 1
		end
		lastX = curX
		lastY = curY
		Save()
		if curZ < 0 or curZ < targetZ then
			if turtle.detectUp() then
				while turtle.detectUp() and turtle.digUp() do
				end
			end
		end
		if curZ > targetZ or curZ > 0 then
			if turtle.detectDown() then
				while turtle.detectDown() and turtle.digDown() do
				end
			end
		end
	else
		if not turtle.detect() then
			turtle.attack()
			turtle.attackUp()
			-- Forwards()
		else
			done = true
			GoTo(0,0,0,2)
		end
	end
end

function Downwards()
	if curZ > targetZ + 1 and not done then
		turtle.turnLeft()
		dir = dir - 1
		lastDir = dir
		Save()
		turtle.turnLeft()
		lastDir = dir
		dir = dir - 1
		Save()
		if turtle.down() then
			curZ = curZ - 1
			lastZ = curZ
			Save()
			alternate = not alternate
			if curZ > targetZ then
				if turtle.detectDown() then
					turtle.digDown()
				end
				if turtle.down() then
					curZ = curZ -1
					lastZ = curZ
					Save()
					if curZ > targetZ + 1 then
						if turtle.detectDown() then
							turtle.digDown()
						end
						if turtle.down() then
							curZ = curZ -1
							lastZ = curZ
							Save()
							if turtle.detectDown() then
								turtle.digDown()
							end
						end
					end
				else
					done = true
				end
			end
		else
			if not turtle.detectDown() then
				turtle.attackDown()
				-- Downwards()
			else
				done = true
			end
		end
	else
		done = true
	end
end

function Upwards()
	if curZ < targetZ - 1 and not done then
		turtle.turnLeft()
		dir = dir + 1
		lastDir = dir
		Save()
		turtle.turnLeft()
		lastDir = dir
		dir = dir + 1
		Save()
		if turtle.up() then
			curZ = curZ + 1
			lastZ = curZ
			Save()
			alternate = not alternate
			if curZ < targetZ then
				if turtle.detectUp() then
					while turtle.detectUp() and turtle.digUp() do
					end
				end
				if turtle.up() then
					curZ = curZ + 1
					lastZ = curZ
					Save()
					if curZ < targetZ - 1 then
						if turtle.detectUp() then
							while turtle.detectUp() and turtle.digUp() do
							end
						end
						if turtle.up() then
							curZ = curZ + 1
							lastZ = curZ
							Save()
							if turtle.detectUp() then
								while turtle.detectUp() and turtle.digUp() do
								end
							end
						end
					end
				end
			end
		else
			if not turtle.detectUp() then
				turtle.attackUp()
				-- Upwards()
			else
				done = true
				GoTo(0,0,0,2)
			end
		end
	else
		done = true
		GoTo(0,0,0,2)
	end
end

function Move()
	if dir == 0 then
		if curX < targetX then
			Forwards()
		elseif not alternate and curY < targetY then
			turtle.turnRight()
			dir = 1
		elseif alternate and curY > 0 then
			turtle.turnLeft()
			dir = 3
		elseif targetZ < 0 then
			Downwards()
		else
			Upwards()
		end
	elseif dir == 1 then
		if curY < targetY then
			Forwards()
			if curX == 0 then
				turtle.turnLeft()
				dir = 0
			elseif curX == targetX then
				turtle.turnRight()
				dir = 2
			end
		end
	elseif dir == 2 then
		if curX > 0 then
			Forwards()
		elseif not alternate and curY < targetY then
			turtle.turnLeft()
			dir = 1
		elseif alternate and curY > 0 then
			turtle.turnRight()
			dir = 3
		elseif targetZ < 0 then
			Downwards()
		else
			Upwards()
		end
	elseif dir == 3 then
		if curY > 0 then
			Forwards()
			if curX == targetX then
				turtle.turnLeft()
				dir = 2
			elseif curX == 0 then
				turtle.turnRight()
				dir = 0
			end
		end
	end
	
	lastDir = dir
	Save()
end

if #tArgs == 1 then
	if tArgs[1] == "del" then
		fs.delete(filePath)
		return 0
	else
		targetZ = tonumber(tArgs[1])
		if targetZ < 0 then
			targetZ = (targetZ+1) * -1
			targetX = targetZ
			targetY = targetZ
		else
			targetZ = (targetZ-1) * -1
			targetX = targetZ * -1
			targetY = targetZ * -1
		end
		SetStartup()
		CheckFuel()
		FirstMove()
	end
elseif #tArgs == 3 then
	targetX = tonumber(tArgs[1])-1
	targetY = tonumber(tArgs[2])-1
	targetZ = tonumber(tArgs[3])
	if targetZ < 0 then
		targetZ = (targetZ+1) * -1
	else
		targetZ = (targetZ-1) * -1
	end
	SetStartup()
	CheckFuel()
	FirstMove()
else
	if fs.exists(filePath) and fs.getSize(filePath) > 0 and #tArgs == 0 then
		savedFile = fs.open(filePath, "r")
		savedValues = textutils.unserialize(savedFile.readAll())
		if savedValues[15] == "false" or (savedValues[15] == "true" and tonumber(savedValues[1])+tonumber(savedValues[2])-tonumber(savedValues[3]) ~= 0) then
			pmsg("Trying to restart ...")
			curX = tonumber(savedValues[1])
			curY = tonumber(savedValues[2])
			curZ = tonumber(savedValues[3])
			dir = tonumber(savedValues[4])
			lastX = tonumber(savedValues[5])
			lastY = tonumber(savedValues[6])
			lastZ = tonumber(savedValues[7])
			lastDir = tonumber(savedValues[8])
			targetX = tonumber(savedValues[9])
			targetY = tonumber(savedValues[10])
			targetZ = tonumber(savedValues[11])
			alternate = savedValues[12] == "true"
			needFuel = savedValues[13] == "true"
			needClearInventory = savedValues[14] == "true"
			done = savedValues[15] == "true"
			enderChestPlaced = savedValues[16] == "true"
		else
			savedValues = nil
		end
		savedFile.close()
	end
	if savedValues == nil then
		print("help: ccquarry <1> <2> <3>")
		print("      <1> : X Y and Z")
		print("or:")
		print("      <1> : X")
		print("      <2> : Y")
		print("      <3> : Z")
		return 0
	end
end

function draw()
	relativeLastZ = lastZ
	if lastZ < 0 then
		relativeLastZ = -lastZ
	end
	relativeTargetZ = targetZ
	if targetZ < 0 then
		relativeTargetZ = -targetZ
	end
	if alternate then
		if dir == 0 or (dir == 3 and (lastY+1)/2 ~= roundTo(lastY/2)) then
			blocsLeftInCurLvl = (((targetX+1)-(lastX+1)) + ((targetX+1)*(lastY)))
		elseif dir == 2 or (dir == 3 and (lastY+1)/2 == roundTo(lastY/2)) then
			blocsLeftInCurLvl = ((lastX) + ((targetX+1)*(lastY)))
		end
	else
		if dir == 0 or (dir == 1 and (lastY+1)/2 ~= roundTo(lastY/2)) then
			blocsLeftInCurLvl = (((targetX+1)-(lastX+1)) + ((targetX+1)*((targetY+1)-(lastY+1))))
		elseif dir == 2 or (dir == 1 and (lastY+1)/2 == roundTo(lastY/2)) then
			blocsLeftInCurLvl = ((lastX) + ((targetX+1)*((targetY+1)-(lastY+1))))
		end
	end
	
	if (relativeTargetZ+1) - (relativeLastZ-1) > 2 then
		blocsLeftInCurLvl = blocsLeftInCurLvl * 3
	elseif (relativeTargetZ+1) - (relativeLastZ+1) > 1 then
		blocsLeftInCurLvl = blocsLeftInCurLvl * 2
	end
	
	monitor.setBackgroundColour(colors.black)
	monitor.setTextColor(colors.white)
	
	-- Blocks Left
	monitor.setCursorPos(1,1)
	monitor.clearLine()
	monitor.write("Blocks left  : " .. (((targetX+1) * (targetY+1) * (relativeTargetZ+1)) - ((targetX+1) * (targetY+1) * (relativeLastZ+2)) + blocsLeftInCurLvl))
	-- Moves Left
	monitor.setCursorPos(1,2)
	monitor.clearLine()
	monitor.write("Moves left  : " .. (((targetX+1) * (targetY+1) * (relativeTargetZ+1)) - ((targetX+1) * (targetY+1) * (relativeLastZ+2)) + blocsLeftInCurLvl)/3)
	-- Fuel Left
	monitor.setCursorPos(1,3)
	monitor.clearLine()
	monitor.write("Fuel left  : " .. turtle.getFuelLevel())
	
	-- Refuel button
	monitor.setBackgroundColour(colors.white)
	monitor.setTextColor(colors.black)
	monitor.setCursorPos(sizeX-5, 1)
	monitor.write("R")
	monitor.setBackgroundColour(colors.black)
	monitor.setTextColor(colors.white)
	monitor.setCursorPos(sizeX-4, 1)
	monitor.write("EFUEL")
	
	-- Pause Button
	if tPause then
		monitor.setCursorPos(sizeX-6, 2)
		monitor.write("UN")
	end
	monitor.setBackgroundColour(colors.white)
	monitor.setTextColor(colors.black)
	monitor.setCursorPos(sizeX-4, 2)
	monitor.write("P")
	monitor.setBackgroundColour(colors.black)
	monitor.setTextColor(colors.white)
	monitor.setCursorPos(sizeX-3, 2)
	monitor.write("AUSE")
	
	-- Coords
	monitor.setCursorPos(1,4)
	monitor.clearLine()
	monitor.write("Target : " .. targetX.." "..targetY.." "..targetZ)
	monitor.setCursorPos(1,5)
	monitor.clearLine()
	monitor.write("Current : " .. curX.." "..curY.." "..curZ.." "..dir)
	monitor.setCursorPos(1,6)
	monitor.clearLine()
	monitor.write("Last : " .. lastX.." "..lastY.." "..lastZ.." "..lastDir)
	
	-- Fuel Slot
	monitor.setCursorPos(1,7)
	monitor.clearLine()
	local itemDetails = ""
	if fuelSlot ~= 0 then turtle.getItemDetail(fuelSlot) end
	monitor.write("Fuel Slot : " .. fuelSlot .. " " .. (itemDetails))
	
	-- Ender Slot
	monitor.setCursorPos(1,8)
	monitor.clearLine()
	monitor.write("EnderChest Slot : " .. enderChest)
	
	sleep(0.5)
end

draw()

function catchEvents()
	if side ~= nil then
		parallel.waitForAny(catchTermEvents, catchRednetEvents)
	else
		catchTermEvents()
	end
end

function catchTermEvents()
	--local event, side, xPos, yPos = os.pullEvent("mouse_click")
	
	while true do
		local event, side, xPos, yPos = os.pullEvent()
		if event == "char" then
			if side == "R" or side == "r" then
				Refuel()
			elseif side == "P" or side == "p"then
				tPause = not tPause
			end
			break
		end
		if event == "mouse_click" then
			if (xPos >= sizeX-5 and xPos <= sizeX) and (yPos == 1) then
				Refuel()
			elseif (xPos >= sizeX-6 and xPos <= sizeX) and (yPos == 2) then
				tPause = not tPause
			end
			break
		end
	end
end

function catchRednetEvents()
    id, msg = rednet.receive("CCQuarryPortable", 5)
	
	if msg == "getAll" then
		reponse = {
			[1] = curX,
			[2] = curY,
			[3] = curZ,
			[4] = dir,
			[5] = lastX,
			[6] = lastY,
			[7] = lastZ,
			[8] = lastDir,
			[9] = targetX,
			[10] = targetY,
			[11] = targetZ,
			[12] = tostring(alternate),
			[13] = tostring(needFuel),
			[14] = tostring(needClearInventory),
			[15] = tostring(done),
			[16] = tostring(enderChestPlaced)
		}
		rednet.send(id, reponse, "CCQuarry")
	end
end

function mainLoop()
	while true do
		sleep(0)
		if not tPause then
			CheckInventory()
			CheckFuel()
			if not needFuel and not needClearInventory and not done then
				Move()
			end
			
			if done and curX == 0 and curY == 0 and curZ == 0 then
				Unload()
				pmsg("Done !")
				fs.delete(filePath)
				fs.delete("startup")
				if fs.exists("startup.old") then
					fs.move("startup.old","startup")
				end
				return 0
			elseif done and (curX ~= 0 or curY ~= 0 or curZ ~= 0) then
				GoTo(0,0,0,2)
			end
		end
	end
end

function drawLoop()
	while not done do
		parallel.waitForAny(catchEvents, draw)
	end
end

SearchEnderChest()
parallel.waitForAll(mainLoop, drawLoop)