--[[
File: init.lua

Initialisations
Module loading
Chat commands
]]

local world_path = minetest.get_worldpath()
s_protect = {}
s_protect.share = {}
s_protect.mod_path = minetest.get_modpath("simple_protection")
s_protect.conf      = world_path.."/s_protect.conf"
s_protect.file      = world_path.."/s_protect.data"
s_protect.sharefile = world_path.."/s_protect_share.data"

-- INTTLIB SUPPORT START
s_protect.gettext = function(rawtext, replacements, ...)
	replacements = {replacements, ...}
	local text = rawtext:gsub("@(%d+)", function(n)
		return replacements[tonumber(n)]
	end)
	return text
end

if minetest.global_exists("intllib") then
	if intllib.make_gettext_pair then
		s_protect.gettext = intllib.make_gettext_pair()
	else
		s_protect.gettext = intllib.Getter()
	end
end
local S = s_protect.gettext
-- INTTLIB SUPPORT END


dofile(s_protect.mod_path.."/functions.lua")
s_protect.load_config()

dofile(s_protect.mod_path.."/database_raw.lua")
minetest.after(0.5, s_protect.load_db)

dofile(s_protect.mod_path.."/protection.lua")
dofile(s_protect.mod_path.."/hud.lua")
dofile(s_protect.mod_path.."/radar.lua")

-- Prevent chest duplicates
-- protector redo does not use the "formspec" meta field
if minetest.registered_nodes["landrush:shared_chest"] then
	minetest.register_alias("simple_protection:chest", "landrush:shared_chest")
else
	dofile(s_protect.mod_path.."/chest.lua")

	-- Just to make sure there can't be unknown nodes
	minetest.register_alias("landrush:shared_chest", "simple_protection:chest")
end


minetest.register_privilege("simple_protection", S("Allows to modify and delete protected areas"))

minetest.register_chatcommand("area", {
	description = S("Manages all of your areas."),
	privs = {interact = true},
	func = function(name, param)
		if param == "" or param == "help" then
			local function chat_send(text, raw_text)
				if raw_text then
					raw_text = ": "..raw_text
				end
				minetest.chat_send_player(name, S(text)..(raw_text or ""))
			end
			local privs = minetest.get_player_privs(name)
			chat_send("Available area commands:")
			chat_send("Information about this area", "/area show")
			chat_send("View of surrounding areas", "  /area radar")
			chat_send("(Un)share one area", "         /area (un)share <name>")
			chat_send("(Un)share all areas", "        /area (un)shareall <name>")
			if s_protect.area_list or privs.simple_protection then
				chat_send("List claimed areas", "         /area list [<name>]")
			end
			chat_send("Unclaim this area", "          /area unclaim")
			if privs.server then
				chat_send("Delete all areas of a player", "/area delete <name>")
			end
			return
		end

		local args = param:split(" ")
		local func = s_protect["command_"..args[1]]
		if not func then
			return false, S("Unknown command parameter: @1. Check '/area' for correct usage.", args[1])
		end

		return func(name, args[2])
	end,
})

s_protect.command_show = function(name)
	local player = minetest.get_player_by_name(name)
	local player_pos = player:get_pos()
	local data = s_protect.get_claim(player_pos)

	minetest.add_entity(s_protect.get_center(player_pos), "simple_protection:marker")
	local minp, maxp = s_protect.get_area_bounds(player_pos)
	minetest.chat_send_player(name, S("Vertical area limit from Y @1 to @2",
			tostring(minp.y), tostring(maxp.y)))

	if not data then
		if s_protect.underground_limit and minp.y < s_protect.underground_limit then
			return true, S("Area status: @1", S("Not claimable"))
		end
		return true, S("Area status: @1", S("Unowned (!)"))
	end

	minetest.chat_send_player(name, S("Area status: @1", S("Owned by @1", data.owner)))
	local text = ""
	for i, player in ipairs(data.shared) do
		text = text..player..", "
	end
	local shared = s_protect.share[data.owner]
	if shared then
		for i, player in ipairs(shared) do
			text = text..player.."*, "
		end
	end

	if text ~= "" then
		return true, S("Players with access: @1", text)
	end
end

local function check_ownership(name)
	local player = minetest.get_player_by_name(name)
	local data, index = s_protect.get_claim(player:get_pos())
	if not data then
		return false, S("This area is not claimed yet.")
	end
	local priv = minetest.check_player_privs(name, {simple_protection=true})
	if name ~= data.owner and not priv then
		return false, S("You do not own this area.")
	end
	return true, data, index
end

s_protect.command_share = function(name, param)
	if not param or name == param then
		return false, S("No player name given.")
	end
	if not minetest.builtin_auth_handler.get_auth(param) and param ~= "*all" then
		return false, S("Unknown player.")
	end
	local success, data, index = check_ownership(name)
	if not success then
		return success, data
	end
	local shared = s_protect.share[name]
	if shared and shared[param] then
		return true, S("@1 already has access to all your areas.", param)
	end

	if table_contains(data.shared, param) then
		return true, S("@1 already has access to this area.", param)
	end
	table.insert(data.shared, param)
	s_protect.set_claim(data, index)

	if minetest.get_player_by_name(param) then
		minetest.chat_send_player(param, S("@1 shared an area with you.", name))
	end
	return true, S("@1 has now access to this area.", param)
end

s_protect.command_unshare = function(name, param)
	if not param or name == param or param == "" then
		return false, S("No player name given.")
	end
	local success, data, index = check_ownership(name)
	if not success then
		return success, data
	end
	if not table_contains(data.shared, param) then
		return true, S("That player has no access to this area.")
	end
	table_erase(data.shared, param)
	s_protect.set_claim(data, index)

	if minetest.get_player_by_name(param) then
		minetest.chat_send_player(param, S("@1 unshared an area with you.", name))
	end
	return true, S("@1 has no longer access to this area.", param)
end

s_protect.command_shareall = function(name, param)
	if not param or name == param or param == "" then
		return false, S("No player name given.")
	end
	if not minetest.builtin_auth_handler.get_auth(param) then
		if param == "*all" then
			return false, S("You can not share all your areas with everybody.")
		end
		return false, S("Unknown player.")
	end

	local shared = s_protect.share[name]
	if table_contains(shared, param) then
		return true, S("@1 already has now access to all your areas.", param)
	end
	if not shared then
		s_protect.share[name] = {}
	end
	table.insert(s_protect.share[name], param)
	s_protect.save_share_db()

	if minetest.get_player_by_name(param) then
		minetest.chat_send_player(param, S("@1 shared all areas with you.", name))
	end
	return true, S("@1 has now access to all your areas.", param)
end

s_protect.command_unshareall = function(name, param)
	if not param or name == param or param == "" then
		return false, S("No player name given.")
	end
	local removed = false
	local shared = s_protect.share[name]
	if table_erase(shared, param) then
		removed = true
		s_protect.save_share_db()
	end

	-- Unshare each single claim
	local claims = s_protect.get_player_claims(name)
	for index, data in pairs(claims) do
		if table_erase(data.shared, param) then
			removed = true
		end
	end
	if not removed then
		return false, S("@1 does not have access to any of your areas.", param)
	end
	s_protect.update_claims(claims)
	if minetest.get_player_by_name(param) then
		minetest.chat_send_player(param, S("@1 unshared all areas with you.", name))
	end
	return true, S("@1 has no longer access to your areas.", param)
end

s_protect.command_unclaim = function(name)
	local success, data, index = check_ownership(name)
	if not success then
		return success, data
	end
	if s_protect.claim_return and name == data.owner then
		local player = minetest.get_player_by_name(name)
		local inv = player:get_inventory()
		if inv:room_for_item("main", "simple_protection:claim") then
			inv:add_item("main", "simple_protection:claim")
		end
	end
	s_protect.set_claim(nil, index)
	return true, S("This area is unowned now.")
end

s_protect.command_delete = function(name, param)
	if not param or name == param or param == "" then
		return false, S("No player name given.")
	end
	if not minetest.check_player_privs(name, {server=true}) then
		return false, S("Missing privilege: @1", "server")
	end

	local removed = {}
	if s_protect.share[param] then
		s_protect.share[param] = nil
		table.insert(removed, S("Globally shared areas"))
		s_protect.save_share_db()
	end

	-- Delete all claims
	local claims, count = s_protect.get_player_claims(param)
	for index in pairs(claims) do
		claims[index] = false
	end
	s_protect.update_claims(claims)

	if count > 0 then
		table.insert(removed, S("@1 claimed area(s)", tostring(count)))
	end

	if #removed == 0 then
		return false, S("@1 does not own any claimed areas.", param)
	end
	return true, S("Removed")..": "..table.concat(removed, ", ")
end

s_protect.command_list = function(name, param)
	local has_sp_priv = minetest.check_player_privs(name, {simple_protection=true})
	if not s_protect.area_list and not has_sp_priv then
		return false, S("This command is not available.")
	end
	if not param or param == "" then
		param = name
	end
	if not has_sp_priv and param ~= name then
		return false, S("Missing privilege: @1", "simple_protection")
	end

	local list = {}
	local width = s_protect.claim_size
	local height = s_protect.claim_height

	local claims = s_protect.get_player_claims(param)
	for index in pairs(claims) do
		-- TODO: Add database-specific function to convert the index to a position
		local abs_pos = minetest.string_to_pos(index)
		table.insert(list, string.format("%5i,%5i,%5i",
			abs_pos.x * width + (width / 2),
			abs_pos.y * height - s_protect.start_underground + (height / 2),
			abs_pos.z * width + (width / 2)
		))
	end

	local text = S("Listing all areas of @1. Amount: @2", param, tostring(#list))
	return true, text.."\n"..table.concat(list, "\n")
end
