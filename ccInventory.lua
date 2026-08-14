-- ccInventory by Teki

-- TODO :
-- handle peripheral types : inventory OK, monitor partially, modem
-- HANDLE PERIPHERAL STATES (online / offline / disabled)

-- monitors :
-- assign a window (list ?) and draw widget
-- on click switch window ?

-- move selected responsibility to item ?
-- move events handling responsibility to item ?

--      enhance peripheral drawing (item responsibility ?)

-- save crafts
-- trigger crafts
-- enhance tabs handling (widget full responsibility)

-- Monitor
term.current().clear()
local sizeX,sizeY = term.current().getSize()
local monitor = window.create(term.current(), 1, 1, sizeX, sizeY, true)
sizeX,sizeY = monitor.getSize()
monitor.setCursorPos(1,sizeY)
monitor.write("Loading...")

-- Properties
local eventFired = false
local getItemDetailInterval = 1000
local itemDb = {}

local nodes = {}
local items = {}
local crafts = {
    -- Make classes
    -- Craft made of a name, Input(s) and Output(s)
    {
        name = "Craft 1",
        -- Input made of Machine(s)
        inputs = {
            -- Machine made of node.name and MachineSlot(s)
            machines = {
                {
                    name = "", -- peripheral side
                    -- MachineSlot made of a key, an ItemList and a ListType
                    slots = {-- list of slots used 0 for all
                        key = "all",
                        list = {}, -- list of items = name +? nbt / count 
                        listType = "whitelist", -- whitelist / blacklist / disabled
                    }
                }
            },
        },
        -- Output made of Machine(s)
        outputs = {
            machines = {
                {
                    side = "", -- peripheral side
                    slots = {0}, -- list of slots used 0 for all
                }
            },
        }
    }
}

-- Logging
local debug = false
-- reset file
local function clearLogFile()
    if debug then
        local logsFile = fs.open("inventory.log", "w")
        logsFile.write("")
        logsFile.close()
    end
end
clearLogFile()
-- Loging method
local function log(message)
    if debug then
        local logsFile = fs.open("inventory.log", "a")
        logsFile.write(message.."\n")
        logsFile.close()
    end
end

-- Save / Load

local savedValues = {}
local filePath = "ccInventory.save"
local function serializeNodes()
    local nodesData = {}
    for index, node in pairs(nodes) do
        nodesData[node.side] = {settings = node.settings}
    end
    return nodesData
end
local function save()
	local savedFile = fs.open(filePath, "w")
	savedValues = {
		["nodes"] = serializeNodes()
	}
    
	savedFile.write(textutils.serialize(savedValues))
	savedFile.flush()
	savedFile.close()
end
local function load()
	if fs.exists(filePath) and fs.getSize(filePath) > 0 then
		local savedFile = fs.open(filePath, "r")
		savedValues = textutils.unserialize(savedFile.readAll())
		savedFile.close()
    end
end
load()

-- Widgets
local itemsListWidget
local peripheralsListWidget
local craftsListWidget
local tabsWidget
local sortWidget

-- Settings
local sortByName = false
local sortAscending = false

-- Methods 
local function roundTo(num, n)
    local mult = 10^(n or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function drawBar(startX, endX, posY, colorFull, colorEmpty, maxSize, currentSize, label, window)
    label = label .. " " .. currentSize .. "/" .. maxSize
    while ((endX - startX + 1) - #label)/2 >= 1 do
        label = " " .. label .. " "
    end
    local length = (endX - startX + 1)*(currentSize/maxSize)
    for i = startX, endX do
        window.setCursorPos(i, posY)
        if i - startX + 1 <= length then
            window.setBackgroundColor(colorFull)
            window.setTextColor(colorEmpty)
        else
            window.setBackgroundColor(colorEmpty)
            window.setTextColor(colorFull)
        end
        if #label < i - startX + 1 then
            window.write(" ")
        else
            window.write(label:sub(i - startX + 1, i))
        end
    end
end

local function indexOf(array, needle)
    for index, value in ipairs(array) do
        if value == needle then
            return index
        end
    end
	return false
end

-- Sorting Items methods
local function growingQuantity(a, b)
    if a.inventory ~= nil and b.inventory ~= nil then
        return a.inventory.capacity < b.inventory.capacity
    elseif a.count ~= nil and b.count ~= nil then
        return a.count < b.count
    else
        return false
    end
end

local function shrinkingQuantity(a, b)
    if a.inventory ~= nil and b.inventory ~= nil then
        return a.inventory.capacity >= b.inventory.capacity
    elseif a.count ~= nil and b.count ~= nil then
        return a.count >= b.count
    else
        return false
    end
end

local function growingName(a, b)
    if a.displayName ~= nil and b.displayName ~= nil then
        return a.displayName < b.displayName
    else
        return a.name < b.name
    end
end

local function shrinkingName(a, b)
    if a.displayName ~= nil and b.displayName ~= nil then
        return a.displayName > b.displayName
    else
        return a.name > b.name
    end
end

local function getSortingMethod()
    if sortByName and sortAscending then
        return growingName
    elseif sortByName and not sortAscending then
        return shrinkingName
    elseif not sortByName and sortAscending then
        return growingQuantity
    elseif not sortByName and not sortAscending then
        return shrinkingQuantity
    end
end

-- Peripherals Data
local function peripheralCall(side, functionName, ...)
    local status, retval = pcall(peripheral.call, side, functionName, ...)
    if status then
        return retval
    else
        return nil
    end
end

local nodeTypes = {
    "command",
    "computer",
    "drive",
    "modem",
    "monitor",
    "printer",
    "speaker",
    -- Generic Peripherals
    "energy_storage",
    "fluid_storage",
    "inventory"
}
-- Node Object Start
local Node = {}
Node.__index = Node
function Node.new(side)
    local newNode = {}
    setmetatable(newNode, Node)
    newNode.side = side
    newNode.name = side
    newNode.peripheral = peripheral.wrap(side)
    newNode.types = {}
    newNode.settings = {}
    local types = table.pack(peripheral.getType(side))
    for k,type in pairs(types) do
        if indexOf(nodeTypes, type) then
            table.insert(newNode.types, type)
        end
    end
    return newNode
end
-- Node Object end

-- Screen Object Start
local Screen = {}
setmetatable(Screen, Node)
Screen.__index = Screen
function Screen.new(side)
    local newScreen = Node.new(side)
    setmetatable(newScreen, Screen)
    newScreen.settings.output = "None"
    return newScreen
end
function Screen:drawNetworkName()
    pcall(function()
        local screen = self.peripheral
        screen.setBackgroundColor(colors.black)
        screen.setTextColor(colors.white)
        local screenSizeX,screenSizeY = screen.getSize()
        screen.clear()
        screen.setCursorPos(1, screenSizeY)
        screen.write(self.side)
    end)
end
function Screen:refreshMonitor()
    pcall(function()
        -- Monitor sizes for textScale = 1:
        -- 1x1 monitor : 7 x 5
        -- 2x2 monitor : 18 x 12 (+7+4 x +5+2)
        -- 3x3 monitor : 29 x 19 (+7+4 x +5+2)
        -- 4x4 monitor : 39 x 26 (+7+3 x +5+2)
        -- 5x5 monitor : 50 x 33 (+7+4 x +5+2)
    
        -- Monitor sizes for textScale = 0.5:
        -- 1x1 monitor : 15 x 10
        -- 2x2 monitor : 36 x 24 (+15+6 x +10+4)
        -- 3x3 monitor : 57 x 38 (+15+6 x +10+4)
        -- 4x4 monitor : 79 x 52 (+15+7 x +10+4)
        -- 5x5 monitor : 100 x 67 (+15+6 x +10+5)
    
        -- add widget setup :
        -- -- width
        -- -- height
        -- -- data type selector : item / node
        -- -- data selector : list / entity
        -- widget size should be selectable (multiples of split screens ? 15 / 2 = 7 + 1 + 7 = widget + border + widget)
        -- widgets types : item data / items list / node data (slots / tanks / RF)
        local screen = self.peripheral
        screen.setBackgroundColor(colors.white)
        screen.setTextColor(colors.black)
        screen.setTextScale(0.5)
        local screenSizeX,screenSizeY = screen.getSize()
        screen.clear()
        if self.settings.output == "Items" then
            screen.setCursorPos(1, 1)
            screen.write("Items")
            screen.setCursorPos(1,2)
            screen.write("count:" .. #items)
        elseif self.settings.output == "Nodes" then
            screen.setCursorPos(1, 1)
            screen.write("Nodes")
            screen.setCursorPos(1,2)
            screen.write("count:" .. #nodes)
        else
            screen.setCursorPos(1, 1)
            screen.write("None")
            screen.setCursorPos(1,2)
            screen.write("x:" .. screenSizeX)
            screen.setCursorPos(1,3)
            screen.write("y:" .. screenSizeY)
            screen.setCursorPos(1,4)
            screen.write("scale:" .. screen.getTextScale())
            screen.setCursorPos(1,5)
            screen.write("Items:" .. #items)
            screen.setCursorPos(1,6)
            screen.write("Nodes:" .. #nodes)
        end
    end)
end
-- Screen Object End

-- Inventory Object Start
local Inventory = {}
setmetatable(Inventory, Node)
Inventory.__index = Inventory
function Inventory.new(side)
    local newInventory = Node.new(side)
    setmetatable(newInventory, Inventory)
    newInventory.settings.inventoryType = "Output"
    newInventory.inventory = {
        capacity = 0,
        stored = 0,
        items = {},
        epoch = 0
    }
    return newInventory
end
function Inventory:refreshInventory()
    local inventory = {
        capacity = self.inventory.capacity,
        stored = 0,
        items = {},
        epoch = 0
    }
    local itemList
    parallel.waitForAll(
        function()
            inventory.capacity = peripheralCall(self.side, "size") or 0
        end,
        function()
            itemList = peripheralCall(self.side, "list") or {}
        end
    )

            local functionsTable = {}
            for i = 1, self.inventory.capacity do
                if itemList[i] == nil then
                    inventory.items[i] = nil
                elseif self.inventory.items[i] == nil or self.inventory.items[i].epoch == nil or self.inventory.items[i].epoch < os.epoch("utc") - getItemDetailInterval then
                    functionsTable[#functionsTable + 1] = function()
                    if itemDb[itemList[i].name] == nil then
                        local tmp = peripheralCall(self.side, "getItemDetail", i)
                        if tmp ~= nil then
                            itemDb[itemList[i].name] = tmp
                        end
                    end
                    inventory.items[i] = {}
                    for k,v in pairs(itemDb[itemList[i].name]) do
                        inventory.items[i][k] = v
                    end
                    inventory.items[i].count = itemList[i].count
                            inventory.items[i].epoch = os.epoch("utc")
                    end
                else
                    inventory.items[i] = self.inventory.items[i]
                end
            end
            parallel.waitForAll(unpack(functionsTable))

    for i = 1, inventory.capacity do
        if inventory.items[i] ~= nil then
            inventory.stored = inventory.stored + 1
        end
    end
    self.inventory = inventory
end
function Inventory:pushItem(toName, fromSlot)
    return peripheralCall(self.side, "pushItems", toName, fromSlot)
end
-- Inventory Object End

-- TurtleInventory Object Start
local TurtleInventory = {}
setmetatable(TurtleInventory, Inventory)
TurtleInventory.__index = TurtleInventory
function TurtleInventory.new(side)
    local newInventory = Inventory.new(side)
    setmetatable(newInventory, TurtleInventory)
    newInventory.peripheral = turtle
    newInventory.types = {"inventory"}
    newInventory.settings.inventoryType = "None"
    newInventory.inventory = {
        capacity = 16,
        stored = 0,
        items = {}
    }
    return newInventory
end
function TurtleInventory:refreshInventory()
    local inventory = {
        capacity = 16,
        stored = 0,
        items = {}
    }

    local functionsTable = {}
    for i = 1, self.inventory.capacity do
        if self.inventory[i] == nil or self.inventory[i].epoch < os.epoch("utc") - getItemDetailInterval then
            functionsTable[#functionsTable + 1] = function()
                local tmp = self.peripheral.getItemDetail(i, true)
                if tmp ~= nil then
                    inventory.items[i] = tmp
                    inventory.items[i].epoch = os.epoch("utc")
                else
                    inventory.items[i] = nil
                end
            end
        end
    end
    parallel.waitForAll(unpack(functionsTable))

    for i = 1, self.inventory.capacity do
        if inventory.items[i] ~= nil then
            inventory.stored = inventory.stored + 1
        end
    end
    self.inventory = inventory
end
function TurtleInventory:pushItem(toName, fromSlot)
    return peripheralCall(toName, "pullItems", self.side, fromSlot)
end
-- TurtleInventory Object End

-- Craft Object Start
local Craft = {}
Craft.__index = Craft
function Craft.new(name)
    local newCraft = {}
    setmetatable(newCraft, Craft)
    -- Craft made of a name, Input(s) and Output(s)
    newCraft.name = name
    newCraft.inputs = {}
    newCraft.outputs = {}
    return newCraft
end
function Craft:pushItem(toName, fromSlot)
    return peripheralCall(self.side, "pushItems", toName, fromSlot)
end
-- Craft Object End

-- wrap turtle inventory 
if (turtle) then
    local sides = peripheral.getNames()
    local localName = nil;
    for i in pairs(sides) do
        if (peripheral.getType(sides[i]) == "modem") and not peripheralCall(sides[i], "isWireless")then
            localName = peripheralCall(sides[i], "getNameLocal")
            break
        end
    end
    nodes[#nodes + 1] = TurtleInventory.new(localName)
end

local function isRemote(name)
    return string.match(name, '(.*_)')
end

local function findPeripherals()
    local sides = peripheral.getNames()

    for k in pairs(nodes) do
        local peripheralFound = false
        for k2 in pairs(sides) do
            if nodes[k] ~= nil and nodes[k].side == sides[k2] then
                table.remove(sides, k2)
                peripheralFound = true
            end
        end
        if not peripheralFound and string.sub(nodes[k].side, 1, string.len("turtle")) ~= "turtle" then
            -- table.remove(nodes, k)
        end
    end

    local index = #nodes + 1
    for i in pairs(sides) do
        local matches = isRemote(sides[i])

        if matches then
            local types = table.pack(peripheral.getType(sides[i]))
            local filteredTypes = {}
            for k,type in pairs(types) do
                if indexOf(nodeTypes, type) then
                    table.insert(filteredTypes, type)
                end
            end
            if indexOf(filteredTypes, "inventory") then
                nodes[index] = Inventory.new(sides[i])
            elseif indexOf(filteredTypes, "monitor") then
                nodes[index] = Screen.new(sides[i])
            else
                nodes[index] = Node.new(sides[i])
            end
            -- restore node settings
            if savedValues["nodes"] ~= nil and savedValues["nodes"][sides[i]] ~= nil then
                for key, value in pairs(savedValues["nodes"][sides[i]]) do
                    nodes[index][key] = value
                end
            end
            index = index + 1
        end
    end
end

local function refreshInventories()
    -- for i in ipairs(wrapped) do
    local functionsTable = {}
    for i = 1, #nodes do
        if indexOf(nodes[i].types, "inventory") then
            functionsTable[#functionsTable + 1] = function() nodes[i]:refreshInventory() end
        end
    end
    if #functionsTable > 0 then
        parallel.waitForAll(unpack(functionsTable))
    end
end
local function refreshScreens()
    -- for i in ipairs(wrapped) do
    local functionsTable = {}
    for i = 1, #nodes do
        if indexOf(nodes[i].types, "monitor") then
            functionsTable[#functionsTable + 1] = function() nodes[i]:refreshMonitor() end
        end
    end
    if #functionsTable > 0 then
        parallel.waitForAll(unpack(functionsTable))
    end
end

-- Items Data

local function updateItems()
    for i = 1,#items do
        items[i].tempCount = 0
    end

    local itemsListHasChanged = false
    for i = 1, #nodes do
        local node = nodes[i]
        if node ~= nil and node.inventory ~= nil and node.settings.inventoryType ~= nil then -- and wrapped[i].inventoryType == "Output" then
            local inventory = node.inventory
            for ii = 1, inventory.capacity do
                if inventory.items[ii] ~= nil and inventory.items[ii].name ~= nil then
                    local currentIndex = 0
                    for iii = 1,#items do
                        if items[iii].name == inventory.items[ii].name and items[iii].nbt == inventory.items[ii].nbt then
                            currentIndex = iii
                        end
                    end
                    if currentIndex == 0 then
                        items[#items + 1] = inventory.items[ii]
                        items[#items].tempCount = inventory.items[ii].count
                        itemsListHasChanged = true
                    else
                        if items[currentIndex].displayName == nil and inventory.items[ii].displayName ~= nil then
                            items[currentIndex].displayName = inventory.items[ii].displayName
                            itemsListHasChanged = true
                        end
                        if items[currentIndex].epoch == nil or items[currentIndex].epoch < os.epoch("utc") - getItemDetailInterval then
                            for k,v in pairs(inventory.items[ii]) do
                                if k ~= "count" then
                                    items[currentIndex][k] = v
                                end
                            end
                        end
                        items[currentIndex].tempCount = items[currentIndex].tempCount + inventory.items[ii].count
                    end
                end
            end
        end
    end

    for k,item in pairs(items) do
        if item.tempCount ~= item.count then
            item.count = item.tempCount
            itemsListHasChanged = true
        end
        item.tempCount = nil
        if item.count == 0 then
            -- TODO : keep data not delete (property hidden = true/false ?)
            table.remove(items, k)
            itemsListHasChanged = true
        end
    end

    if itemsListHasChanged then
        table.sort(items, getSortingMethod())
    end
end

-- Draw
-- Widget Object Start
local Widget = {}
Widget.__index = Widget
function Widget.new(window, x, y, label)
    local newWidget = {}
    setmetatable(newWidget, Widget)
    newWidget.window = window
    newWidget.x = x
    newWidget.y = y
    newWidget.width, newWidget.height = window.getSize()
    newWidget.label = label
    newWidget.content = nil
    newWidget.events = {}
    return newWidget
end
function Widget:draw()
    if self.content ~= nil then
        for y = self.y, self.height do
            self.window.setCursorPos(self.x, y)
            self.window.write(self.label)
            -- for x = self.x, self.height do
            -- if self.content[y] ~= nil then
            --     self.window.blit(self.content[y][1], self.content[y][2], self.content[y][3])
            -- end
            -- end
        end
    end
end
function Widget:handleEvents(event, side, xPos, yPos)
    if xPos ~= nil and yPos ~= nil then
        local offsetX, offsetY = self.window.getPosition()
        xPos = xPos - offsetX + 1
        yPos = yPos - offsetY + 1
    end
    -- start from the end of the table
    -- pass an object by reference to keep data ?
    -- if a callback returns stop propagating event ?
    for k,v in pairs(self.events) do
        if v.type == event and (xPos == nil or (xPos > 0 and xPos <= self.width)) and (yPos == nil or (yPos > 0 and yPos <= self.height)) then
            v.callback(self, side, xPos, yPos)
        end
    end
end
-- return Widget
-- Widget Object End

-- ListWidget Object Start
local ListWidget = {}
setmetatable(ListWidget, Widget)
ListWidget.__index = ListWidget
function ListWidget.new(window, x, y, label, list)
    local newWidget = Widget.new(window, x, y, label)
    setmetatable(newWidget, ListWidget)
    newWidget.list = list
    newWidget.scrolled = 0
    newWidget.totalLines = 0
    newWidget.currentLine = 1
    newWidget.selected = 0
    newWidget.selectedLines = 0
    newWidget.dragged = false

    newWidget.events = {
        {
            -- Scroll buttons
            type = "mouse_click",
            callback = function (self, side, xPos, yPos)
                if (xPos == self.width) then
                    if (yPos == 1) then
                        if self.scrolled > 0 then
                            self.scrolled = self.scrolled - 1
                        end
                    elseif (yPos == self.height) then
                        if self.totalLines > self.scrolled + self.height then
                            self.scrolled = self.scrolled + 1
                        end
                    else
                        self.scrolled = math.floor((yPos-2) * ((self.totalLines - self.height) / (self.height-3)))
                    end
                end
            end
        },
        {
            -- Scroll wheel
            type = "mouse_scroll",
            callback = function (self, direction, xPos, yPos)
                if (self.scrolled + direction < 0) then
                    self.scrolled = 0
                elseif self.scrolled + direction <= self.totalLines - self.height then
                    self.scrolled = self.scrolled + direction
                end
            end
        },
        {
            -- Drag buttons + selection mecanism
            type = "mouse_click",
            callback = function (self, side, xPos, yPos)
                if xPos > 0 and yPos > 0 and xPos <= self.width and yPos <= self.height then
                    -- clicked on selected or selectedLines
                    if (yPos + self.scrolled >= self.selected and yPos + self.scrolled <= self.selected + self.selectedLines) then
                        -- clicked on selected
                        if (yPos + self.scrolled == self.selected) then
                            -- clicked on up arrow of the last line
                            if self.selected > 1 and xPos == 1 then
                                local temp = self.list[self.selected - 1]
                                self.list[self.selected - 1] = self.list[self.selected]
                                self.list[self.selected] = temp
                                self.selected = self.selected - 1
                            -- clicked on down arrow of any line
                            elseif (self.selected == 1 and xPos == 1) or (self.selected > 1 and self.selected < #self.list and xPos == 2) then
                                local temp = self.list[self.selected + 1]
                                self.list[self.selected + 1] = self.list[self.selected]
                                self.list[self.selected] = temp
                                self.selected = self.selected + 1
                            end
                        else
                            -- trigger click on item selected content ?
                        end
                    -- clicked in list but not on selected => new selected
                    elseif (yPos + self.scrolled <= self.totalLines and xPos < self.width) then
                        if self.selected ~= 0 then
                            -- clicked after selected
                            if yPos + self.scrolled > self.selected + self.selectedLines then
                                self.dragged = true
                                self.selected = yPos + self.scrolled - self.selectedLines
                            -- clicked before selected
                            else
                                self.dragged = true
                                self.selected = yPos + self.scrolled
                            end
                        else
                            self.dragged = true
                            self.selected = yPos + self.scrolled
                            if self.scrolled + sizeY <= self.selected + self.selectedLines then
                                self.scrolled = self.selected + 1 - self.height
                            end
                        end
                    end
                end
            end
        },
        {
            type = "mouse_up",
            callback = function (self, side, xPos, yPos)
                -- if not dragged clear selected
                if not self.dragged then
                    if xPos < self.width and yPos >= 1 and (yPos + self.scrolled == self.selected) then
                        if self.scrolled > #self.list - self.height then
                            self.scrolled = #self.list - self.height
                        end
                        if self.scrolled < 0 then
                            self.scrolled = 0
                        end
                        self.selected = 0
                    end
                else
                    self.dragged = false
                end
            end
        },
        {
            type = "mouse_drag",
            callback = function (self, side, xPos, yPos)
                if (yPos + self.scrolled < self.selected and yPos + self.scrolled >= 1) then
                    local temp = self.list[self.selected - 1]
                    self.list[self.selected - 1] = self.list[self.selected]
                    self.list[self.selected] = temp
                    self.selected = self.selected - 1
                    self.dragged = true
                    if (self.scrolled > 0 and yPos == 1) then
                        self.scrolled = self.scrolled - 1
                    end
                elseif (yPos + self.scrolled > self.selected and self.selected < #self.list) then
                    local temp = self.list[self.selected + 1]
                    self.list[self.selected + 1] = self.list[self.selected]
                    self.list[self.selected] = temp
                    self.selected = self.selected + 1
                    self.dragged = true
                    if (self.scrolled + sizeY-1 < self.selected + self.selectedLines and yPos == self.height) then
                        self.scrolled = self.scrolled + 1
                    end
                end
            end
        },
        {
            type = "peripheral",
            callback = function (self, side, xPos, yPos)
                self:listUpdated(side)
            end
        },
        {
            type = "peripheral_detach",
            callback = function (self, side, xPos, yPos)
                self:listUpdated(side)
            end
        }
    }
    return newWidget
end
function ListWidget:draw()
    self:drawList()
    if (self.totalLines > self.height) then
        self:drawScrollBar()
        -- Check if last line was empty
        if (self.currentLine - 1 < self.height) then
            self.scrolled = self.scrolled - (self.height - self.currentLine) - 1
        end
    end
end
function ListWidget:drawList()
    self.totalLines = 0
    self.currentLine = 1
    self.selectedLines = 0

    for i = 1, #self.list do
        if self.list[i] ~= nil then
            if i > self.scrolled - self.selectedLines and self.currentLine <= self.height then
                local linesAdded = self:drawItem(self.list[i], self.currentLine, i == self.selected, i == 1, i == #self.list)
                self.currentLine = self.currentLine + linesAdded
                if i == self.selected then
                    self.selectedLines = linesAdded - 1
                end
                self.totalLines = self.totalLines + linesAdded
            elseif i == self.selected then
                self.currentLine = i - self.scrolled
                local linesAdded = self:drawItem(self.list[i], self.currentLine, i == self.selected, i == 1, i == #self.list)
                self.selectedLines = linesAdded - 1
                self.currentLine = self.currentLine + linesAdded
                if self.currentLine < 1 then
                    self.currentLine = 1
                end
                self.totalLines = self.totalLines + linesAdded
            else
                self.totalLines = self.totalLines + 1
            end
        end
    end
    if self.totalLines < self.height then
        for i = self.totalLines + 1, self.height do
            self.window.setCursorPos(1, i)
            self.window.setBackgroundColor(colors.white)
            self.window.clearLine()
        end
    end
end
function ListWidget:drawScrollBar()
    local unit = self.totalLines / self.height
    local scrollBarHeight = math.ceil(self.height / unit)
    if scrollBarHeight > self.height then scrollBarHeight = self.height end

    for i = 1, self.height do
        self.window.setBackgroundColor(colors.gray)
        self.window.setTextColor(colors.lightGray)
        -- if (i) >= math.ceil(self.scrolled / unit) and (i) <= math.floor((self.scrolled / unit) + scrollBarHeight) then
        if math.floor(i * unit) >= self.scrolled and math.ceil(i * unit) <= self.scrolled + self.height then
            self.window.setBackgroundColor(colors.lightGray)
            self.window.setTextColor(colors.gray)
        end
        self.window.setCursorPos(sizeX, i)
        if i == 1 then
            self.window.write("\30")
        elseif i == self.height then
            self.window.write("\31")
        else
            self.window.write(" ")
        end
    end
end
function ListWidget:drawItemFirstLine(Y, isSelected, first, last)
    self.window.setCursorPos(1, Y)
    if isSelected then
        -- affiche les fleches pour monter/descendre
        self.window.setBackgroundColor(colors.lightGray)
        self.window.setTextColor(colors.gray)
        self.window.clearLine()
        if first then
            self.window.write("\31")
            self.window.setCursorPos(2, Y)
        elseif last then
            self.window.write("\30")
            self.window.setCursorPos(2, Y)
        else
            self.window.write("\30\31")
            self.window.setCursorPos(3, Y)
        end
        self.window.setTextColor(colors.black)
    else
        self.window.setBackgroundColor(colors.white)
        self.window.setTextColor(colors.black)
        self.window.clearLine()
    end
end
function ListWidget:listUpdated(side)
end
-- return ListWidget
-- ListWidget Object End

-- ItemsListWidget Object Start
local itemsWindow = window.create(monitor, 1, 2, sizeX, sizeY-1)
itemsListWidget = ListWidget.new(itemsWindow, 1, 1, "Items", items)
function itemsListWidget:drawItem(item, Y, isSelected, first, last)
    local linesDrawn = 0
    self:drawItemFirstLine(Y, isSelected, first, last)

    if item.displayName ~= nil then
        self.window.write(item.displayName)
    else
        self.window.write(item.name)
    end
    self.window.setCursorPos(sizeX - #("" .. item.count), Y)
    self.window.write(item.count)
    Y = Y + 1
    linesDrawn = linesDrawn + 1

    if isSelected then
        self.window.setTextColor(colors.gray)
        for k,v in pairs(item) do
            if type(v) ~= type(table) then
                -- if k ~= "epoch" then
                    self.window.setCursorPos(2, Y)
                    self.window.clearLine()
                    self.window.write(k .. " " .. v)
                    Y = Y + 1
                    linesDrawn = linesDrawn + 1
                -- end
            else
                -- count entries in table (tags may be empty)
                local entriesCount = 0;
                for kk in pairs(v) do
                    entriesCount = entriesCount + 1
                end
                if entriesCount > 0 then
                    self.window.setCursorPos(2, Y)
                    self.window.clearLine()
                    self.window.write(k .. ":")
                    Y = Y + 1
                    linesDrawn = linesDrawn + 1
                    for kk in pairs(v) do
                        self.window.setCursorPos(3, Y)
                        self.window.clearLine()
                        self.window.write(kk)
                        Y = Y + 1
                        linesDrawn = linesDrawn + 1
                    end
                end
            end
        end
    end
    return linesDrawn
end
-- ItemsListWidget Object end

-- PeripheralsListWidget Object Start
local peripheralsWindow = window.create(monitor, 1, 2, sizeX, sizeY-1)
peripheralsListWidget = ListWidget.new(peripheralsWindow, 1, 1, "Peripherals", nodes)
function peripheralsListWidget:drawItem(item, Y, isSelected, first, last)
    local linesDrawn = 0
    self:drawItemFirstLine(Y, isSelected, first, last)

    if item.name ~= nil then
        self.window.write(item.name)
    else
        self.window.write(item.side)
    end
    Y = Y + 1
    linesDrawn = linesDrawn + 1

    if isSelected then
        if indexOf(item.types, "inventory") then
            local inventoryLinesDrawn = self:drawInventory(item, Y)
            Y = Y + inventoryLinesDrawn
            linesDrawn = linesDrawn + inventoryLinesDrawn
        end
        if indexOf(item.types, "monitor") then
            local monitorLinesDrawn = self:drawMonitor(item, Y)
            Y = Y + monitorLinesDrawn
            linesDrawn = linesDrawn + monitorLinesDrawn
        end

        -- draw types
        if #item.types > 0 then
            self.window.setBackgroundColor(colors.black)
            self.window.setTextColor(colors.white)
            self.window.setCursorPos(1, Y)
            self.window.clearLine()
            self.window.write("Types :")
            Y = Y + 1
            linesDrawn = linesDrawn + 1
            for k, type in pairs(item.types) do
                self.window.setCursorPos(1, Y)
                self.window.clearLine()
                self.window.write(" " .. type)
                Y = Y + 1
                linesDrawn = linesDrawn + 1
            end
        end
    end
    return linesDrawn
end
function peripheralsListWidget:drawInventory(item, Y)
    local linesDrawn = 0
    self.window.setBackgroundColor(colors.white)
    self.window.setTextColor(colors.black)
    self.window.setCursorPos(1, Y)
    self.window.clearLine()
    self.window.write("Type : Input Output None Configure")
    self.window.setBackgroundColor(colors.black)
    self.window.setTextColor(colors.white)
    if item.settings.inventoryType == "Input" then
        self.window.setCursorPos(8, Y)
        self.window.write("Input")
    elseif item.settings.inventoryType == "Output" then
        self.window.setCursorPos(14, Y)
        self.window.write("Output")
    else
        self.window.setCursorPos(21, Y)
        self.window.write("None")
    end
    Y = Y + 1
    linesDrawn = linesDrawn + 1

    drawBar(1, self.width-1, Y, colors.lightGray, colors.gray, item.inventory.capacity, item.inventory.stored, "Inventory", self.window)
    Y = Y + 1
    linesDrawn = linesDrawn + 1

    self.window.setBackgroundColor(colors.lightGray)
    self.window.setTextColor(colors.gray)
    for i = 1,item.inventory.capacity do
        if item.inventory.items[i] ~= nil then
            self.window.setCursorPos(1, Y)
            self.window.clearLine()
            if item.inventory.items[i].displayName ~= nil then
                self.window.write(i .. " " .. item.inventory.items[i].displayName .. " " .. item.inventory.items[i].count)
            else
                self.window.write(i .. " " .. item.inventory.items[i].name .. " " .. item.inventory.items[i].count)
            end
            Y = Y + 1
            linesDrawn = linesDrawn + 1
        end
    end
    return linesDrawn
end
function peripheralsListWidget:drawMonitor(item, Y)
    local linesDrawn = 0
    self.window.setBackgroundColor(colors.white)
    self.window.setTextColor(colors.black)
    self.window.setCursorPos(1, Y)
    self.window.clearLine()
    self.window.write("Print : Items Nodes None")
    self.window.setBackgroundColor(colors.black)
    self.window.setTextColor(colors.white)
    if item.settings.output == "Items" then
        self.window.setCursorPos(9, Y)
        self.window.write("Items")
    elseif item.settings.output == "Nodes" then
        self.window.setCursorPos(15, Y)
        self.window.write("Nodes")
    else
        self.window.setCursorPos(21, Y)
        self.window.write("None")
    end
    Y = Y + 1
    linesDrawn = linesDrawn + 1
    return linesDrawn
end
function peripheralsListWidget:listUpdated(side)
    if self.list[self.selected] ~= nil and self.list[self.selected].side == side then
        self.selected = 0
    end
end
table.insert(peripheralsListWidget.events, {
    type = "mouse_click",
    callback = function (self, side, xPos, yPos)
        -- Peripherals settings
        if self.selected ~= 0 and yPos + self.scrolled == self.selected + 1 then
            local item = nodes[self.selected]
            if indexOf(item.types, "inventory") then
                if xPos >= 8 and xPos <= 12 then
                    item.settings.inventoryType = "Input"
                elseif xPos >= 14 and xPos <= 19 then
                    item.settings.inventoryType = "Output"
                elseif xPos >= 21 and xPos <= 24 then
                    item.settings.inventoryType = "None"
                end
            end
            if indexOf(item.types, "monitor") then
                if xPos >= 9 and xPos <= 13 then
                    item.settings.output = "Items"
                elseif xPos >= 15 and xPos <= 19 then
                    item.settings.output = "Nodes"
                elseif xPos >= 21 and xPos <= 24 then
                    item.settings.output = "None"
                end
            end
        end
    end
})
-- PeripheralsListWidget Object end

-- CraftsListWidget Object Start
local craftsWindow = window.create(monitor, 1, 2, sizeX, sizeY-1)
craftsListWidget = ListWidget.new(craftsWindow, 1, 1, "Crafts", crafts)
craftsListWidget.mode = "list"
function craftsListWidget:drawItem(item, Y, isSelected, first, last)
    local linesDrawn = 0
    self:drawItemFirstLine(Y, isSelected, first, last)

    self.window.write(item.name)
    self.window.setCursorPos(sizeX - #("Config"), Y)
    self.window.write("Config")
    Y = Y + 1
    linesDrawn = linesDrawn + 1

    if isSelected then
        -- Inputs
        self.window.setTextColor(colors.gray)
        self.window.setCursorPos(2, Y)
        self.window.clearLine()
        self.window.write("Inputs :")
        Y = Y + 1
        linesDrawn = linesDrawn + 1
        if #item.inputs > 0 then 
            for k,v in pairs(item.inputs) do
                self.window.setCursorPos(3, Y)
                self.window.clearLine()
                self.window.write(k .. " " .. v)
                Y = Y + 1
                linesDrawn = linesDrawn + 1
            end
        end

        -- Outputs
        self.window.setTextColor(colors.gray)
        self.window.setCursorPos(2, Y)
        self.window.clearLine()
        self.window.write("Outputs :")
        Y = Y + 1
        linesDrawn = linesDrawn + 1
        if #item.outputs > 0 then 
            for k,v in pairs(item.outputs) do
                self.window.setCursorPos(3, Y)
                self.window.clearLine()
                self.window.write(k .. " " .. v)
                Y = Y + 1
                linesDrawn = linesDrawn + 1
            end
        end
    end
    return linesDrawn
end
function craftsListWidget:draw()
    if craftsListWidget.mode == "list" then 
        self:drawList()
        self.totalLines = self.totalLines + 1
        self.window.setBackgroundColour(colors.gray)
        self.window.setTextColor(colors.lightGray)
        self.window.setCursorPos(self.width / 2, self.currentLine)
        self.window.clearLine()
        self.window.write("+")
        self.currentLine = self.currentLine + 1
        if (self.totalLines > self.height) then
            self:drawScrollBar()
            -- Check if last line was empty
            if (self.currentLine - 1 < self.height) then
                self.scrolled = self.scrolled - (self.height - self.currentLine) - 1
            end
        end
    else
        -- Start Method display Craft Setup
        self.totalLines = 0
        self.currentLine = 1
        self.selectedLines = 0
    
        if self.list[self.selected] ~= nil then
            if self.selected > self.scrolled - self.selectedLines and self.currentLine <= self.height then
                local linesAdded = self:drawItem(self.list[self.selected], self.currentLine, self.selected == self.selected, self.selected == 1, self.selected == #self.list)
                self.currentLine = self.currentLine + linesAdded
                if self.selected == self.selected then
                    self.selectedLines = linesAdded - 1
                end
                self.totalLines = self.totalLines + linesAdded
            elseif self.selected == self.selected then
                self.currentLine = self.selected - self.scrolled
                local linesAdded = self:drawItem(self.list[self.selected], self.currentLine, self.selected == self.selected, self.selected == 1, self.selected == #self.list)
                self.selectedLines = linesAdded - 1
                self.currentLine = self.currentLine + linesAdded
                if self.currentLine < 1 then
                    self.currentLine = 1
                end
                self.totalLines = self.totalLines + linesAdded
            else
                self.totalLines = self.totalLines + 1
            end
        end
        if self.totalLines < self.height then
            for i = self.totalLines + 1, self.height do
                self.window.setCursorPos(1, i)
                self.window.setBackgroundColor(colors.white)
                self.window.clearLine()
            end
        end
        -- End Method
    end
end
table.insert(craftsListWidget.events, {
    type = "mouse_click",
    callback = function (self, side, xPos, yPos)
        if craftsListWidget.mode == "list" then
            -- Craft settings
            local item = nil
            if self.selected ~= 0 and yPos + self.scrolled == self.selected + 1 then
                item = crafts[self.selected]
            elseif yPos + self.scrolled == self.totalLines then
                -- New craft !
                crafts[#crafts + 1] = Craft.new("Craft #" .. #crafts + 1)
                item = crafts[#crafts]
            end
            if item ~= nil then
                -- Print craft configuration
                -- new widget ? configuration widget ? pre made inputs ?
            end
        else
            -- chaining events to another widget -- abstraction needed ? (généraliser à tous les widgets se relayer l'abonnement aux events ?)
            -- TODO : créer un widget CraftSetupWidget permettant de créer un Craft et de revenir à la craftListWidget
            -- Créer un ClickableWidget : créé à partir de coordonnées relatives à l'item affiché contenant un label et un callback !!! 
        end
    end
})
-- CraftsListWidget Object end

-- TabsWidget Object start
tabsWidget = Widget.new(monitor, 1, 1, "Tabs")
tabsWidget.currentTab = itemsListWidget
tabsWidget.tabsList = {itemsListWidget, peripheralsListWidget, craftsListWidget}
function tabsWidget:draw()
    self.window.setBackgroundColor(colors.black)
    self.window.setTextColor(colors.white)
    self.window.setCursorPos(6, 1)
    self.window.clearLine()
    self.window.write(" ")
    local X = 1
    for key, tab in pairs(tabsWidget.tabsList) do
        if tabsWidget.currentTab == tab then
            self.window.setBackgroundColour(colors.gray)
        else
            self.window.setBackgroundColour(colors.black)
        end
        self.window.setCursorPos(X, 1)
        self.window.write(tab.label)
        X = X + #tab.label + 1
    end
end
table.insert(tabsWidget.events, {
    type = "mouse_click",
    callback = function (self, side, xPos, yPos)
        -- Tabs
        if (yPos == 1) then
            local X = 1
            for key, tab in pairs(tabsWidget.tabsList) do
                if xPos >= X and xPos <= X + #tab.label then
                    tabsWidget.currentTab = tab
                    break
                else
                    X = X + #tab.label + 1
                end
            end
        end
    end
})
-- TabsWidget Object end

-- SortWidget Object start
sortWidget = Widget.new(monitor, 1, 1, "SortingButtons")
sortWidget.needRedraw = true
function sortWidget:draw()
    if self.needRedraw then
        table.sort(tabsWidget.currentTab.list, getSortingMethod())
        self.needRedraw = false
    end
    self.window.setBackgroundColor(colors.black)
    self.window.setTextColor(colors.white)
    self.window.setCursorPos(sizeX-1, 1)
    if sortByName == true then
        self.window.write("N")
    else
        self.window.write("C")
    end
    self.window.setCursorPos(sizeX, 1)
    if sortAscending == true then
        self.window.write("\30")
    else
        self.window.write("\31")
    end
    self.window.setBackgroundColor(colors.white)
end
table.insert(sortWidget.events, {
    type = "mouse_click",
    callback = function (self, side, xPos, yPos)
        -- Sorting
        if (xPos == sizeX-1 and yPos == 1) then
            sortByName = not sortByName
            self.needRedraw = true
        elseif (xPos == sizeX and yPos == 1) then
            sortAscending = not sortAscending
            self.needRedraw = true
        end
    end
})
-- SortWidget Object end

local function drawAll()
    local elapsed = os.clock()
    while not eventFired do
        updateItems()
        monitor.setVisible(false)
        -- monitor.clear()
        tabsWidget:draw()
        sortWidget:draw()
        tabsWidget.currentTab:draw()

        if debug then
            -- Debug List Count
            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.white)
            monitor.setCursorPos(sizeX - 8 + 1 - 4, 1)
            monitor.write("    ")
            monitor.setCursorPos(sizeX - 8 + 1 - 4, 1)
            monitor.write(tabsWidget.currentTab.totalLines)
            -- End Debug

            -- Debug Elapsed Time
            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.white)
            local elapsedTime = (os.clock() - elapsed)
            local elapsedTimeString = "" .. roundTo((os.clock() - elapsed) / 0.05, 1)
            monitor.setCursorPos(sizeX - 3 + 1 - 4, 1)
            monitor.write("    ")
            monitor.setCursorPos(sizeX - 3 + 1 - #elapsedTimeString, 1)
            monitor.write(elapsedTimeString)
            elapsed = os.clock()
            -- End Debug
        end
        monitor.setVisible(true)

        sleep(0)
        -- if tonumber(elapsedTime) >= 0.01 then
        --     os.queueEvent("")
        --     coroutine.yield()
        -- else
        --     sleep(0)
        -- end
    end
end

local function catchEvents()

    -- EVENTS
    -- local event, side, xPos, yPos = os.pullEvent(eventType)
    while not eventFired do
        local event, side, xPos, yPos = os.pullEvent()

        while event ~= "monitor_touch" and event ~= "mouse_click" and event ~= "mouse_up" and event ~= "mouse_drag"
        and event ~= "mouse_scroll" and event ~= "peripheral" and event ~= "peripheral_detach" do
            event, side, xPos, yPos = os.pullEvent()
        end

        if tabsWidget ~= nil then
            tabsWidget:handleEvents(event, side, xPos, yPos)
            tabsWidget.currentTab:handleEvents(event, side, xPos, yPos)
        end
        if sortWidget ~= nil then
            sortWidget:handleEvents(event, side, xPos, yPos)
        end

        if event == "monitor_touch" then
            for key, node in pairs(nodes) do
                if node.side == side then
                    node:drawNetworkName()
                end
            end
        end

        if event == "peripheral" or event == "peripheral_detach" then
            findPeripherals()
            refreshScreens()
            eventFired = true
        end
        save()
    end
end

local function updateLoop()
    while not eventFired do
        refreshInventories()
        refreshScreens()
        sleep(0)
    end
end

local function transferLoop()
    while not eventFired do
        local movingItemsFunctionsTable = {}
        for indexMaster = 1, #nodes do
            if nodes[indexMaster] ~= nil and nodes[indexMaster].inventory ~= nil and nodes[indexMaster].settings.inventoryType ~= nil and nodes[indexMaster].settings.inventoryType == "Input" then
                for indexSlotMaster = 1, nodes[indexMaster].inventory.capacity do
                    if nodes[indexMaster].inventory.items[indexSlotMaster] ~= nil and nodes[indexMaster].inventory.items[indexSlotMaster].count > 0 then
                        local targetFound = false
                        for indexSlave = 1, #nodes do
                            if not targetFound and nodes[indexSlave] ~= nil and nodes[indexSlave].inventory ~= nil and nodes[indexSlave].settings.inventoryType ~= nil and nodes[indexSlave].settings.inventoryType == "Output" then
                                for indexSlotSlave = 1, nodes[indexSlave].inventory.capacity do
                                    if not targetFound and nodes[indexSlave].inventory.items[indexSlotSlave] ~= nil and nodes[indexSlave].inventory.items[indexSlotSlave].count > 0 and nodes[indexSlave].inventory.items[indexSlotSlave].name == nodes[indexMaster].inventory.items[indexSlotMaster].name then
                                        movingItemsFunctionsTable[#movingItemsFunctionsTable + 1] = function()
                                            local ret = nodes[indexMaster]:pushItem(nodes[indexSlave].side, indexSlotMaster)
                                            if ret ~= nil and ret > 0 then
                                                nodes[indexMaster].inventory.items[indexSlotMaster].count = nodes[indexMaster].inventory.items[indexSlotMaster].count - ret
                                            -- else
                                                -- handle error (slot is full ? peripheral is off ?)
                                            end
                                        end
                                        targetFound = true
                                        break
                                    end
                                end
                            elseif targetFound then
                                break
                            end
                        end
                    end
                end
            end
        end

        if #movingItemsFunctionsTable > 0 then
            parallel.waitForAll(unpack(movingItemsFunctionsTable))
        end
        sleep(0)
    end
end

-- Loop
local function main()
    findPeripherals()
    refreshScreens()
    while true do
        refreshInventories()
        parallel.waitForAll(catchEvents, drawAll, updateLoop, transferLoop)
        eventFired = false
        -- sleep(0)
    end
end

local status, retval = pcall(main)

monitor.clear()
monitor.setCursorPos(1, sizeY);
if not status then
    printError(retval)
else
    print(retval)
end