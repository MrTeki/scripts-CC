--ComputerCraft ccDigiCode by Teki 0.1
-----------------------------------------------------
-- A simple digital code interrupting or sending a --
-- redstone signal when the correct code is typed. --
-----------------------------------------------------
--[[ CONFIG START ]]--
local catchTerminateEvent = true
-- If true will prevent terminating the program by
-- pressing Ctrl + T.
local redstoneInverted = true
-- If true redstone keeps doors closed.
-- If false redstone opens doors.
local redstoneDelay = 2.5
-- Time in seconds before locking back
local redstoneOutputSide = {
-- If true computer will use this side to send a
-- redstone signal to open/close doors. 
bottom = true, -- "bottom"
top = true, -- "top"
back = true, -- "back"
front = true, -- "front"
right = true, -- "right"
left = true -- "left"
}
local redstoneInputSide = {
-- If true computer will listen to this side for
-- a redstone signal when unlocked to lock back.
bottom = true, -- "bottom"
top = true, -- "top"
back = true, -- "back"
front = true, -- "front"
right = true, -- "right"
left = true -- "left"
}
--[[ CONFIG END ]]--

local deleteSettings = not fs.exists(".settings")

if settings.get("shell.allow_disk_startup") then
	if deleteSettings then
		settings.set("shell.allow_disk_startup", false)
		settings.set("ccDigiCode.allow_disk_startup", true)
		settings.set("ccDigiCode.delete_settings", true)
		settings.save(".settings")
	else
		settings.save("ccDigiCode.settings")
		settings.set("shell.allow_disk_startup", false)
		settings.set("ccDigiCode.allow_disk_startup", true)
		settings.save(".settings")
	end
end
		
local startupScript = "shell.run("..shell.getRunningProgram()..")"

-- DATA

local savedCode = ""
local codeStatus = "changing"
local code = ""

local tArgs = { ... }
if #tArgs == 1 then
	savedCode = tArgs[1]
	codeStatus = "false"
end

-- REDSTONE

local timerID

local function setRSOutput(activate)
	local sides = redstone.getSides()
	for i = 1, #sides do
		if redstoneOutputSide[sides[i]] then
			redstone.setOutput(sides[i], activate)
		end
	end
end

local lastRedstoneInput = {}

local function getRSInput()
	local sides = redstone.getSides()
	local returnValue = false
	for i = 1, #sides do
		if redstoneInputSide[sides[i]] then
			if redstone.getInput(sides[i]) ~= lastRedstoneInput[sides[i]] then
				returnValue = true
			end
		end
		lastRedstoneInput[sides[i]] = redstone.getInput(sides[i])
	end
	return returnValue
end

-- DRAWING

local function roundTo(num, n)
  local mult = 10^(n or 0)
  return math.floor(num * mult + 0.5) / mult
end

local function prepareMonitor(target)
	target.sizeX,target.sizeY = target.getSize()
	target.monitor = window.create(target, 1, 1, target.sizeX, target.sizeY, true)
	
	target.cols = roundTo(target.sizeX/3)
	target.rows = roundTo(target.sizeY/5)
	target.centCol = roundTo(target.cols/2)
	target.centRow = roundTo(target.rows/2)
	
	target.buttons = {}

	table.insert(target.buttons, {1, target.rows+1, target.cols, 2*target.rows, "1"})
	table.insert(target.buttons, {target.cols+1, target.rows+1, 2*target.cols, 2*target.rows, "2"})
	table.insert(target.buttons, {2*target.cols+1, target.rows+1, 3*target.cols, 2*target.rows, "3"})

	table.insert(target.buttons, {1, 2*target.rows+1, target.cols, 3*target.rows, "4"})
	table.insert(target.buttons, {target.cols+1, 2*target.rows+1, 2*target.cols, 3*target.rows, "5"})
	table.insert(target.buttons, {2*target.cols+1, 2*target.rows+1, 3*target.cols, 3*target.rows, "6"})

	table.insert(target.buttons, {1, 3*target.rows+1, target.cols, 4*target.rows, "7"})
	table.insert(target.buttons, {target.cols+1, 3*target.rows+1, 2*target.cols, 4*target.rows, "8"})
	table.insert(target.buttons, {2*target.cols+1, 3*target.rows+1, 3*target.cols, 4*target.rows, "9"})

	table.insert(target.buttons, {1, 4*target.rows+1, target.cols, 5*target.rows, "C"})
	table.insert(target.buttons, {target.cols+1, 4*target.rows+1, 2*target.cols, 5*target.rows, "0"})
	table.insert(target.buttons, {2*target.cols+1, 4*target.rows+1, 3*target.cols, 5*target.rows, "E"})
end

local monitors

local function findMonitors()
	monitors = {}
	
	monitors[#monitors+1] = term.current()
	
	prepareMonitor(monitors[#monitors])
	
	local sides = peripheral.getNames()
	for i = 1, #sides do
		if peripheral.getType(sides[i]) == "monitor" then
			monitors[#monitors+1] = peripheral.wrap(sides[i])
			monitors[#monitors].side = sides[i]
			monitors[#monitors].setTextScale(0.5)
			
			prepareMonitor(monitors[#monitors])
		end
	end
end

local function printButton(target, index)
	if target.buttons[index][5] == "C" then
		color = colors.gray
		target.monitor.setTextColor(colors.red)
	elseif target.buttons[index][5] == "E" then
		color = colors.gray
		target.monitor.setTextColor(colors.green)
	elseif index/2 == roundTo(index/2) then
		color = colors.gray
		target.monitor.setTextColor(colors.lightGray)
	else
		color = colors.lightGray
		target.monitor.setTextColor(colors.gray)
	end
	
	if target.buttons[index][6] ~= nil and target.buttons[index][6] > os.clock() then
		color = colors.yellow
	end

	target.monitor.setBackgroundColour(color)
	for i = target.buttons[index][1], target.buttons[index][3] do
		for ii = target.buttons[index][2], target.buttons[index][4] do
			target.monitor.setCursorPos(i, ii)
			target.monitor.write(" ")
		end
	end
	target.monitor.setCursorPos(target.buttons[index][1] + target.centCol-1, target.buttons[index][2] + target.centRow-1)
	target.monitor.write(target.buttons[index][5])
end

local function draw(target)
	while true do
		if codeStatus == "changing" then
			target.monitor.setBackgroundColour(colors.black)
			target.monitor.setTextColor(colors.gray)
		elseif codeStatus == "true" then
			target.monitor.setBackgroundColour(colors.green)
			target.monitor.setTextColor(colors.green)
		else
			target.monitor.setBackgroundColour(colors.red)
			target.monitor.setTextColor(colors.black)
		end
		target.monitor.setVisible(false)
		target.monitor.clear()
		
		--Code
		target.monitor.setCursorPos(roundTo((target.sizeX - string.len(code)+1)/2),target.centRow)
		local hiddenCode = ""
		for i = 1, string.len(code) do
			hiddenCode = hiddenCode .. "*"
		end
		-- target.monitor.write(code)
		target.monitor.write(hiddenCode)
		
		for i=1,#target.buttons do
			printButton(target, i)
		end
		
		target.monitor.setVisible(true)
		sleep(0)
	end
end

-- CATCHING EVENTS

local function catchEvents()
	while true do
		local event, side, xPos, yPos = os.pullEvent()
		
		while event ~= "mouse_click" and event ~= "monitor_touch" and (event ~= "timer" or side ~= timerID) and (event ~= "redstone" or timerID == nil) do
			event, side, xPos, yPos = os.pullEvent()
		end
		
		if event == "redstone" then
			if getRSInput() then
				os.cancelTimer(timerID)
				setRSOutput(redstoneInverted)
				codeStatus = "false"
				code = ""
			end
		elseif event == "timer" then
			setRSOutput(redstoneInverted)
			codeStatus = "false"
			code = ""
		elseif event == "mouse_click" or event == "monitor_touch" then
			local buttons = monitors[1].buttons
			if type(side) ~= "number" then
				for i = 1, #monitors do
					if monitors[i].side == side then
						buttons = monitors[i].buttons
						break
					end
				end
			end
			for i=1,#buttons do
				if (xPos >= buttons[i][1] and xPos <= buttons[i][3]) and (yPos >= buttons[i][2] and yPos <= buttons[i][4] and buttons[i][5] == "C") then
					buttons[i][6] = os.clock() + 0.25
					if code == savedCode and type(side) == "number" and codeStatus ~= "changing" then
						codeStatus = "changing"
						code = ""
					elseif code == savedCode and type(side) == "number" and codeStatus == "changing" then
						return
					else
						code = ""
						codeStatus = "false"
					end
				elseif (xPos >= buttons[i][1] and xPos <= buttons[i][3]) and (yPos >= buttons[i][2] and yPos <= buttons[i][4] and buttons[i][5] == "E") then
					buttons[i][6] = os.clock() + 0.25
					if codeStatus == "changing" then
						savedCode = code
						code = ""
						codeStatus = "false"
					elseif codeStatus == "false" then
						if code == savedCode then
							codeStatus = "true"
							setRSOutput(not redstoneInverted)
							timerID = os.startTimer(redstoneDelay)
							sleep(0.15)
							getRSInput()
						end
						code = ""
					end
				elseif (xPos >= buttons[i][1] and xPos <= buttons[i][3]) and (yPos >= buttons[i][2] and yPos <= buttons[i][4]) then
					buttons[i][6] = os.clock() + 0.25
					code = code .. buttons[i][5]
				end
			end
		end
	end
end

-- START PROGRAM

-- Prevent "terminate" event
local oldPullEvent = os.pullEvent
if catchTerminateEvent then
	os.pullEvent = os.pullEventRaw
end

-- Setup redstone outputs
setRSOutput(redstoneInverted)

-- Setup monitors
findMonitors()
local functionsTable = {}
functionsTable[1] = catchEvents
for i = 1, #monitors do
	functionsTable[#functionsTable+1] = function()
											draw(monitors[i])
										end
end

-- Main Loop
parallel.waitForAny(unpack(functionsTable))

-- Clean quit
-- Disable redstone outputs
setRSOutput(false)
-- Clear monitors
for i = 1, #monitors do
	monitors[i].setCursorPos(1,1)
	monitors[i].clear()
end
-- Restore disk startup setting
if settings.get("ccDigiCode.allow_disk_startup") then
	settings.unset("ccDigiCode.allow_disk_startup")
	if settings.get("ccDigiCode.delete_settings") then
		settings.unset("ccDigiCode.delete_settings")
		settings.set("shell.allow_disk_startup", true)
		fs.delete(".settings")
	else
		settings.load("ccDigiCode.settings")
		settings.save(".settings")
		fs.delete("ccDigiCode.settings")
	end
end
-- Restore pullEvent
os.pullEvent = oldPullEvent