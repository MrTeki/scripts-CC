local tArgs = { ... }
local monitor = term.current()
local sizeX,sizeY = monitor.getSize()

local makeCharcoal = false
local fuelPriority = {
	"minecraft:stick",
	"minecraft:charcoal",
	"minecraft:oak_log",
}
local origin = {X = 0, Y = 0, Z = 0, direction = 0}
local curPosition = {
    X = 0,
    Y = 0,
    Z = 0,
    direction = 0
}
local lastPosition = {
    X = 0,
    Y = 0,
    Z = 0,
    direction = 0
}
local targetPosition = {
    X = 0,
    Y = 0,
    Z = 0,
    direction = nil
}
local chestSide = nil
local furnaceSide = nil
local currentState = "setup"
local lastPositionStack = {}

-- Logging

local lastMsg = ""
local lastMsgCount = 0
local function pmsg(msg)
	if lastMsg == msg then
		lastMsgCount = lastMsgCount + 1
		msg = msg .. " " .. lastMsgCount
	else
		lastMsg = msg
		lastMsgCount = 0
		monitor.scroll(1)
	end
	monitor.setCursorPos(1,13)
	monitor.clearLine()
	monitor.write(msg)
end

-- Utility

local function indexOf(array, needle)
    for index, value in ipairs(array) do
        if value == needle then
            return index
        end
    end
	return false
end

local function copyPosition(position)
    local newPosition = {}
	newPosition.X = position.X
	newPosition.Y = position.Y
	newPosition.Z = position.Z
	newPosition.direction = position.direction
	return newPosition
end

local function arePositionEquals(pos1, pos2, checkDirection)
	if pos1.X == pos2.X and pos1.Y == pos2.Y and pos1.Z == pos2.Z then
		if checkDirection then
			return pos1.direction == pos2.direction
		else
			return true
		end
	end
	return false
end

-- save / Load

local filePath = "ccchop.save"
local function save()
	if currentState == "chopping" then
		lastPositionStack[#lastPositionStack+1] = copyPosition(curPosition)
		pmsg("new stack")
		-- lastPositionStack[#lastPositionStack].direction = (curPosition.direction + 2) % 4
	elseif currentState == "going_back" and #lastPositionStack > 1 then
		if curPosition.X == lastPositionStack[#lastPositionStack].X and curPosition.Y == lastPositionStack[#lastPositionStack].Y and curPosition.Z == lastPositionStack[#lastPositionStack].Z then
			lastPositionStack[#lastPositionStack] = nil
			pmsg("stack removed")
		end
	end
	-- disable save
	if true then
		return nil
	end
	if curPosition.direction > 3 then
		curPosition.direction = curPosition.direction - 4
	elseif curPosition.direction < 0 then
		curPosition.direction = curPosition.direction + 4
	end
	local savedFile = fs.open(filePath, "w")
	local savedValues = {
		[1] = curPosition,
		[2] = lastPosition,
		[3] = targetPosition,
		[4] = chestSide,
		[5] = furnaceSide,
		[6] = currentState,
		[7] = lastPositionStack,
	}
	savedFile.write(textutils.serialize(savedValues))
	savedFile.flush()
	savedFile.close()
end
local function load()
	if fs.exists(filePath) and fs.getSize(filePath) > 0 and #tArgs == 0 then
		local savedFile = fs.open(filePath, "r")
		local savedValues = textutils.unserialize(savedFile.readAll())

        curPosition = savedValues[1]
        lastPosition = savedValues[2]
        targetPosition = savedValues[3]
        chestSide = savedValues[4]
        furnaceSide = savedValues[5]
        currentState = savedValues[6]
		lastPositionStack = savedValues[7]

		savedFile.close()
    end
end
load()
save()

-- Setup

local function findPeripherals()
	chestSide = nil
	furnaceSide = nil
	local sides = peripheral.getNames()
	for i=1, #sides do
		if peripheral.getType(sides[i]) == "minecraft:chest" then
			chestSide = sides[i]
        elseif peripheral.getType(sides[i]) == "minecraft:furnace" then
            furnaceSide = sides[i]
		end
	end
	return chestSide ~= nil and furnaceSide ~= nil
end

-- Block/Item Check

local function isSapling(itemName)
    return string.match(itemName, "_sapling$") ~= nil
end

local function isLog(itemName)
    return string.match(itemName, "_log$") ~= nil
end

local function isLeaves(itemName)
    return string.match(itemName, "_leaves$") ~= nil
end

local function shouldMineBlock(direction, allowLeaves)
	allowLeaves = (allowLeaves == nil) or allowLeaves
	local turtleInspect = turtle.inspect
	if direction == "up" then
		turtleInspect = turtle.inspectUp
	elseif direction == "down" then
		turtleInspect = turtle.inspectDown
	end
	local success, frontItem = turtleInspect()
	if success and (isLog(frontItem.name) or (allowLeaves and isLeaves(frontItem.name))) then
		return true
	end
	return false
end

local function suckItems()
	if not turtle.detect() then
		while turtle.suck() do
		end
	end
	if not turtle.detectUp() then
		while turtle.suckUp() do
		end
	end
	if not turtle.detectDown() then
		while turtle.suckDown() do
		end
	end
end

-- Movement

local function moveUp()
	suckItems()
	if turtle.up() then
		curPosition.Z = curPosition.Z + 1
		save()
        return true
	else
		while shouldMineBlock("up") and turtle.digUp() do
		end
		if not turtle.detectUp() then
			turtle.attackUp()
		end
        return false
	end
end

local function moveDown()
	suckItems()
	if turtle.down() then
		curPosition.Z = curPosition.Z - 1
		save()
        return true
	else
		while shouldMineBlock("down") and turtle.digDown() do
		end
		if not turtle.detectDown() then
			turtle.attackDown()
		end
        return false
	end
end

-- Fonction pour avancer et gérer les obstacles
local function moveForward(curPosition, axis)
	suckItems()
	if turtle.forward() then
		curPosition[axis] = curPosition[axis] + ((curPosition.direction == 0 or curPosition.direction == 1) and 1 or -1)
		save()
        return true
	else
		while shouldMineBlock("front") and turtle.dig() do
		end
		if not turtle.detect() then
			turtle.attack()
		end
        return false
	end
end
-- Fonction pour tourner à droite
local function turnRight()
	suckItems()
	if turtle.turnRight() then
		curPosition.direction = (curPosition.direction + 1) % 4
		save()
	end
end
-- Fonction pour tourner à gauche
local function turnLeft()
	suckItems()
	if turtle.turnLeft() then
		curPosition.direction = (curPosition.direction + 3) % 4
		save()
	end
end
-- Fonction pour faire demi-tour
local function turnAround()
	turnLeft()
	turnLeft()
end
local function moveToTarget()
	-- Si on doit monter on commence par monter
	if curPosition.Z < targetPosition.Z then
		return moveUp()
	-- Vérifiez la direction actuelle de la turtle
	elseif curPosition.X ~= targetPosition.X or curPosition.Y ~= targetPosition.Y then
		if curPosition.direction == 0 then -- Nord
			if curPosition.X < targetPosition.X then
				return moveForward(curPosition, "X")
			elseif curPosition.X > targetPosition.X then
				turnAround()
				return moveForward(curPosition, "X")
			elseif curPosition.Y < targetPosition.Y then
				turnRight()
				return moveForward(curPosition, "Y")
			elseif curPosition.Y > targetPosition.Y then
				turnLeft()
				return moveForward(curPosition, "Y")
			end
		elseif curPosition.direction == 1 then -- Est
			if curPosition.Y < targetPosition.Y then
				return moveForward(curPosition, "Y")
			elseif curPosition.Y > targetPosition.Y then
				turnAround()
				return moveForward(curPosition, "Y")
			elseif curPosition.X > targetPosition.X then
				turnRight()
				return moveForward(curPosition, "X")
			elseif curPosition.X < targetPosition.X then
				turnLeft()
				moveForward(curPosition, "X")
			end
		elseif curPosition.direction == 2 then -- Sud
			if curPosition.X > targetPosition.X then
				return moveForward(curPosition, "X")
			elseif curPosition.X < targetPosition.X then
				turnAround()
				return moveForward(curPosition, "X")
			elseif curPosition.Y > targetPosition.Y then
				turnRight()
				return moveForward(curPosition, "Y")
			elseif curPosition.Y < targetPosition.Y then
				turnLeft()
				return moveForward(curPosition, "Y")
			end
		elseif curPosition.direction == 3 then -- Ouest
			if curPosition.Y > targetPosition.Y then
				return moveForward(curPosition, "Y")
			elseif curPosition.Y < targetPosition.Y then
				turnAround()
				return moveForward(curPosition, "Y")
			elseif curPosition.X < targetPosition.X then
				turnRight()
				return moveForward(curPosition, "X")
			elseif curPosition.X > targetPosition.X then
				turnLeft()
				return moveForward(curPosition, "X")
			end
		end
	-- Si on doit descendre on fini par descendre
	elseif curPosition.Z > targetPosition.Z then
		return moveDown()
	-- Enfin on aligne la direction
	elseif targetPosition.direction ~= nil and curPosition.direction > targetPosition.direction then
		turnLeft()
	elseif targetPosition.direction ~= nil and curPosition.direction < targetPosition.direction then
		turnRight()
	else
		save()
	end
end

-- Inventory

local function findItemSlotInTurtleInventory(itemName)
	for slot=1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and itemDetail.name == itemName then
			return true, slot
		end
	end
	return false, nil
end

local function findItemSlotInInventory(inventory, itemName, stackMustHaveFreeSpace)
	-- TODO : use a callback to validate itemName
	-- if is string use a default callback (anonymous function)
	-- if is function use it as callback (and validator(itemDetail.name))
	local size = inventory.size()
	for slot=1, size do
		local itemDetail = inventory.getItemDetail(slot)
		if itemDetail ~= nil and itemDetail.name == itemName and (not stackMustHaveFreeSpace or itemDetail.count < itemDetail.maxCount) then
			return slot, itemDetail
		end
	end
	return nil
end

local function findEmptySlot(itemList, size)
	for slot=1, size do
		if not itemList[slot] then
			return true, slot
		end
	end
	return false, nil
end

local function clearFurnaceOutput()
	if findPeripherals() then
		local furnace = peripheral.wrap(furnaceSide)
		local chest = peripheral.wrap(chestSide)
		local outputSlotItemDetail = furnace.getItemDetail(3)
		if outputSlotItemDetail ~= nil and outputSlotItemDetail.count > 0 then
			local itemName = outputSlotItemDetail.name
			local chestSlot, chestItemDetail = findItemSlotInInventory(chest, itemName, true)
			while (chestSlot ~= nil and chestItemDetail ~= nil) and outputSlotItemDetail ~= nil and outputSlotItemDetail.count > 0 do
				furnace.pushItems(chestSide, 3, chestItemDetail.maxCount - chestItemDetail.count, chestSlot)
				outputSlotItemDetail = furnace.getItemDetail(3)
				chestSlot, chestItemDetail = findItemSlotInInventory(chest, itemName, true)
			end
			if chestSlot == nil and outputSlotItemDetail ~= nil and outputSlotItemDetail.count > 0 then
				local success, chestSlot = findEmptySlot(chest.list(), chest.size())
				if success then
					furnace.pushItems(chestSide, 3, 64, chestSlot)
				end
			end
			outputSlotItemDetail = furnace.getItemDetail(3)
		end
		return outputSlotItemDetail == nil or outputSlotItemDetail.count > 0
	end
	return false
end

local function fillFurnaceInput()
	if findPeripherals() then
		local furnace = peripheral.wrap(furnaceSide)
		local chest = peripheral.wrap(chestSide)

		local furnaceItemInput = furnace.getItemDetail(1)
		local chestSlot, chestItemDetail = findItemSlotInInventory(chest, "minecraft:oak_log", false)
		while chestSlot ~= nil and chestItemDetail ~= nil and (furnaceItemInput== nil or furnaceItemInput.count < furnaceItemInput.maxCount) do
			furnaceItemInput = furnace.getItemDetail(1)
			chestSlot, chestItemDetail = findItemSlotInInventory(chest, "minecraft:oak_log", false)
			if chestSlot ~= nil and chestItemDetail ~= nil then
				chest.pushItems(furnaceSide, chestSlot)
			end
		end

		local furnaceFuelInput = furnace.getItemDetail(2)
		local fuelItem = "minecraft:oak_log"
		if furnaceFuelInput ~= nil and furnaceFuelInput.name ~= nil then
			fuelItem = furnaceFuelInput.name
		end
		chestSlot, chestItemDetail = findItemSlotInInventory(chest, fuelItem, false)
		while chestSlot ~= nil and chestItemDetail ~= nil and (furnaceFuelInput == nil or furnaceFuelInput.count < furnaceFuelInput.maxCount) do
			furnaceFuelInput = furnace.getItemDetail(2)
			chestSlot, chestItemDetail = findItemSlotInInventory(chest, fuelItem, false)
			if chestSlot ~= nil and chestItemDetail ~= nil then
				chest.pushItems(furnaceSide, chestSlot)
			end
		end
		return true
	end
	return false
end

-- turtle must be facing, below or over the chest
local function takeItemInChest(itemName, count)
	local turtleSuck = turtle.suck
	local oldChestSide = chestSide
	if chestSide == "right" then
		turnRight()
		chestSide = "front"
	elseif chestSide == "left" then
		turnLeft()
		chestSide = "front"
	elseif chestSide == "back" then
		turnAround()
		chestSide = "front"
	elseif chestSide == "top" then
		turtleSuck = turtle.suckUp
	elseif chestSide == "down" then
		turtleSuck = turtle.suckDown
	end

	local returnValue = false
	local chest = peripheral.wrap(chestSide)
	local chestItemSlot, chestItemDetail = findItemSlotInInventory(chest, itemName, false)
	if chestItemSlot ~= nil and chestItemDetail ~= nil then
		if chestItemSlot == 1 then
			turtleSuck(count)
			returnValue = true
		else
			-- find empty slot
			local success, chestEmptySlot = findEmptySlot(chest.list(), chest.size())
			if success then
				if chestEmptySlot == 1 then
					-- move fuitemel to slot 1
					chest.pushItems(chestSide, chestItemSlot, chestItemDetail.count, 1)
					turtleSuck(count)
					returnValue = true
				else
					-- move slot 1 to empty slot
					chest.pushItems(chestSide, 1, 64, chestEmptySlot)
					-- move item to slot 1
					chest.pushItems(chestSide, chestItemSlot, chestItemDetail.count, 1)
					turtleSuck(count)
					returnValue = true
				end
			end
		end
	end

	if oldChestSide == "right" then
		turnLeft()
	elseif oldChestSide == "left" then
		turnRight()
	elseif oldChestSide == "back" then
		turnAround()
	end
	chestSide = oldChestSide

	return returnValue
end

local function clearTurtleInventory()
	local needEmptying = false
	local fuelItem = nil
	for slot=1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and not (indexOf(fuelPriority, itemDetail.name) or isSapling(itemDetail.name) or itemDetail.name == "minecraft:bone_meal") then
			needEmptying = true
			break
		elseif itemDetail ~= nil and fuelItem == nil and indexOf(fuelPriority, itemDetail.name) then
			fuelItem = fuelPriority[indexOf(fuelPriority, itemDetail.name)]
		elseif itemDetail ~= nil and fuelItem ~= nil and indexOf(fuelPriority, itemDetail.name) and fuelItem ~= fuelPriority[indexOf(fuelPriority, itemDetail.name)] then
			needEmptying = true
			break
		end
	end
	if not needEmptying then
		return true
	end
	if findPeripherals() then
		local turtleDrop = turtle.drop
		local oldChestSide = chestSide
		if chestSide == "right" then
			turnRight()
			chestSide = "front"
		elseif chestSide == "left" then
			turnLeft()
			chestSide = "front"
		elseif chestSide == "back" then
			turnAround()
			chestSide = "front"
		elseif chestSide == "top" then
			turtleDrop = turtle.dropUp
		elseif chestSide == "down" then
			turtleDrop = turtle.dropDown
		end
		local chest = peripheral.wrap(chestSide)
		local fuelSlot = {slot = 0, count = 0, maxCount = 64, name = nil}
		local saplingSlot = {slot = 0, count = 0, maxCount = 64, name = nil}
		local fertilizerSlot = {slot = 0, count = 0, maxCount = 64, name = nil}
		for slot=1, 16 do
			if not findEmptySlot(chest.list(), chest.size()) then
				if oldChestSide == "right" then
					turnLeft()
				elseif oldChestSide == "left" then
					turnRight()
				elseif oldChestSide == "back" then
					turnAround()
				end
				return false
			end
			local itemDetail = turtle.getItemDetail(slot, true)
			if itemDetail ~= nil then
				-- c'est un log
				if isLog(itemDetail.name) then
					turtle.select(slot)
					turtleDrop()
				-- c'est un fuel et je n'en ai pas
				elseif fuelSlot.name == nil and indexOf(fuelPriority, itemDetail.name) then
					for fuelIndex = 1, #fuelPriority do
						if itemDetail.name == fuelPriority[fuelIndex] then
							fuelSlot.name = itemDetail.name
							fuelSlot.count = itemDetail.count
							fuelSlot.slot = slot
						end
					end
				-- c'est mon fuel et j'ai de la place
				elseif itemDetail.name == fuelSlot.name and fuelSlot.count < fuelSlot.maxCount then
					turtle.select(slot)
					turtle.transferTo(fuelSlot.slot, fuelSlot.maxCount - fuelSlot.count)
					local fuelDetail = turtle.getItemDetail(fuelSlot.slot, true)
					if fuelDetail ~= nil then
						fuelSlot.count = fuelDetail.count
					end
					-- c'est mon fuel et j'avais de la place mais je n'en ai plus
					if itemDetail.count > (fuelSlot.maxCount - fuelSlot.count) then
						turtleDrop()
					end
				-- c'est un sapling et je n'en ai pas
				elseif saplingSlot.name == nil and isSapling(itemDetail.name) then
					saplingSlot.name = itemDetail.name
					saplingSlot.count = itemDetail.count
					saplingSlot.slot = slot
				-- c'est mon sapling et j'ai de la place
				elseif itemDetail.name == saplingSlot.name and saplingSlot.count < saplingSlot.maxCount then
					turtle.select(slot)
					turtle.transferTo(saplingSlot.slot, saplingSlot.maxCount - saplingSlot.count)
					local saplingDetail = turtle.getItemDetail(saplingSlot.slot, true)
					if saplingDetail ~= nil then
						saplingSlot.count = saplingDetail.count
					end
					-- c'est mon sapling et j'avais de la place mais je n'en ai plus
					if itemDetail.count > (saplingSlot.maxCount - saplingSlot.count) then
						turtleDrop()
					end
				-- c'est un fertilizer et je n'en ai pas
				elseif fertilizerSlot.name == nil and itemDetail.name == "minecraft:bone_meal" then
					fertilizerSlot.name = itemDetail.name
					fertilizerSlot.count = itemDetail.count
					fertilizerSlot.slot = slot
				-- c'est mon sapling et j'ai de la place
				elseif itemDetail.name == fertilizerSlot.name and fertilizerSlot.count < fertilizerSlot.maxCount then
					turtle.select(slot)
					turtle.transferTo(fertilizerSlot.slot, fertilizerSlot.maxCount - fertilizerSlot.count)
					local fertilizerDetail = turtle.getItemDetail(fertilizerSlot.slot, true)
					if fertilizerDetail ~= nil then
						fertilizerSlot.count = fertilizerDetail.count
					end
					-- c'est mon sapling et j'avais de la place mais je n'en ai plus
					if itemDetail.count > (fertilizerSlot.maxCount - fertilizerSlot.count) then
						turtleDrop()
					end
				else
					turtle.select(slot)
					turtleDrop()
				end
				turtle.select(1)
			end
		end
		if saplingSlot.name == nil or saplingSlot.count < saplingSlot.maxCount then
			-- search sapling in chest ?
			takeItemInChest("minecraft:oak_sapling", saplingSlot.maxCount - saplingSlot.count)
		end
		if fuelSlot.name == nil or fuelSlot.count < fuelSlot.maxCount then
			-- search fuel in chest ?
			if fuelSlot.name ~= nil then
				takeItemInChest(fuelSlot.name, fuelSlot.maxCount - fuelSlot.count)
			else
				for fuelIndex = 1, #fuelPriority do
					if takeItemInChest(fuelPriority[fuelIndex], fuelSlot.maxCount - fuelSlot.count) then
						break
					end
				end
			end
		end
		turtle.select(1)
		if oldChestSide == "right" then
			turnLeft()
		elseif oldChestSide == "left" then
			turnRight()
		elseif oldChestSide == "back" then
			turnAround()
		end
		chestSide = oldChestSide
		return true
	end
	return false
end

local function useFertilizer()
	local success, fertilizerSlot = findItemSlotInTurtleInventory("minecraft:bone_meal")
	if success then
		turtle.select(fertilizerSlot)
		turtle.place()
		turtle.select(1)
	end
end

local function refuel()
	local minimumFuelAMount = (math.abs(curPosition.X) + math.abs(curPosition.Y) + math.abs(curPosition.Z)) + 200
	if turtle.getFuelLevel() > minimumFuelAMount then
		return true
	end
	local success, fuelSlot
	for fuelIndex = 1, #fuelPriority do
		success, fuelSlot = findItemSlotInTurtleInventory(fuelPriority[fuelIndex])
		if success then
			turtle.select(fuelSlot)
			local itemDetail = turtle.getItemDetail(fuelSlot)
			turtle.refuel(itemDetail.count)
			turtle.select(1)
			if turtle.getFuelLevel() > minimumFuelAMount then
				return true
			end
		end
		success = takeItemInChest(fuelPriority[fuelIndex])
		if success then
			success, fuelSlot = findItemSlotInTurtleInventory(fuelPriority[fuelIndex])
			if success then
				turtle.select(fuelSlot)
				local itemDetail = turtle.getItemDetail(fuelSlot)
				turtle.refuel(itemDetail.count)
				turtle.select(1)
				if turtle.getFuelLevel() > minimumFuelAMount then
					return true
				end
			end
		end
	end
	return turtle.getFuelLevel() > minimumFuelAMount
end

local function recursiveChopping()
	local mineLeaves = true
	for i = 1, 1 do
		if shouldMineBlock("down", mineLeaves) then
			while shouldMineBlock("down", mineLeaves) and turtle.digDown() do
			end
			if moveDown() then
				recursiveChopping()
				moveUp()
			end
		end

		if shouldMineBlock("up", mineLeaves) then
			while shouldMineBlock("up", mineLeaves) and turtle.digUp() do
			end
			if moveUp() then
				recursiveChopping()
				moveDown()
			end
		end

		local sidesSeen = {0, 0, 0, 0}
		for turn = curPosition.direction, curPosition.direction + 3 do
			local oldPosition = copyPosition(curPosition)
			local newPosition = copyPosition(curPosition)

			if shouldMineBlock("front", mineLeaves) then
				while shouldMineBlock("front", mineLeaves) and turtle.dig() do
				end
				if newPosition.direction == 0 or newPosition.direction == 2 then -- Nord ou Sud
					newPosition.X = newPosition.X + (newPosition.direction == 0 and 1 or -1)
				elseif newPosition.direction == 1 or curPosition.direction == 3 then -- Est ou Ouest
					newPosition.Y = newPosition.Y + (newPosition.direction == 1 and 1 or -1)
				end

				targetPosition = copyPosition(newPosition)
				while not arePositionEquals(curPosition, targetPosition, true) do
					moveToTarget()
				end

				recursiveChopping()
			end

			newPosition = copyPosition(oldPosition)
			sidesSeen[oldPosition.direction] = 1
			if sidesSeen[(oldPosition.direction + 1) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction + 1) % 4
			elseif sidesSeen[(oldPosition.direction - 1) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction - 1) % 4
			elseif sidesSeen[(oldPosition.direction + 2) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction + 2) % 4
			elseif sidesSeen[(oldPosition.direction - 2) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction - 2) % 4
			elseif sidesSeen[(oldPosition.direction + 3) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction + 3) % 4
			elseif sidesSeen[(oldPosition.direction - 3) % 4] ~= 1 then
				newPosition.direction = (oldPosition.direction - 3) % 4
			else
				break
			end
			targetPosition = copyPosition(newPosition)
			while not arePositionEquals(curPosition, targetPosition, true) do
				moveToTarget()
			end
		end
		mineLeaves = true
	end
end

-- Main Loop

local function mainLoop()
	while true do
		sleep(0)
		local lastState = currentState
		if currentState == "setup" then
			-- est-on à l'origine ?
			-- les peripheriques sont-ils présents ?
			if not findPeripherals() then
				pmsg("Please place a chest and a furnace next to the turtle.")
				return false;
			end
			-- inspecte devant, cherche un sapling
        	local success, frontItem = turtle.inspect()
			if not success or not (isSapling(frontItem.name) or isLog(frontItem.name)) then
				-- si pas de sapling on en cherche dans l'inventaire
				local success, saplingSlot = findItemSlotInTurtleInventory("minecraft:oak_sapling")
				if not success then
					local success, saplingSlot = findItemSlotInTurtleInventory("minecraft:oak_sapling")
					-- sinon on n'en cherche dans le coffre
				end
				if success then
					-- enfin on le plante
					turtle.select(saplingSlot)
					turtle.place()
					turtle.select(1)
					currentState = "wait"
				else
					pmsg("Can't find sappling.")
					return false;
					-- ou si toujours pas trouvé afficher message
				end
			end
			currentState = "wait"
		elseif currentState == "wait" then
			if makeCharcoal and not clearFurnaceOutput() then
				pmsg("Chest is full")
			elseif makeCharcoal and not fillFurnaceInput() then
				pmsg("Please place a chest and a furnace next to the turtle.")
			elseif not clearTurtleInventory() then
				pmsg("Chest is full")
			elseif makeCharcoal and not fillFurnaceInput() then
				pmsg("Please place a chest and a furnace next to the turtle.")
			elseif not refuel()  then
				pmsg("Can't refuel")
				-- we do nothing, not enought fuel
			elseif #lastPositionStack > 1 then
				targetPosition = lastPositionStack[#lastPositionStack]
				moveToTarget()
				pmsg("Move to target " .. #lastPositionStack)
			else
				pmsg("Inspect")
				local success, frontItem = turtle.inspect()
				if success and isLog(frontItem.name) then
					recursiveChopping()
					currentState = "going_back"
				elseif success and isSapling(frontItem.name) then
					useFertilizer()
				end
            end
		elseif currentState == "going_back" then
			if #lastPositionStack >= 1 then
				local lastPositionInStack = lastPositionStack[#lastPositionStack]
				if curPosition.X == lastPositionInStack.X and curPosition.Y == lastPositionInStack.Y and curPosition.Z == lastPositionInStack.Z then
					lastPositionStack[#lastPositionStack] = nil
				end
				if #lastPositionStack >= 1 then
					targetPosition = lastPositionStack[#lastPositionStack]
					moveToTarget()
				end
			elseif curPosition.X ~= 0 or curPosition.Y ~= 0 or curPosition.Z ~= 0 or curPosition.direction ~= 0 then
				targetPosition = origin
				moveToTarget()
			else
				currentState = "setup"
			end
		end
		if lastState ~= currentState then
			pmsg(currentState)
		end
	end
end

-- Event Loop

local function toggleMakeCharcoal()
	makeCharcoal = not makeCharcoal
	if makeCharcoal then
		pmsg("Charcoal production enabled.")
	else
		pmsg("Charcoal production disabled.")
	end
end

local function eventLoop()
	while true do
		sleep(0)
		while true do
			local event, side, xPos, yPos = os.pullEvent()
			if event == "char" then
				if side == "C" or side == "c" then
					toggleMakeCharcoal()
				end
			end
			if event == "mouse_click" then
				if (xPos >= sizeX-5 and xPos <= sizeX) and (yPos == 1) then
					toggleMakeCharcoal()
				end
			end
		end
	end
end

parallel.waitForAll(mainLoop, eventLoop)
