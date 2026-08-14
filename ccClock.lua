--CCClock by Teki
local tArgs = { ... }
local isMon = false
local isNote = false
math.randomseed(os.time())

local monitors = {}
local sizeX = {}
local sizeY = {}
local scales = {}
local noteBlocks = {}
local pitchs = {}

local rings = 0
local lastRing = 0
local curTime
local hours
local minutes
local finalTime

local function formatTime()
	curTime = os.time()
	hours = math.floor(curTime)
	minutes = math.floor((curTime - hours)*60)
	return string.format("%02d:%02d", hours, minutes)
end

local function findScale(side)
	local monitor = peripheral.wrap(side)
	local sizeX2,sizeY2 = monitor.getSize()
	if sizeX2 ~= sizeX[side] or scales[side] == 0 then
		for i=1, 5 do
			monitor.setTextScale(6-i)
			sizeX[side],sizeY[side] = monitor.getSize()
			if sizeX[side] >= 5 then
				scales[side] = 6-i
				break
			end
		end
		monitor.clear()
	end
end

local function resizeEvent()
	local event, side = os.pullEvent("monitor_resize")
	if event == "monitor_resize" then
		findScale(side)
	end
end

local function ring()
	for i = 1, #noteBlocks do
		pitchs[i] = pitchs[i] - (math.random(-1, 1)*3)
		if pitchs[i] < 0 then pitchs[i] = pitchs[i] + 25 end
		if pitchs[i] > 24 then pitchs[i] = pitchs[i] - 25 end
		noteBlocks[i].setPitch(pitchs[i])
		noteBlocks[i].triggerNote()
	end
	rings = rings - 1
end

local function drawTime()
	finalTime = formatTime()
	for i = 1, #monitors do
		monitors[i].setCursorPos(1,1)
		monitors[i].write(finalTime)
	end
end

local function ringTime()
	if isNote then
		-- if lastRing ~= hours then
			-- lastRing = hours
			-- if hours == 0 then
				-- rings = 12
				-- rings = 1
			-- elseif hours > 12 then
				-- rings = hours - 12
				-- rings = 1
			-- else
				-- rings = hours
				-- rings = 1
			-- end
		-- end
		if hours == 18 and minutes >= 30 and minutes < 35 and rings == 0 then
			rings = 6
		end
		
		if rings > 0 then
			ring()
		end
	end
end

local function mainLoop() 
	while true do
		parallel.waitForAll(drawTime, ringTime)
		sleep(1)
	end
end

monitors[#monitors+1] = term.current()
monitors[#monitors].clear()
local peripherals = peripheral.getNames()
for i=1, #peripherals do
	if peripheral.getType(peripherals[i]) == "monitor" then
		monitors[#monitors+1] = peripheral.wrap(peripherals[i])
		sizeX[peripherals[i]],sizeY[peripherals[i]] = monitors[#monitors].getSize()
		scales[peripherals[i]] = 0
		findScale(peripherals[i])
		isMon = true
	elseif peripheral.getType(peripherals[i]) == "note_block" then
		noteBlocks[#noteBlocks+1] = peripheral.wrap(peripherals[i])
		-- pitchs[#noteBlocks] = noteBlocks[#noteBlocks].getNote()
		pitchs[#noteBlocks] = 0
		isNote = true
	end
end

while true do
	parallel.waitForAny(resizeEvent, mainLoop)
	sleep(0)
end