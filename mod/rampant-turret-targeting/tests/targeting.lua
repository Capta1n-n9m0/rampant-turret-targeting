-- Tests for rampant-turret-targeting, run with FactorioTest (see AutoTest/README.md in the author's workspace).
-- Loaded only when the factorio-test mod is active; never runs in a normal game.
--
-- Everything happens on an own lab surface and an own force, so the remote "apply" (which scans every surface,
-- but only for the force it is given) never touches turrets of the save the tests run on.

local L = require("targeting-data")

local FORCE = "rtt-test"
local surface, force

-- the list the mod should set: the generated list minus enemies that don't exist in this game
local function expected(base)
	local kept = {}
	for _, name in ipairs(L[base]) do
		if prototypes.entity[name] then
			kept[#kept + 1] = name
		end
	end
	return kept
end

-- name in a priority slot, nil if the slot is empty or past the end of the list
local function slot(turret, i)
	local ok, p = pcall(turret.get_priority_target, i)
	return ok and p and p.name or nil
end

local function assert_list(turret, base)
	local want = expected(base)
	assert(#want > 0, "no enemy of the " .. base .. " list exists in this game")
	for i, name in ipairs(want) do
		local got = slot(turret, i)
		assert(got == name, string.format("%s slot %d: expected %s, got %s (list of %d)", turret.name, i, name, tostring(got), #want))
	end
	assert(slot(turret, #want + 1) == nil, "slot after the list is not empty: " .. tostring(slot(turret, #want + 1)))
end

local function assert_empty(turret)
	assert(slot(turret, 1) == nil, turret.name .. " got a priority list: slot 1 = " .. tostring(slot(turret, 1)))
end

local function create(name, position, extra)
	local spec = { name = name, position = position, force = force }
	for k, v in pairs(extra or {}) do
		spec[k] = v
	end
	local e = surface.create_entity(spec)
	assert(e, "could not create " .. name .. " at " .. serpent.line(position))
	return e
end

local function apply_all()
	return remote.call("rampant-turret-targeting", "apply", FORCE)
end

-- a unit that is in none of the lists, to fill slots with something that isn't ours
local OTHER = (function()
	local in_lists = {}
	for _, list in pairs(L) do
		for _, name in ipairs(list) do
			in_lists[name] = true
		end
	end
	for name in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "unit" } })) do
		if not in_lists[name] then
			return name
		end
	end
end)()

local hero_mod = script.active_mods["HeroTurretRedux"] or script.active_mods["HeroTurretsReduxFork"]

before_all(function()
	surface = game.create_surface("rtt-test")
	surface.generate_with_lab_tiles = true
	surface.request_to_generate_chunks({ 0, 0 }, 3)
	surface.force_generate_chunk_requests()
	force = game.create_force(FORCE)
end)

after_all(function()
	game.delete_surface(surface)
	game.merge_forces(FORCE, "neutral")
end)

after_each(function()
	for _, e in pairs(surface.find_entities()) do
		if e.valid and e.type ~= "character" then
			e.destroy()
		end
	end
end)

describe("auto-apply on build", function()
	test.each({ "gun-turret", "laser-turret", "flamethrower-turret" })("script-built %s gets its full list", function(name)
		assert_list(create(name, { 10, 0 }, { raise_built = true }), name)
	end)

	test("revived ghost gets the list", function()
		local ghost = create("entity-ghost", { 10, 0 }, { inner_name = "gun-turret" })
		local _, turret = ghost.revive({ raise_revive = true })
		assert(turret and turret.valid, "revive failed")
		assert_list(turret, "gun-turret")
	end)

	test("turret built without an event is left alone", function()
		assert_empty(create("gun-turret", { 10, 0 }))
	end)

	test("own entries past the end of the list are cleared", function()
		assert(OTHER, "no unit outside the lists to test with")
		local turret = create("laser-turret", { 10, 0 })
		local n = #expected("laser-turret")
		for i = 1, n + 3 do
			turret.set_priority_target(i, OTHER)
		end
		script.raise_script_built({ entity = turret })
		assert_list(turret, "laser-turret")
	end)

	local rocket_test = prototypes.entity["rocket-turret"] and test or test.skip
	rocket_test("turret type without a list keeps its own list", function()
		assert(OTHER, "no unit outside the lists to test with")
		local turret = create("rocket-turret", { 10, 0 })
		turret.set_priority_target(1, OTHER)
		script.raise_script_built({ entity = turret })
		assert(slot(turret, 1) == OTHER, "slot 1 changed to " .. tostring(slot(turret, 1)))
		assert(slot(turret, 2) == nil, "slot 2 set to " .. tostring(slot(turret, 2)))
	end)

	describe("setting off", function()
		after_each(function()
			settings.global["rtt-auto-apply"] = { value = true }
		end)

		test("nothing is set while auto-apply is off", function()
			settings.global["rtt-auto-apply"] = { value = false }
			assert_empty(create("gun-turret", { 10, 0 }, { raise_built = true }))
		end)
	end)

	test("construction robots building a ghost give the turret the list", function()
		create("electric-energy-interface", { -4, 0 })
		create("medium-electric-pole", { -2, 0 })
		local roboport = create("roboport", { 0, 0 })
		roboport.get_inventory(defines.inventory.roboport_robot).insert({ name = "construction-robot", count = 10 })
		local chest = create("storage-chest", { 3.5, 3.5 })
		chest.insert({ name = "gun-turret", count = 1 })
		create("entity-ghost", { 10, 0 }, { inner_name = "gun-turret" })

		async(60 * 60)
		on_tick(function()
			-- type filter: other mods put helper entities on turrets (ammo-loader adds a hidden inserter)
			local turret = surface.find_entities_filtered({ position = { 10, 0 }, radius = 1.5, force = force, type = "ammo-turret" })[1]
			if turret then
				assert_list(turret, "gun-turret")
				done()
				return false
			end
		end)
	end)
end)

describe("apply to all (shortcut)", function()
	test("every listed turret of the force gets its list, other forces none", function()
		local gun = create("gun-turret", { 10, 0 })
		local laser = create("laser-turret", { 13, 0 })
		local flame = create("flamethrower-turret", { 16, 0 })
		local stranger = surface.create_entity({ name = "gun-turret", position = { 20, 0 }, force = "neutral" })
		assert(apply_all() == 3, "expected 3 turrets")
		assert_list(gun, "gun-turret")
		assert_list(laser, "laser-turret")
		assert_list(flame, "flamethrower-turret")
		assert_empty(stranger)
	end)

	test("a list set by hand is replaced", function()
		assert(OTHER, "no unit outside the lists to test with")
		local turret = create("gun-turret", { 10, 0 })
		turret.set_priority_target(1, OTHER)
		apply_all()
		assert_list(turret, "gun-turret")
	end)
end)

describe("verification", function()
	local function is_applied(entity)
		return remote.call("rampant-turret-targeting", "is_applied", entity)
	end

	test("last_apply records what the remote apply did", function()
		create("gun-turret", { 10, 0 })
		create("laser-turret", { 13, 0 })
		apply_all()
		local last = remote.call("rampant-turret-targeting", "last_apply")
		assert(last, "no last_apply after an apply")
		assert(last.tick == game.tick, "tick " .. tostring(last.tick) .. ", now " .. game.tick)
		assert(last.source == "remote", "source " .. tostring(last.source))
		assert(last.force == FORCE, "force " .. tostring(last.force))
		assert(last.player == nil, "player " .. tostring(last.player))
		assert(last.turrets == 2, "turrets " .. tostring(last.turrets))
		assert(last.first_error == nil, "error " .. tostring(last.first_error))
	end)

	test("is_applied tells turrets with our list from the rest", function()
		local listed = create("gun-turret", { 10, 0 }, { raise_built = true })
		local plain = create("gun-turret", { 13, 0 })
		local changed = create("laser-turret", { 16, 0 }, { raise_built = true })
		local longer = create("flamethrower-turret", { 19, 0 }, { raise_built = true })
		assert(OTHER, "no unit outside the lists to test with")
		changed.set_priority_target(1, OTHER)
		longer.set_priority_target(#expected("flamethrower-turret") + 1, OTHER)
		assert(is_applied(listed), "turret with the list")
		assert(not is_applied(plain), "turret without a list")
		assert(not is_applied(changed), "turret with slot 1 changed")
		assert(not is_applied(longer), "turret with an extra slot")
		listed.destroy()
		assert(not is_applied(listed), "destroyed turret")
	end)
end)

describe("hero turrets", function()
	local hero_test = (hero_mod and prototypes.entity["hero-turret-2-for-laser-turret"]) and test or test.skip

	hero_test("a ranked turret uses its base turret's list", function()
		assert_list(create("hero-turret-2-for-laser-turret", { 10, 0 }, { raise_built = true }), "laser-turret")
	end)

	-- HeroTurretRedux replaces the turret on the tick after a kill that reaches a rank, copies the old priority
	-- list onto the new entity and raises script_raised_built
	hero_test("a turret ranked up by a kill keeps the full list", function()
		local turret = create("gun-turret", { 10, 0 }, { raise_built = true })
		turret.kills = 1000000
		local unit
		for name in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "unit" } })) do
			unit = unit or name
		end
		local victim = surface.create_entity({ name = unit, position = { 14, 0 }, force = "enemy" })
		assert(victim, "could not create an enemy unit")
		victim.die(force, turret)

		async(10 * 60)
		on_tick(function()
			local now = surface.find_entities_filtered({ position = { 10, 0 }, radius = 1.5, force = force, type = "ammo-turret" })[1]
			if now and now.name ~= "gun-turret" then
				assert(now.name:match("^hero%-turret%-%d+%-for%-gun%-turret$"), "unexpected turret " .. now.name)
				assert_list(now, "gun-turret")
				done()
				return false
			end
		end)
	end)
end)
