--ComputerCraft CCNote by Teki 0.1
local mon
local X = 1
local Y = 1
local data = {{}}
local blink = false
local tmpChar
local myTimer

local savedFile
local filePath = "ccnote.save"

if peripheral.find("monitor") == nil then
	mon = term.current()
else
	mon = peripheral.find("monitor")
	isMon = true
end

mon.clear()
term.clear()

local sizeX,sizeY = mon.getSize()

local function Save()
	savedFile = fs.open(filePath, "w")
	savedFile.write(textutils.serialize(data))
	savedFile.flush()
	savedFile.close()
	sleep(0)
end

local function refresh(startX, startY)
	term.clear()
	mon.clear()
	for y=startY, #data do
		for x=startX, #data[y] do
			term.setCursorPos(x,y)
			term.write(data[y][x])
			if isMon then 
				mon.setCursorPos(x,y)
				mon.write(data[y][x])
			end
		end
	end
	
	endY = #data
	if endY > sizeY then
		endY = sizeY
	end
	endX = #data[#data] + 1
	if endX > sizeX then
		endY = endY + 1
		endX = 1
	end
end

local function addLine()
	X = 1
	Y = Y + 1
	
	table.insert(data, Y, {})
	Save()

	refresh(1, 1)
	
	if Y > sizeY then
		Y = sizeY
		term.scroll(1)
		mon.scroll(1)
	end
end

local function addChar(newChar)
	data[Y][X] = newChar
	Save()
	term.setCursorPos(X,Y)
	term.write(data[Y][X])
	if isMon then 
		mon.setCursorPos(X,Y)
		mon.write(data[Y][X])
	end
	X = X + 1
	if X > sizeX then
		addLine()
	end
end

local function delChar()
	X = X - 1
	if X < 1 then
		tableLenghtY = #data[Y]
		tableLenghtYminusOne = #data[Y-1]
		if tableLenghtYminusOne == sizeX then
			table.remove(data[Y-1], sizeX)
		end
		for i = 1, sizeX do
			if i > tableLenghtYminusOne then
				data[Y-1][i] = data[Y][1]
				table.remove(data[Y], 1)
			end
		end
		if #data[Y] == 0 then
			table.remove(data, Y)
			Y = Y - 1
		end
		Save()
		if #data[Y] == sizeX then
			X = #data[Y]
		else
			X = #data[Y] + 1
		end
	else
		table.remove(data[Y], X)
		Save()
	end
	
	term.setCursorPos(X,Y)
	term.write(" ")
	mon.setCursorPos(X,Y)
	mon.write(" ")
	refresh(1, 1)
end

if fs.exists(filePath) and fs.getSize(filePath) > 0 then
	savedFile = fs.open(filePath, "r")
	data = textutils.unserialize(savedFile.readAll())
	savedFile.close()
	refresh(1,1)
	if #data < sizeY then
		Y = #data
	else
		Y = sizeY
	end
	if #data[Y] == 0 then
		Y = Y - 1
	end
	if #data[Y] < sizeX then
		X = #data[Y] + 1
	else
		addLine()
		X = 1
	end
end

while true do
	if myTimer ~= nil then
		os.cancelTimer(myTimer)
	end
	myTimer = os.startTimer(0.25)
	
	local event, param1, param2 = os.pullEvent()
	
	-- Cursor Blink
	if event == "timer" then
		blink = not blink
		if blink then
			term.setCursorPos(X,Y)
			term.write("_")
			if isMon then 
				mon.setCursorPos(X,Y)
				mon.write("_")
			end
		else
			tmpChar = " "
			if data[Y][X] ~= nil then
				tmpChar = data[Y][X]
			end
			term.setCursorPos(X,Y)
			term.write(tmpChar)
			if isMon then 
				mon.setCursorPos(X,Y)
				mon.write(tmpChar)
			end
		end
	else
		tmpChar = " "
		if data[Y][X] ~= nil then
			tmpChar = data[Y][X]
		end
		term.setCursorPos(X,Y)
		term.write(tmpChar)
		if isMon then 
			mon.setCursorPos(X,Y)
			mon.write(tmpChar)
		end
	end
	
	-- Key Events
	if event == "char" then
		addChar(param1)
	elseif event == "key" then
		if keys.getName(param1) == "enter" then
			addLine()
		elseif keys.getName(param1) == "backspace" then
			if X > 1 or Y > 1 then
				delChar()
			end
		elseif keys.getName(param1) == "right" then
			if X < #data[Y] or (X == #data[Y] and X < sizeX) then
				X = X + 1
			elseif Y < #data and (X == #data[Y]+1 or X == sizeX) then
				Y = Y + 1
				X = 1
			end
		elseif keys.getName(param1) == "left" then
			if X > 1 then
				X = X - 1
			elseif Y > 1 then
				Y = Y - 1
				if #data[Y] == sizeX then
					X = #data[Y]
				else
					X = #data[Y] + 1
				end
			end
		elseif keys.getName(param1) == "up" then
			if Y > 1 then
				Y = Y - 1
				if X > #data[Y] then
					X = #data[Y] + 1
				end
			end
		elseif keys.getName(param1) == "down" then
			if Y < sizeY and Y < #data then
				Y = Y + 1
				if X > #data[Y] then
					X = #data[Y] + 1
				end
			end
		else
			-- See pressed key at 1:1
			--mon.setCursorPos(1,1)
			--mon.write(keys.getName(param1))
		end
	end
end

mon.setCursorPos(1,1)
mon.write("Ajouter 3 options à ccquarry pour")
mon.setCursorPos(1,2)
mon.write("définir la position de départ")
mon.setCursorPos(1,3)
mon.write("Faire des ponts/tunnels")
