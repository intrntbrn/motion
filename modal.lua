local M = {}

-- TODO:
-- force stay open keybind
-- add keybind support for each tree node
-- keyname tester
-- timestamp
-- move wm specific configs away from config?
-- fix default clienting floating resize
-- tests for key parser

local awful = require("awful")
local vim = require("motion.vim")
local util = require("motion.util")
local dump = require("motion.vim").inspect
local akeygrabber = require("awful.keygrabber")

-- global
local global_tree
local global_keygrabber
local mod_conversion = nil
local mod_map

local function generate_mod_conversion_maps()
	if mod_conversion then
		return nil
	end

	local mods = awesome._modifiers
	assert(mods)

	mod_conversion = {}

	for mod, keysyms in pairs(mods) do
		for _, keysym in ipairs(keysyms) do
			assert(keysym.keysym)
			mod_conversion[mod] = mod_conversion[mod] or keysym.keysym
			mod_conversion[keysym.keysym] = mod
		end
	end

	-- all supported mods
	local map = {
		["S"] = mod_conversion["Shift_L"], -- Shift
		["A"] = mod_conversion["Alt_L"], -- Mod1
		["C"] = mod_conversion["Control_L"], -- Control
		["M"] = mod_conversion["Super_L"], -- Mod4
	}

	for k, v in pairs(map) do
		map[v] = k
	end

	mod_map = map

	return nil
end

-- @param t table A motion (sub)tree
local function on_start(t)
	awesome.emit_signal("motion::start", t)
end

-- @param t table A motion (sub)tree
local function on_stop(t)
	global_keygrabber = nil
	awesome.emit_signal("motion::stop", t)
end

local global_execute
-- bypass the keygrabber
function M.fake_input(key, force_continue)
	if global_keygrabber and global_execute then
		global_execute(key, global_keygrabber, force_continue)
	end
end

-- @param m table Map of parsed keys
-- @param k table Parsed key
local function add_key_to_map(m, k)
	assert(k.key)
	assert(k.mods)

	m[k.key] = m[k.key] or {}
	table.insert(m[k.key], k)

	-- sort by mod count descending
	table.sort(m[k.key], function(a, b)
		return #a.mods > #b.mods
	end)
end

-- @param t table A motion (sub)tree
-- @return table Table with tables of keys
local function keygrabber_keys(t)
	local succs = t:successors()
	local opts = t:opts()

	local all_keys = {}

	-- regular keys (successors)
	for k, v in pairs(succs) do
		if v:cond() then
			for _, key in pairs(M.parse_vim_key(k)) do
				add_key_to_map(all_keys, key)
			end
		end
	end

	-- stop keys
	assert(opts.stop_keys, "no stop keys found")
	local stop_keys

	if type(opts.stop_keys) == "table" then
		stop_keys = opts.stop_keys
	elseif type(opts.stop_keys) == "string" then
		stop_keys = { opts.stop_keys }
	end

	assert(stop_keys, "no stop keys found")

	for _, sk in pairs(stop_keys) do
		local parsed_keys = M.parse_vim_key(sk)
		for _, parsed_key in pairs(parsed_keys) do
			local key = {
				mods = parsed_key.mods,
				key = parsed_key.key,
				stop = true,
			}
			add_key_to_map(all_keys, key)
		end
	end

	-- back keys
	if t:pred() then
		local back_keys

		if type(opts.back_keys) == "table" then
			back_keys = opts.back_keys
		elseif type(opts.back_keys) == "string" then
			back_keys = { opts.back_keys }
		end

		if back_keys then
			for _, bk in pairs(back_keys) do
				local parsed_keys = M.parse_vim_key(bk)
				for _, parsed_key in pairs(parsed_keys) do
					local key = {
						mods = parsed_key.mods,
						key = parsed_key.key,
						back = t:pred(),
					}
					add_key_to_map(all_keys, key)
				end
			end
		end
	end

	return all_keys
end

local function mm_press(self, key, mods)
	if not self then
		return
	end

	for _, mod in pairs(mods) do
		self[mod] = true
		print("mm: pressed mod: ", mod)
	end

	---@diagnostic disable-next-line: need-check-nil
	local converted_key = mod_conversion[key]
	-- key is actually a mod (e.g. Super_L -> Mod4)
	if converted_key then
		print("mm: pressed mod: ", converted_key)
		self[converted_key] = true
	end
end

local function mm_init(self, key, mods)
	assert(self)
	mm_press(self, key, mods)
end

local function mm_release(self, key)
	if not self then
		return
	end

	print("mm release: ", key, dump(self))
	---@diagnostic disable-next-line: need-check-nil
	local converted_key = mod_conversion[key]
	-- key is actually a mod (e.g. Super_L -> Mod4)
	if converted_key then
		print("mm is converted: ", key, converted_key)
		if not (self[converted_key] == nil) then
			self[converted_key] = false
			print("mm: cleared mod: ", key, converted_key)
		else
			print("mm is not registered: ", key, converted_key)
		end
	end
end

-- local function mm_is_key_pressed(self, key)
-- 	if not self then
-- 		return
-- 	end
--
-- 	if not (self[key] == nil) then
-- 		return self[key]
-- 	end
--
-- 	---@diagnostic disable-next-line: need-check-nil
-- 	local converted_key = mod_conversion[key]
--
-- 	if converted_key then
-- 		if not (self[converted_key] == nil) then
-- 			return self[converted_key]
-- 		end
-- 	end
--
-- 	return false
-- end

local function mm_has_pressed_mods(self)
	if not self then
		return
	end
	for k, m in pairs(self) do
		if m then
			print("mm: has mod pressed: ", k)
			return true
		end
	end
	return false
end

local function mm_get_pressed_mods(self)
	local pressed_mods = {}
	for mod, is_pressed in pairs(self or {}) do
		if is_pressed then
			table.insert(pressed_mods, mod)
		end
	end
	return pressed_mods
end

local function grab(t, keybind)
	assert(mod_conversion)
	local opts = t:opts()

	-- hold mod init
	local hold_mod = opts.mod_hold_continue and keybind
	local root_key = hold_mod and keybind

	if hold_mod then
		assert(root_key.key, "hold_mod is active but there is no root key")
	end

	local hold_mod_ran_once = false

	local mm = {}
	if hold_mod then
		mm_init(mm, root_key.key, root_key.mods)
	end

	----------------------------------------------------------------------------------------------

	local keybinds = keygrabber_keys(t)
	assert(keybinds)

	local function set_next_tree(tree)
		keybinds = keygrabber_keys(tree)
		t = tree
		global_tree = t
		on_start(tree)
	end

	-- set the tree
	local function run(tree, force)
		-- force is currently only true for timeout nodes
		if not tree then
			assert(false, "catch bug: tree is nil in run_tree")
			return
		end

		---@diagnostic disable-next-line: redefined-local
		local opts = tree:opts()
		local succs = tree:successors()

		if succs and vim.tbl_count(succs) > 0 and not force then
			-- wait for inputs
			return tree
		end

		-- run!
		local subtree = tree:fn(opts)
		if subtree then
			-- dynamically created list
			if type(subtree) ~= "table" or vim.tbl_count(subtree) == 0 then
				return
			end
			tree:add_successors(subtree)
			return tree
		end

		-- command did not return a new list
		hold_mod_ran_once = true

		if opts.stay_open then
			return tree:pred()
		end

		return nil
	end

	local function execute(key, grabber, continue)
		if key == "back" then
			local prev = t:pred()
			if prev then
				set_next_tree(prev)
			end
			return
		end

		if key == "stop" then
			grabber = grabber or global_keygrabber
			if grabber then
				grabber:stop()
			end
			return
		end

		local next_tree = run(t[key])
		if next_tree then
			set_next_tree(next_tree)
			return
		end

		if not mm_has_pressed_mods(mm) and not continue then
			grabber:stop()
			return
		end

		-- the execution might cause some hinting labels to change
		-- therefore we are emitting the signal again
		-- on_start(t)
	end

	-- we have to force the menu generation if the user calls M.run() on an
	-- dynamic menu node. This should be the only case when we end up here
	-- without any successors.
	if vim.tbl_count(t:successors()) == 0 then
		run(t) -- populate the tree
		if vim.tbl_count(t:successors()) == 0 then
			assert(false, "catch bug: no successors on grab")
			return
		end
	end

	local grabber = akeygrabber({
		-- keyreleased_callback is only used for hold_mod detection
		keyreleased_callback = hold_mod and function(self, _, key)
			-- print("released callback: ", dump(key))

			mm_release(mm, key)
			if not mm_has_pressed_mods(mm) then
				local mod_release = t:opts().mod_release_stop
				if mod_release == "always" or hold_mod_ran_once and mod_release == "after" then
					print("mm: all mods are released: ", mod_release)
					self:stop()
					return
				end
				print("mm: all mods are released: ", mod_release)
			end
		end,
		keypressed_callback = function(self, modifiers, key)
			print("pressed callback: ", dump(modifiers), dump(key))
			local converted_key = mod_conversion[key] -- e.g. Super_L -> Mod4

			mm_press(mm, key, modifiers)

			if keybinds[key] then
				local function on_match(v)
					-- stop key
					if v.stop then
						self:stop()
						return
					end

					-- back key
					if v.back then
						execute("back", self)
						-- set_next_tree(v.back)
						return
					end

					-- regular key
					local key_name = v.name
					print("running key function: ", key_name, t[key_name]:desc())
					execute(key_name, self)
					return
				end

				-- remove all mods that are ignored by default
				local ignore_mods = { "Lock2", "Mod2" }
				local filtered_modifiers = {}
				-- for _, m in ipairs(modifiers) do
				-- 	local ignore = vim.tbl_contains(ignore_mods, m)
				-- 	if not ignore then
				-- 		table.insert(filtered_modifiers, m)
				-- 	end
				-- end

				-- algo: remove mod, and check each key again

				-- modifiers = filtered_modifiers

				local function is_match(v, comparator)
					if not (#v == #comparator) then
						return false
					end

					-- generate mod map
					local mod = {}
					for _, v2 in ipairs(v) do
						mod[v2] = true
					end

					local match = true
					for _, v2 in ipairs(comparator) do
						match = match and mod[v2]
					end

					return match
				end

				local ignore_hold_mods = {}
				local filtered_hold_mod_modifiers = {}
				local check_hold_mod = mm_has_pressed_mods(mm)

				if check_hold_mod then
					local pressed_mods = mm_get_pressed_mods(mm)
					for _, mod in pairs(pressed_mods) do
						table.insert(ignore_hold_mods, mod)
					end
				end

				for _, m in ipairs(modifiers) do
					local ignore = vim.tbl_contains(ignore_mods, m)
					if not ignore then
						table.insert(filtered_modifiers, m)
						if check_hold_mod then
							local ignore_hold_mod = vim.tbl_contains(ignore_hold_mods, m)
							if not ignore_hold_mod then
								table.insert(filtered_hold_mod_modifiers, m)
							end
						end
					end
				end

				-- keybinds are sorted by descending mod count
				for _, v in ipairs(keybinds[key]) do
					-- generate mod map
					local mod = {}
					for _, v2 in ipairs(v.mods) do
						mod[v2] = true
					end

					-- check if mods are matching
					local match = false
					local mod_count = #v.mods
					if #filtered_modifiers == mod_count then
						match = true
						for _, v2 in ipairs(filtered_modifiers) do
							match = match and mod[v2]
						end
					elseif check_hold_mod and #filtered_hold_mod_modifiers == mod_count then
						match = true
						for _, v2 in ipairs(filtered_hold_mod_modifiers) do
							match = match and mod[v2]
						end
					end

					if match then
						return on_match(v)
					end
				end
			else
				-- -- key is not defined
				-- -- it might be a mod key that is pressed again
				-- if converted_key and root_key then
				-- 	-- key is a mod
				-- 	for _, m in pairs(root_key.mods) do
				-- 		if m == converted_key then
				-- 			-- user has re-pressed a root mod key
				-- 			hold_mods_active[converted_key] = true
				-- 			break
				-- 		end
				-- 	end
				--
				-- 	-- mod is not part of keybind
				-- 	-- ignore it
				-- 	return
				-- end

				if converted_key then
					-- user is pressing a mod key, we have to ignore it
					return
				end

				-- key is not defined and not a mod
				if t:opts().stop_on_unknown_key then
					print("unknown key: ", key)
					self:stop()
				end
			end
		end,
		timeout = opts.timeout and opts.timeout > 0 and opts.timeout / 1000,
		timeout_callback = function()
			run(t, true)
			on_stop(t)
		end,
		start_callback = function()
			on_start(t)
		end,
		stop_callback = function()
			on_stop(t)
		end,
	})

	global_keygrabber = grabber
	global_execute = execute
	grabber:start()
end

function M.parse_vim_key(k)
	-- upper alpha (e.g. "S")
	if string.match(k, "^%u$") then
		return {
			{ key = k, mods = { "Shift" }, name = k },
		}
	end

	-- alphanumeric char (e.g. "s", "4")
	if string.match(k, "^%w$") then
		return {
			{ key = k, mods = {}, name = k },
		}
	end

	-- <keysym> (e.g. <BackSpace>, <F11>, <Alt_L>)
	local _, _, keysym = string.find(k, "^<([%w_]+)>$")
	if keysym then
		return {
			{ key = keysym, mods = {}, name = k },
		}
	end

	-- <Mod-key> (e.g. <A-C-BackSpace>, <A- >, <A-*>)
	local _, _, mod_and_key = string.find(k, "^<([%u%-]+.+)>$")
	if mod_and_key then
		local mods = {}
		for mod in string.gmatch(mod_and_key, "%u%-") do
			mod = string.gsub(mod, "%-$", "")
			local modifier = mod_map[mod]
			assert(modifier, string.format("unable to parse modifier: %s in key: %s", mod, k))
			if not vim.tbl_contains(mods, modifier) then
				-- ignore duplicate mods (e.g. <A-A-F1>)
				table.insert(mods, modifier)
			end
		end

		-- get the actual key
		local _, _, key = string.find(mod_and_key, "[%u%-]+%-(.+)$")
		assert(key, string.format("unable to parse key: %s", k))

		-- user might not have defined Shift explicitly as mod when using an
		-- upper alpha as key (<A-K> == <A-S-K>)
		if string.match(key, "^%u$") then
			local shift = mod_map["S"]
			if not vim.tbl_contains(mods, shift) then
				table.insert(mods, shift)
			end
		end

		return {
			{ key = key, mods = mods, name = k },
		}
	end

	assert(string.len(k) == 1, string.format("unable to parse unknown key: %s", k))

	-- we assume it's a special character (e.g. $ or #)

	-- HACK: awful.keygrabber requires for special keys to also specify shift as
	-- mods. This is utterly broken, because for some layouts the
	-- minus key is on the shift layer, but for others layouts not. Therefore we're just
	-- ignoring the shift state by adding the key with and without shift to the
	-- map.

	return {
		{ key = k, mods = {}, name = k },
		{ key = k, mods = { "Shift" }, name = k },
	}
end

function M.add_globalkey_vim(prefix, key)
	local parsed_keys = M.parse_vim_key(key)
	for _, parsed_key in pairs(parsed_keys) do
		awful.keyboard.append_global_keybindings({
			awful.key(parsed_key.mods, parsed_key.key, function()
				M.run(prefix, parsed_key)
			end),
		})
	end
end

-- not used currently
function M.add_globalkey(sequence, parsed_key)
	parsed_key = util.parse_awesome_key(parsed_key)
	awful.keyboard.append_global_keybindings({
		awful.key(parsed_key.mods, parsed_key.key, function()
			M.run(sequence, parsed_key)
		end),
	})
end

-- TODO: rename
-- run inline table
function M.run_tree(tree, opts, name)
	local t = require("motion.tree").create_tree(tree, opts, name)
	if not t then
		return
	end
	return grab(t)
end

-- run root_tree
function M.run(key_sequence, parsed_keybind)
	local t = require("motion.tree")[key_sequence]
	return grab(t, parsed_keybind)
end

function M.setup(opts)
	awesome.connect_signal("xkb::map_changed", function()
		generate_mod_conversion_maps()
	end)

	awesome.connect_signal("motion::fake_input", function(args)
		if type(args) == "string" then
			M.fake_input(args)
			return
		end
		if type(args) == "table" then
			M.fake_input(args.key, args.continue)
			return
		end
	end)

	generate_mod_conversion_maps()

	if opts.key then
		M.add_globalkey_vim("", opts.key)
	end

	print(dump(mod_conversion))
end

return M
