local completion = require "cc.completion"
local monitor = term.current()

-- Logging

local lastMsg = ""
local lastMsgCount = 0
local function logMsg(msg)
	monitor.setCursorPos(1,13)
	monitor.clearLine()
	if lastMsg == msg then
		lastMsgCount = lastMsgCount + 1
		msg = msg .. " " .. lastMsgCount
	else
		lastMsg = msg
		lastMsgCount = 0
		monitor.scroll(1)
	end
	monitor.setCursorPos(1,12)
	monitor.clearLine()
	monitor.write(msg)
	monitor.setCursorPos(1,13)
end
local function msg(msg)
	monitor.setCursorPos(1,13)
	monitor.clearLine()
	monitor.write(msg)
end

-- User Interraction

local function askUserForAgreement(question)
    while true do
        io.write(question .. " ")
        local input = read(nil, nil, function(t)
            return completion.choice(t, { "yes", "no" })
        end)
        if not input then return false end

        input = input:lower()
        -- Enter alone refuses: proceeding means something is missing
        if input == "yes" or input == "y" then
            return true
        elseif input == "" or input == "no" or input == "n" then
            return false
        end
    end
end

-- Turtle Inventory

local function getItemList()
    local itemList = {}
	for slot=1, 16 do
		itemList[slot] = turtle.getItemDetail(slot)
	end
	return itemList
end

local function isStairs(itemName)
    return string.match(itemName, "_stairs$") ~= nil
end

local function isTorch(itemName)
    return itemName == "minecraft:torch"
end

local function selectStairSlot()
	for slot = 1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and isStairs(itemDetail.name) then
            turtle.select(slot)
            return true
		end
	end
    return false
end

local function selectTorchSlot()
	for slot = 1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and isTorch(itemDetail.name) then
            turtle.select(slot)
            return true
		end
	end
    return false
end

-- Fuel

local unlimitedFuel = turtle.getFuelLevel() == "unlimited"

local function getFuelLevel()
    if unlimitedFuel then
        return math.huge
    end
    return turtle.getFuelLevel()
end

local function refuel()
	for slot = 1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		-- keep the stairs and torches for building, wooden stairs burn
		if itemDetail ~= nil and not isStairs(itemDetail.name) and not isTorch(itemDetail.name) then
            turtle.select(slot)
            if turtle.refuel(1) then
                return true
            end
		end
	end
    return false
end

-- Setup

local tArgs = { ... }
if #tArgs < 1 then
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    logMsg("To start digging a stair type:")
    logMsg(programName .. " <1>")
    logMsg("<1>: the number of floors to dig.")
    return 0
end

local floorsToMine = tonumber(tArgs[1])
if not floorsToMine or floorsToMine < 1 or floorsToMine % 1 ~= 0 then
    logMsg("Floors must be a whole number >= 1.")
    return 0
end

local function startup()
    local startupSuccess = true

    local items = getItemList()
    local freeSlotCount = 0
    local stairsCount = 0
    local torchesCount = 0
	for slot = 1, 16 do
		if not items[slot] then
			freeSlotCount = freeSlotCount + 1
        elseif isStairs(items[slot].name) then
            stairsCount = stairsCount + items[slot].count
        elseif isTorch(items[slot].name) then
            torchesCount = torchesCount + items[slot].count
		end
	end
    local slotsNeeded = 0
    if floorsToMine <= 2 then
        slotsNeeded = floorsToMine * 4
    else
        slotsNeeded = 8 + ((floorsToMine - 2) * 5)
    end
    slotsNeeded = math.ceil(slotsNeeded / 64)

    local fuelNeeded = 0
    if floorsToMine == 1 then
        fuelNeeded = 1
    elseif floorsToMine == 2 then
        fuelNeeded = 3
    else
        fuelNeeded = 3 + ((floorsToMine - 2) * 4)
    end
    while getFuelLevel() < fuelNeeded and refuel() do
    end

    logMsg("There is " .. freeSlotCount .. "/" .. slotsNeeded .. " free slots.")
    -- only a warning: with a full inventory, digging drops the blocks
    if freeSlotCount < slotsNeeded then
        logMsg("Inventory may fill up, blocks will drop")
    end
    logMsg("There is " .. stairsCount .. "/" .. floorsToMine .. " stairs.")
    if stairsCount < floorsToMine then
        startupSuccess = false
        logMsg("Not enough stairs !")
    end
    -- a torch on every even floor from the 4th one
    local torchesNeeded = math.max(0, math.floor(floorsToMine / 2) - 1)
    logMsg("There is " .. torchesCount .. "/" .. torchesNeeded .. " torches.")
    if torchesCount < torchesNeeded then
        startupSuccess = false
        logMsg("Not enough torches !")
    end
    logMsg("There is " .. turtle.getFuelLevel() .. "/" .. fuelNeeded .. " fuel left.")
    if getFuelLevel() < fuelNeeded then
        startupSuccess = false
        logMsg("Not enough fuel !")
    end

    return startupSuccess
end
if not startup() and not askUserForAgreement("Do you want to proceed anyway ? (y/N)") then
    return 0 
end

-- Digging

local maxAttempts = 20

local actions = {
    forward = {
        move = turtle.forward, detect = turtle.detect, dig = turtle.dig,
        inspect = turtle.inspect, attack = turtle.attack,
    },
    up = {
        move = turtle.up, detect = turtle.detectUp, dig = turtle.digUp,
        inspect = turtle.inspectUp, attack = turtle.attackUp,
    },
    down = {
        move = turtle.down, detect = turtle.detectDown, dig = turtle.digDown,
        inspect = turtle.inspectDown, attack = turtle.attackDown,
    },
}

local function getActions(direction)
    local action = actions[direction]
    if not action then
        error("Error: Bad direction")
    end
    return action
end

-- Errors raised with level 0 stop the digging with a readable message
local function dig(direction)
    local action = getActions(direction)
    while action.detect() do
        if not action.dig() then
            local _, block = action.inspect()
            local name = type(block) == "table" and block.name or "unknown"
            error("Can't dig " .. direction .. " " .. name, 0)
        end
        -- let falling blocks (gravel, sand) land before checking again. Only
        -- needed above: what falls in front lands on the turtle once it moved
        -- in, and the dig up that always follows clears it.
        if direction == "up" then
            sleep(0.5)
        end
    end
end

local function move(direction)
    local action = getActions(direction)
    for attempt = 1, maxAttempts do
        if action.move() then
            return
        end
        if getFuelLevel() < 1 then
            if not refuel() then
                error("Out of fuel", 0)
            end
        elseif action.detect() then
            dig(direction)
        else
            -- probably a mob in the way
            msg("Can't move " .. direction)
            action.attack()
            sleep(0.5)
        end
    end
    error("Can't move " .. direction, 0)
end

local function placeDown()
    for attempt = 1, maxAttempts do
        if turtle.placeDown() then
            return
        end
        if turtle.detectDown() then
            dig("down")
        else
            -- probably a mob in the way
            turtle.attackDown()
            sleep(0.5)
        end
    end
    error("Can't place down", 0)
end

-- Common blocks from digging, solid and not falling
local fillerNames = {
    cobblestone = true, cobbled_deepslate = true, stone = true, deepslate = true,
    dirt = true, andesite = true, diorite = true, granite = true, tuff = true,
    calcite = true, netherrack = true, blackstone = true,
}

local function selectFillerSlot()
	for slot = 1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and fillerNames[itemDetail.name:match(":(.+)$")] then
            turtle.select(slot)
            return true
		end
	end
    return false
end

local function turnAround()
    turtle.turnRight()
    turtle.turnRight()
end

-- With nothing under it (cave, liquid), CC leans the stair against the
-- bottom of the turtle and places it upside down: fill the hole and redo it.
local function fixUpsideDownStair()
    local _, block = turtle.inspectDown()
    if type(block) ~= "table" or not block.state or block.state.half ~= "top" then
        return
    end
    if not selectFillerSlot() then
        logMsg("Upside-down stair, no block to fill the hole")
        return
    end
    dig("down")
    move("down")
    turtle.placeDown()
    move("up")
    selectStairSlot()
    placeDown()
end

local function placeStair()
    if not selectStairSlot() then
        error("Out of stairs", 0)
    end
    -- face backwards so the stair goes down the way we dig
    turnAround()
    placeDown()
    fixUpsideDownStair()
    turnAround()
end

local function digFirstLevel()
    dig("up")
    dig("forward")
    move("forward")
    dig("up")
    dig("down")
    return placeStair()
end

local function digSecondLevel()
    dig("forward")
    move("forward")
    dig("up")
    dig("down")
    move("down")
    dig("down")
    return placeStair()
end

local function digRemainingLevels(floorNumber)
    move("up")
    dig("forward")
    move("forward")
    dig("up")
    if floorNumber % 2 == 0 then
        if selectTorchSlot() then
            turtle.placeUp()
        end
    end
    dig("down")
    move("down")
    dig("down")
    move("down")
    dig("down")
    return placeStair()
end

local ok, err = pcall(function()
    for i = 1, floorsToMine do
        if i == 1 then
            digFirstLevel()
        elseif i == 2 then
            digSecondLevel()
        else
            digRemainingLevels(i)
        end
    end
end)
if ok then
    logMsg("Done: " .. floorsToMine .. " floors dug.")
else
    logMsg("Stop: " .. tostring(err))
end

monitor.scroll(1)
monitor.setCursorPos(1,13)
