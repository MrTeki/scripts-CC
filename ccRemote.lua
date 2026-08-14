--------------------------------------
-- Common logic ----------------------
--------------------------------------

-- Configuration
local protocolName = "ccRemoteProtocol"

-- Logging
local monitor = term.current()
local sizeX, sizeY = monitor.getSize()
local lastMsg = ""
local lastMsgCount = 0
local function logMsg(msg)
	monitor.setCursorPos(1,sizeY)
	monitor.clearLine()
	if lastMsg == msg then
		lastMsgCount = lastMsgCount + 1
		msg = msg .. " " .. lastMsgCount
	else
		lastMsg = msg
		lastMsgCount = 0
		monitor.scroll(1)
	end
	monitor.setCursorPos(1,sizeY - 1)
	monitor.clearLine()
	monitor.write(msg)
	monitor.setCursorPos(1,sizeY)
end
local function msg(msg)
	monitor.setCursorPos(1,sizeY)
	monitor.clearLine()
	monitor.write(msg)
end

-- Setup
local modem = peripheral.find("modem")
if not modem then
    msg("No modem found.")
    return 0
else
	local sides = peripheral.getNames()
	for i=1, #sides do
		if peripheral.getType(sides[i]) == "modem" then
			side = sides[i]
		end
	end
	rednet.open(side)
end

--------------------------------------
-- Turtle logic ----------------------
--------------------------------------

if turtle ~= nil then
    local function getItemList()
        local itemList = {}
        for slot=1, 16 do
            itemList[slot] = turtle.getItemDetail(slot, true)
        end
        return itemList
    end
    local itemList = getItemList()

    local function catchRednetEvents()
        local id, response = rednet.receive(protocolName, 5)
        if not id or not response then
            return
        end
        local data = {}
        if response ~= nil then
            if response == "searchTurtle" then
                logMsg("Pairing with " .. id)
                data.success = true
                data.message = "I'm a turtle !"
            elseif response == "refresh" then
                    data.success = true
                    data.message = "OO"
            elseif response.method then
                if turtle[response.method] ~= nil then
                        logMsg("Turtle " .. response.method)
                        local pcallSuccess, success, message = pcall(turtle[response.method], response.args)
                        data.success = success
                        data.message = message
                else
                    logMsg("Unknown action " .. response.method)
                    data.success = false
                    data.message = "Unknown action " .. response.method
                end
            end
        end
        
        data.epoch = os.epoch("utc")
        data.fuelLevel = turtle.getFuelLevel()
        data.fuelLimit = turtle.getFuelLimit()
        data.itemList = itemList
        data.inspect = {
            front = turtle.inspect(),
            up = turtle.inspectUp(),
            down = turtle.inspectDown(),
        }
        data.selectedSlot = turtle.getSelectedSlot()
        data.selectedItem = turtle.getItemDetail(turtle.getSelectedSlot(), true)

        rednet.send(id, data, protocolName)
    end
    local function catchInventoryEvents()
        local event = os.pullEvent("turtle_inventory")
        parallel.waitForAny(
            function()
                itemList = getItemList()
            end,
            catchInventoryEvents
        )
    end
    local function updateInventoryPeriodically()
        while true do
            itemList = getItemList()
            sleep(5) -- Update every 5 seconds
        end
    end

    while true do
        parallel.waitForAny(catchRednetEvents, catchInventoryEvents, updateInventoryPeriodically)
    end
end

--------------------------------------
-- Controller logic ------------------
--------------------------------------

-- Search Turtle
local turtleId = nil
local turtleData = {
    selectedSlot = 1
}
while turtleId == nil do
    msg("Searching for a turtle...")
    rednet.broadcast("searchTurtle", protocolName)
    local id, response = rednet.receive(protocolName, 5)
    logMsg(response)
    if id and response and response.message == "I'm a turtle !" then
        msg(response.message)
        turtleId = id
        turtleData = response
    end
end

-- Configuration des couleurs par défaut
local defaultText = colors.black
local defaultBackground = colors.white
local buttonText = colors.black
local buttonBackground = colors.cyan
local buttonFeedback = colors.lightGray
local buttonFeedbackSuccess = colors.lime
local buttonFeedbackError = colors.red

local function sendInstruction(action, ...)
    local data = {
        method = action,
        args = ...
    }
    rednet.send(turtleId, data, protocolName)
    local _, response = rednet.receive(protocolName, 5)
    turtleData = response
end

local function refreshData()
    local message = turtleData.message
    local epoch = turtleData.epoch
    rednet.send(turtleId, "refresh", protocolName)
    local _, response = rednet.receive(protocolName, 5)
    turtleData = response
    turtleData.message = message
    turtleData.epoch = epoch
end

-- Configuration de l'interface avec des options supplémentaires
local uiElements = {
    -- Movements
    {name = "up", x = 4, y = 2, width = 3, text = "U", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("up") end},
    {name = "turnLeft", x = 1, y = 3, width = 3, text = "L", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("turnLeft") end},
    {name = "forward", x = 4, y = 3, width = 3, text = "F", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("forward") end},
    {name = "turnRight", x = 7, y = 3, width = 3, text = "R", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("turnRight") end},
    {name = "down", x = 4, y = 4, width = 3, text = "D", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("down") end},
    
    -- Dig
    {name = "digUp", x = 8, y = 5, width = 4, text = "up", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("digUp") end},
    {name = "dig", x = 13, y = 5, width = 7, text = "front", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("dig") end},
    {name = "digDown", x = 21, y = 5, width = 6, text = "down", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("digDown") end},
    -- Place
    {name = "placeUp", x = 8, y = 6, width = 4, text = "up", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("placeUp") end},
    {name = "place", x = 13, y = 6, width = 7, text = "front", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("place") end},
    {name = "placeDown", x = 21, y = 6, width = 6, text = "down", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("placeDown") end},
    -- Suck
    {name = "suckUp", x = 8, y = 7, width = 4, text = "up", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("suckUp", 1) end},
    {name = "suck", x = 13, y = 7, width = 7, text = "front", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("suck", 1) end},
    {name = "suckDown", x = 21, y = 7, width = 6, text = "down", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("suckDown", 1) end},
    -- Drop
    {name = "dropUp", x = 8, y = 8, width = 4, text = "up", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("dropUp", 1) end},
    {name = "drop", x = 13, y = 8, width = 7, text = "front", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("drop", 1) end},
    {name = "dropDown", x = 21, y = 8, width = 6, text = "down", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("dropDown", 1) end},
    -- Attack
    {name = "attackUp", x = 8, y = 9, width = 4, text = "up", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("attackUp") end},
    {name = "attack", x = 13, y = 9, width = 7, text = "front", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("attack") end},
    {name = "attackDown", x = 21, y = 9, width = 6, text = "down", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("attackDown") end},

    -- Other
    {name = "refuel", x = 10, y = 2, width = 8, text = "Refuel", textColor = buttonText, bgColor = buttonBackground, align = "center", action = function() sendInstruction("refuel", 1) end},
    {name = "selectPrevious", x = 6, y = sizeY - 3, width = 1, text = "-", textColor = buttonText, bgColor = buttonBackground, align = "center",
    action = function()
        sendInstruction("select", (turtleData.selectedSlot - 2) % 16 + 1)
    end},
    {name = "selectNext", x = 9, y = sizeY - 3, width = 1, text = "+", textColor = buttonText, bgColor = buttonBackground, align = "center",
    action = function()
         sendInstruction("select", turtleData.selectedSlot % 16 + 1)
    end},
}

local function drawBar(startX, endX, posY, colorFull, colorEmpty, maxSize, currentSize, label)
	label = label .. " " .. currentSize .. "/" .. maxSize
	local length = (endX - startX + 1)*(currentSize/maxSize)
	for i = startX, endX do
		monitor.setCursorPos(i, posY)
		if i - startX + 1 <= length then
			monitor.setBackgroundColor(colorFull)
		else
			monitor.setBackgroundColor(colorEmpty)
		end
		if #label < i - startX + 1 then
			monitor.write(" ")
		else
			monitor.write(label:sub(i-startX+1, i))
		end
	end
end

-- Fonction pour dessiner l'interface
local function drawUI()
    local monitor = term.current()
    monitor.setTextColor(defaultText)
    monitor.setBackgroundColor(defaultBackground)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Turtle Control Interface")

    -- Labels
    monitor.setCursorPos(1, 5)
    monitor.write("Dig:")
    monitor.setCursorPos(1, 6)
    monitor.write("Place:")
    monitor.setCursorPos(1, 7)
    monitor.write("Suck:")
    monitor.setCursorPos(1, 8)
    monitor.write("Drop:")
    monitor.setCursorPos(1, 9)
    monitor.write("Attack:")

    for _, element in ipairs(uiElements) do
        -- Dessiner le fond du bouton
        local bgColor = element.bgColor or defaultBackground
        local textColor = element.textColor or defaultText
        local width = element.width or string.len(element.text)

        for i = 0, width - 1 do
            monitor.setCursorPos(element.x + i, element.y)
            monitor.setBackgroundColor(bgColor)
            monitor.write(" ")
        end

        -- Dessiner le texte
        local textX = element.x
        if element.align == "center" then
            textX = element.x + math.floor((width - string.len(element.text)) / 2)
        elseif element.align == "right" then
            textX = element.x + (width - string.len(element.text))
        end

        monitor.setCursorPos(textX, element.y)
        monitor.setTextColor(textColor)
        monitor.write(element.text)
    end
    -- Reset colors
    monitor.setTextColor(defaultText)
    monitor.setBackgroundColor(defaultBackground)

    -- Afficher le slot selectionné
    if turtleData and turtleData.selectedSlot then
        monitor.setCursorPos(1, sizeY - 3)
        monitor.write("Slot:")
        monitor.setCursorPos(7, sizeY - 3)
        monitor.write(string.format("%02d", turtleData.selectedSlot))
        monitor.setCursorPos(1, sizeY - 2)
        if turtleData.selectedItem then
            monitor.write("Item: " .. turtleData.selectedItem.displayName .. "(" .. turtleData.selectedItem.count .. "/" .. turtleData.selectedItem.maxCount .. ")")
        else
            monitor.write("Item: None")
        end
    end

    -- Afficher le niveau de carburant
    if turtleData and turtleData.fuelLimit and turtleData.fuelLevel then
        drawBar(1, sizeX, sizeY - 1, colors.green, colors.red, turtleData.fuelLimit, turtleData.fuelLevel, "Fuel:")
    end
    monitor.setTextColor(defaultText)
    monitor.setBackgroundColor(defaultBackground)

    -- Afficher le message de retour d'action
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.setCursorPos(1, sizeY)
    monitor.clearLine()
    if turtleData ~= nil and turtleData.message ~= nil and turtleData.epoch > os.epoch("utc") - 1000 then
        monitor.write(turtleData.message)
    end
    monitor.setCursorPos(1, 1)
end

-- Fonction pour gérer les clics de souris
local function handleMouseClick(event, button, x, y)
    for _, element in ipairs(uiElements) do
        local width = element.width or string.len(element.text)
        if x >= element.x and x < element.x + width and y == element.y then
            -- Change temporairement la couleur du bouton pour indiquer un clic
            local originalBgColor = element.bgColor
            element.bgColor = buttonFeedback -- Couleur de feedback
            drawUI()

            -- Exécuter l'action associée et gérer les erreurs
            local success, err = pcall(element.action)
            if not success then
                -- Afficher un message d'erreur sur la dernière ligne
                logMsg("Error: " .. err)
                turtleData.message = err
                turtleData.epoch = os.epoch("utc")
                element.bgColor = buttonFeedbackError
            elseif not turtleData.success then
                element.bgColor = buttonFeedbackError
            else
                element.bgColor = buttonFeedbackSuccess
            end

            drawUI()
            sleep(0.2) -- Attendre un court moment pour montrer le feedback
            element.bgColor = originalBgColor
            drawUI()
            break
        end
    end
end

-- Boucle principale pour écouter les événements
local function main()
    -- drawUI()
    -- while true do
    --     local event, button, x, y = os.pullEvent("mouse_click") -- "mouse_click" for computers, "monitor_touch" for monitors
    --     handleMouseClick(event, button, x, y)
    -- end
    local pendingRequest = false
    parallel.waitForAny(
        function ()
            while true do
                while pendingRequest do sleep(0) end
                pendingRequest = true
                refreshData()
                pendingRequest = false
                drawUI()
                sleep(0.1)
            end
        end, function ()
            while true do
                local event, button, x, y = os.pullEvent("mouse_click") -- "mouse_click" for computers, "monitor_touch" for monitors
                while pendingRequest do sleep(0) end
                pendingRequest = true
                handleMouseClick(event, button, x, y)
                pendingRequest = false
            end
        end
    )
end

-- Initialisation de l'écran
monitor.setTextColor(defaultText)
monitor.setBackgroundColor(defaultBackground)
for i = 1, sizeY do
	monitor.setCursorPos(1,sizeY)
	monitor.clearLine()
end

-- Exécuter la boucle principale
main()
