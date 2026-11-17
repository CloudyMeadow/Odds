--!nocheck
--!nolint UnknownGlobal
-- Kept separate because it touches Roblox globals that only exist inside the engine.
-- Checking is off here so the rest of the library also checks cleanly outside Roblox.
--# selene: allow(undefined_variable)

local isStudio = false
if game ~= nil then
	pcall(function()
		isStudio = game:GetService("RunService"):IsStudio()
	end)
end

return {
	-- True in Roblox Studio (including Play Solo), false in live servers and in Lune.
	isStudio = isStudio :: boolean,
	warn = (warn or print) :: (...any) -> (),
}
