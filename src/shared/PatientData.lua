--[[
	Animal Hospital - Stage 2: PatientData.

	Generates a patient and describes what makes it normal or anomalous.
	Pure data: this module builds no parts and touches no world state, so both
	the server and the client can require it.

	Where to put it:
		ReplicatedStorage -> Folder named "Shared" -> ModuleScript named
		"PatientData" -> paste this file in.

	The patient table follows the roadmap's shape:

		{
			name = "Хомяк Джерри",
			isAnomaly = false,
			visualTraits = {},          -- trait ids, only when isAnomaly
			illnessId = "poisoning",    -- what the ward scanner finds
			correctMedicine = "MedicineC",   -- decided by the illness
		}

	plus id / species fields the model builder and the reception UI need.

	IMPORTANT: isAnomaly, visualTraits and correctMedicine are answers. Never
	send a raw patient table to a client - use PatientData.toPublic(), which
	strips them. The client is supposed to work the answer out by looking at
	the patient and the photo, and the server checks the decision.
]]

local PatientData = {}

-- Roadmap: roughly one patient in four is an anomaly.
local ANOMALY_CHANCE = 1 / 4

local rng = Random.new()

--------------------------------------------------------------------------------
-- Traits
--------------------------------------------------------------------------------
-- showsInPhoto splits the two ways a player can catch an anomaly:
--   true  - it is part of the body, so a photo freezes it and can be studied.
--   false - it is behaviour, so it only ever happens live at the counter and
--           a photo of a still pose will never show it.
-- Keeping both kinds means neither the camera nor standing and watching is
-- enough on its own. Stage 7 adds more traits and makes looking harder.

PatientData.Traits = {
	tooManyTeeth = {
		id = "tooManyTeeth",
		label = "Слишком много зубов",
		hint = "Пасть полна лишних зубов.",
		showsInPhoto = true,
	},
	twitching = {
		id = "twitching",
		label = "Дёргается",
		hint = "Время от времени дёргается на месте.",
		showsInPhoto = false,
	},
	wrongVoice = {
		id = "wrongVoice",
		label = "Неправильный голос",
		hint = "Говорит искажённым голосом.",
		showsInPhoto = false,
	},
}

-- Fixed order so trait rolls are reproducible when a bug needs chasing.
local TRAIT_IDS = { "tooManyTeeth", "twitching", "wrongVoice" }

--------------------------------------------------------------------------------
-- Species and names
--------------------------------------------------------------------------------
-- scale is deliberately kept near 1: patients stand at a counter 4 studs tall
-- with a glass window above it, and the model builder puts a patient's head at
-- about 5.1 * scale studs. Anything much smaller disappears behind the desk
-- and the player never sees the animal they are supposed to inspect.

PatientData.Species = {
	{ id = "hamster", label = "Хомяк", color = Color3.fromRGB(214, 170, 110), scale = 0.85 },
	{ id = "cat", label = "Кот", color = Color3.fromRGB(120, 120, 128), scale = 0.95 },
	{ id = "dog", label = "Пёс", color = Color3.fromRGB(150, 110, 70), scale = 1.15 },
	{ id = "rabbit", label = "Кролик", color = Color3.fromRGB(232, 228, 220), scale = 1.0, longEars = true },
	{ id = "parrot", label = "Попугай", color = Color3.fromRGB(90, 170, 90), scale = 0.85 },
}

local GIVEN_NAMES = {
	"Джерри",
	"Мурзик",
	"Бублик",
	"Пиксель",
	"Тофу",
	"Марта",
	"Кекс",
	"Зефир",
	"Рокки",
	"Луна",
	"Персик",
	"Бося",
}

PatientData.Medicines = { "MedicineA", "MedicineB", "MedicineC" }

-- What the three medicine buttons in every treatment room say. Named rather
-- than lettered so the diagnosis on the ward monitor can point at one of them
-- by name and the player has something to match, instead of guessing between
-- A, B and C.
PatientData.MedicineLabels = {
	MedicineA = "Антибиотик",
	MedicineB = "Обезболивающее",
	MedicineC = "Противоядие",
}

--------------------------------------------------------------------------------
-- Illnesses
--------------------------------------------------------------------------------
-- Treatment is not a guess: every patient has an illness, the illness decides
-- the right medicine, and the ward scanner is what turns the illness from a
-- server-side secret into something written on the monitor. Until a patient
-- has been examined the player genuinely does not know which button to press;
-- afterwards there is exactly one right answer and it is on the screen.

PatientData.Illnesses = {
	{
		id = "infection",
		label = "Инфекция",
		finding = "Температура выше нормы, воспаление.",
		medicine = "MedicineA",
	},
	{
		id = "fracture",
		label = "Перелом лапы",
		finding = "Кость повреждена, острая боль.",
		medicine = "MedicineB",
	},
	{
		id = "poisoning",
		label = "Отравление",
		finding = "В крови посторонние вещества.",
		medicine = "MedicineC",
	},
}

function PatientData.getIllness(illnessId)
	for _, illness in ipairs(PatientData.Illnesses) do
		if illness.id == illnessId then
			return illness
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Speech
--------------------------------------------------------------------------------
-- The wrongVoice trait has no audio yet (sound design is stage 15), so for now
-- a patient "speaks" in a bubble above its head and a wrong-voiced one speaks
-- in mangled text. Same idea: only observable live, never in a photo.

local NORMAL_LINES = {
	"Здравствуйте.",
	"Мне бы к врачу.",
	"Что-то мне нехорошо.",
	"Я записан на приём.",
	"Долго ещё ждать?",
}

local WRONG_VOICE_LINES = {
	"З-З-ЗДРАВСТВУЙТЕ.",
	"МНЕ. БЫ. К. ВРАЧУ.",
	"ЧТ0-Т0 МНЕ НЕХОР0Ш0",
	"Я ЗАПИСАН НА ПРИЁМ Я ЗАПИСАН НА ПРИЁМ",
	"Д0ЛГ0 ЕЩЁ ЖДАТЬ",
}

--------------------------------------------------------------------------------
-- Generation
--------------------------------------------------------------------------------

local nextId = 0

local function pick(list)
	return list[rng:NextInteger(1, #list)]
end

function PatientData.getSpecies(speciesId)
	for _, species in ipairs(PatientData.Species) do
		if species.id == speciesId then
			return species
		end
	end
	return nil
end

function PatientData.generate()
	nextId = nextId + 1

	local species = pick(PatientData.Species)
	local givenName = pick(GIVEN_NAMES)
	local isAnomaly = rng:NextNumber() < ANOMALY_CHANCE
	local illness = pick(PatientData.Illnesses)

	-- One or two traits, drawn without replacement so the same trait is never
	-- rolled twice on one patient.
	local visualTraits = {}
	if isAnomaly then
		local pool = {}
		for index, traitId in ipairs(TRAIT_IDS) do
			pool[index] = traitId
		end
		for _ = 1, rng:NextInteger(1, 2) do
			table.insert(visualTraits, table.remove(pool, rng:NextInteger(1, #pool)))
		end
	end

	return {
		id = nextId,
		name = ("%s %s"):format(species.label, givenName),
		givenName = givenName,
		speciesId = species.id,
		speciesLabel = species.label,
		isAnomaly = isAnomaly,
		visualTraits = visualTraits,
		illnessId = illness.id,
		illnessLabel = illness.label,
		illnessFinding = illness.finding,
		-- Derived, never rolled separately: the illness IS the answer, so the
		-- scanner cannot disagree with the button that cures.
		correctMedicine = illness.medicine,
	}
end

--------------------------------------------------------------------------------
-- Reading a patient
--------------------------------------------------------------------------------

function PatientData.hasTrait(patient, traitId)
	for _, id in ipairs(patient.visualTraits) do
		if id == traitId then
			return true
		end
	end
	return false
end

-- Trait ids that the model builder has to show on the body.
function PatientData.getPhotoTraits(patient)
	local traits = {}
	for _, id in ipairs(patient.visualTraits) do
		local trait = PatientData.Traits[id]
		if trait and trait.showsInPhoto then
			table.insert(traits, id)
		end
	end
	return traits
end

function PatientData.pickLine(patient)
	if PatientData.hasTrait(patient, "wrongVoice") then
		return pick(WRONG_VOICE_LINES), true
	end
	return pick(NORMAL_LINES), false
end

-- Human-readable trait list, for the result panel after a decision is made
-- and for server logs. Never send this to a client before the decision.
function PatientData.describeTraits(patient)
	if #patient.visualTraits == 0 then
		return "признаков аномалии нет"
	end
	local labels = {}
	for index, id in ipairs(patient.visualTraits) do
		local trait = PatientData.Traits[id]
		labels[index] = trait and trait.label or id
	end
	return table.concat(labels, ", ")
end

-- Everything a client is allowed to know before it decides. The answers stay
-- on the server; the player reads the body and the photo instead.
function PatientData.toPublic(patient)
	return {
		id = patient.id,
		name = patient.name,
		givenName = patient.givenName,
		speciesLabel = patient.speciesLabel,
	}
end

-- Was admitting/rejecting this patient the right call? The single place that
-- decides, so the server never has the rule written out twice.
function PatientData.isDecisionCorrect(patient, decision)
	if decision == "admit" then
		return not patient.isAnomaly
	elseif decision == "reject" then
		return patient.isAnomaly
	end
	return false
end

return PatientData
