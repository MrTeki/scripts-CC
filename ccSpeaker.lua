-- Liste des instruments disponibles
local instruments = {
    "harp", "basedrum", "snare", "hat", "bass",
    "flute", "bell", "guitar", "chime", "xylophone",
    "iron_xylophone", "cow_bell", "didgeridoo", "bit",
    "banjo", "pling"
}

-- Liste des valeurs de pitch (semitones)
local pitches = {}
for i = 0, 24 do
    table.insert(pitches, tostring(i))
end

-- Liste des niveaux de volume
local volumes = {"0.5", "1.0", "1.5", "2.0", "2.5", "3.0"}

-- Dictionnaire pour mapper les noms des notes aux valeurs de pitch
local noteToPitch = {
    ["F#"] = "0", ["G"] = "1", ["G#"] = "2", ["A"] = "3", ["A#"] = "4", ["B"] = "5",
    ["C"] = "6", ["C#"] = "7", ["D"] = "8", ["D#"] = "9", ["E"] = "10", ["F"] = "11",
    ["F#2"] = "12", ["G2"] = "13", ["G#2"] = "14", ["A2"] = "15", ["A#2"] = "16", ["B2"] = "17",
    ["C2"] = "18", ["C#2"] = "19", ["D2"] = "20", ["D#2"] = "21", ["E2"] = "22", ["F2"] = "23", ["F#3"] = "24"
}

-- Table pour regrouper les notes simples et leurs dièses
local groupedNotes = {
    {"F#"}, {"G", "G#"}, {"A", "A#"}, {"B"}, {"C", "C#"}, {"D", "D#"}, {"E"}, {"F", "F#2"},
    {"G2", "G#2"}, {"A2", "A#2"}, {"B2"}, {"C2", "C#2"}, {"D2", "D#2"}, {"E2"}, {"F2", "F#3"}
}

-- Variables pour stocker les sélections de l'utilisateur
local selectedInstrument = instruments[1]
local selectedPitch = pitches[1]
local selectedVolume = volumes[1]

-- Fonction pour dessiner l'interface utilisateur
local function drawUI()
    local monitor = term.current()
    monitor.clear()
    monitor.setBackgroundColor(colors.white)
    monitor.setTextColor(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Instrument:")

    -- Afficher les instruments
    for i, instrument in ipairs(instruments) do
        monitor.setCursorPos(1, i + 1)
        if instrument == selectedInstrument then
            monitor.setBackgroundColor(colors.cyan)
            monitor.setTextColor(colors.black)
            monitor.write(instrument)
            monitor.setBackgroundColor(colors.white)
        else
            monitor.write(instrument)
        end
    end

    monitor.setCursorPos(15, 1)
    monitor.write("Note:")

    -- Afficher les noms des notes regroupées
    for i, noteGroup in ipairs(groupedNotes) do
        monitor.setCursorPos(15, i + 1)
        for j, note in ipairs(noteGroup) do
            local xPos = 15 + ((j-1) * 3)
            monitor.setCursorPos(xPos, i + 1)
            if noteToPitch[note] == selectedPitch then
                monitor.setBackgroundColor(colors.cyan)
                monitor.setTextColor(colors.black)
                monitor.write(note)
                monitor.setBackgroundColor(colors.white)
            else
                monitor.write(note)
            end
        end
    end

    monitor.setCursorPos(21, 1)
    monitor.write("Volume:")

    -- Afficher les niveaux de volume
    for i, volume in ipairs(volumes) do
        monitor.setCursorPos(21, i + 1)
        if volume == selectedVolume then
            monitor.setBackgroundColor(colors.cyan)
            monitor.setTextColor(colors.black)
            monitor.write(volume)
            monitor.setBackgroundColor(colors.white)
        else
            monitor.write(volume)
        end
    end
end

-- Fonction pour gérer les clics de souris
local function handleMouseClick(event, button, x, y)
    if x >= 1 and x <= 14 then
        -- Sélection de l'instrument
        local index = y - 1
        if index >= 1 and index <= #instruments then
            selectedInstrument = instruments[index]
            drawUI()
        end
    elseif x >= 15 and x <= 20 then
        -- Sélection du pitch
        local index = y - 1
        if index >= 1 and index <= #groupedNotes then
            local noteGroup = groupedNotes[index]
            local note = nil
            if #noteGroup == 2 then
                if x <= 17 then
                    note = noteGroup[1]
                else
                    note = noteGroup[2]
                end
            else
                note = noteGroup[1]
            end
            if note then
                selectedPitch = noteToPitch[note]
                drawUI()
            end
        end
    elseif x >= 21 and x <= 28 then
        -- Sélection du volume
        local index = y - 1
        if index >= 1 and index <= #volumes then
            selectedVolume = volumes[index]
            drawUI()
        end
    end
end

-- Fonction pour jouer la note sélectionnée
local function playSelectedNote(speaker)
    speaker.playNote(selectedInstrument, tonumber(selectedVolume), tonumber(selectedPitch))
end

-- Vérifier si un périphérique speaker est connecté
local speaker = peripheral.find("speaker")
if not speaker then
    print("No speaker found.")
    return
end

-- Boucle principale pour écouter les événements
local function main()
    drawUI()
    while true do
        local event, button, x, y = os.pullEvent("mouse_click")
        handleMouseClick(event, button, x, y)
        playSelectedNote(speaker)
    end
end

-- Exécuter la boucle principale
main()
