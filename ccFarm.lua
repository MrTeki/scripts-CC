local plantsDb = {}

-- Save / Load
local filePath = "ccFarm.save"
local function save()
	local savedFile = fs.open(filePath, "w")
	savedFile.write(textutils.serialize(plantsDb))
	savedFile.flush()
	savedFile.close()
end
local function load()
	if fs.exists(filePath) and fs.getSize(filePath) > 0 then
		local savedFile = fs.open(filePath, "r")
		plantsDb = textutils.unserialize(savedFile.readAll())
		savedFile.close()
    end
end
load()

-- Message handling
local monitor = term.current()
local sizeX, sizeY = monitor.getSize()
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

-- Setup
local tArgs = { ... }
if #tArgs < 1 then
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    logMsg("To start farming type:")
    logMsg(programName .. " <1>")
    logMsg("<1>: the size of the farm.")
    logMsg("The size can be 0 to 8.")
    logMsg("Turtle must be at the center of the farm.")
    logMsg("With size 0 turtle consume no fuel and will mine in a cross shaped pattern :")
    logMsg(" X ")
    logMsg("XTX")
    logMsg(" X ")
    return 0
end
local farmSize = tArgs[1] + 0

local function isSeed(itemName)
    return string.match(itemName, "_seeds$") ~= nil
end

local function selectSeedsSlot(seedName)
    if seedName ~= nil then
        local otherSeedSlot = 0
        for slot = 1, 16 do
            local itemDetail = turtle.getItemDetail(slot)
            if itemDetail ~= nil and itemDetail.name == seedName then
                turtle.select(slot)
                return true
            elseif itemDetail ~= nil and isSeed(itemDetail.name) then
                otherSeedSlot = slot
            end
        end
		if otherSeedSlot > 0 then
            turtle.select(otherSeedSlot)
            return true
		end
    end
	for slot = 1, 16 do
		local itemDetail = turtle.getItemDetail(slot)
		if itemDetail ~= nil and isSeed(itemDetail.name) then
            turtle.select(slot)
            return true
		end
	end
    return false
end

local function getTurtleInventory()
    local inventory = {}
	for slot = 1, 16 do
		inventory[slot] = turtle.getItemDetail(slot)
	end
    return inventory
end

local function compareInventories(firstInventory, secondInventory)
    local items = {}
	for slot = 1, 16 do
        if firstInventory[slot] ~= nil then
            items[firstInventory[slot].name] = (items[firstInventory[slot].name] or 0) - firstInventory[slot].count
        end
        if secondInventory[slot] ~= nil then
            items[secondInventory[slot].name] = (items[secondInventory[slot].name] or 0) + secondInventory[slot].count
        end
	end
    for key, value in pairs(items) do
        if value == 0 then
            items[key] = nil
        end
    end
    return items
end

local function findCrop(itemList)
    local crop = nil
    local totalItems = 0
    for name, count in pairs(itemList) do
        if count > 0 then
            totalItems = totalItems + count
            if isSeed(name) or crop == nil then
                crop = name
            end
        end
    end
    return crop, totalItems
end

local function plantSeed(seedName)
    local success = false
    if selectSeedsSlot(seedName) then
        success = turtle.place()
        turtle.select(1)
    else
        logMsg("No more seeds!")
    end
    return success
end
local function harvest()
    if turtle.detect() then
        while turtle.dig() do
            while turtle.suck() do
            end
        end
    end
end

if farmSize == 0 then
    while true do
        local success, plantData = turtle.inspect()
        if success and plantData.state then
            local plant = plantsDb[plantData.name] or {seedName = nil, maxAge = 1, needTest = true}
            if plantData.state.age >= plant.maxAge then
                local oldInventory = nil
                if plant.needTest == true then
                    logMsg("Analyzing " .. plantData.name .. " stage " .. plantData.state.age)
                    oldInventory = getTurtleInventory()
                end
                harvest()
                if plant.needTest == true then
                    local newInventory = getTurtleInventory()
                    local newItems = compareInventories(oldInventory, newInventory)
                    local seedName, itemsCount = findCrop(newItems)
                    if seedName ~= nil then
                        plant.seedName = seedName
                        plantsDb[plantData.name] = plant
                    end
                    if itemsCount > 1 then
                        plant.maxAge = plantData.state.age
                        plant.needTest = false
                        logMsg(plantData.name .. " is now fully known.")
                    else
                        plant.maxAge = plantData.state.age + 1
                    end
                    save()
                end
                plantSeed(plant.seedName)
            end
        end
        turtle.turnRight()
        sleep(0)
    end
end
