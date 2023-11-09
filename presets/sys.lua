local mt = require("modalisa.presets.metatable")
local awful = require("awful")
---@diagnostic disable-next-line: unused-local
local dump = require("modalisa.lib.vim").inspect

local M = {}

local function volume_show(opts)
	local amixer_get_master = [[bash -c 'amixer get Master']]
	awful.spawn.easy_async(amixer_get_master, function(stdout)
		local vol, status = string.match(stdout, "([%d]+)%%.*%[([%l]*)")
		if status == "off" then
			require("modalisa.ui.echo").show_simple("volume", "muted", opts)
		else
			local value = tonumber(vol) / 100
			require("modalisa.ui.echo").show_simple("volume", value, opts)
		end
	end)
end

local function volume_toggle_cmd()
	return "amixer -D pulse set Master 1+ toggle"
end

local function volume_cmd(inc)
	local sign = "+"
	if inc < 0 then
		sign = "-"
	end
	local cmd = string.format("amixer set Master %s%%%s > /dev/null 2>&1", inc, sign)
	return cmd
end

function M.volume_inc(inc)
	return mt({
		group = "volume",
		desc = "volume",
		opts = {
			echo = {
				show_percentage_as_progressbar = true,
			},
		},
		function(opts)
			local cmd = volume_cmd(inc)
			awful.spawn.easy_async_with_shell(cmd, function()
				volume_show(opts)
			end)
		end,
	})
end

function M.volume_mute_toggle()
	return mt({
		group = "volume",
		desc = "mute toggle",
		opts = {
			echo = {
				show_percentage_as_progressbar = true,
			},
		},
		function(opts)
			local cmd = volume_toggle_cmd()
			awful.spawn.easy_async_with_shell(cmd, function()
				volume_show(opts)
			end)
		end,
	})
end

function M.power_shutdown()
	return mt({
		group = "power.shutdown",
		desc = "shutdown",
		function()
			awful.spawn("shutdown -h 0")
		end,
		result = { shutdown = "" },
	})
end

function M.power_shutdown_cancel()
	return mt({
		group = "power.shutdown",
		desc = "cancel shutdown timer",
		function()
			awful.spawn("shutdown -c")
		end,
		result = { shutdown = "cancled" },
	})
end

function M.power_shutdown_timer()
	return mt({
		group = "power.shutdown",
		desc = "shutdown timer",
		function(opts)
			local header = "shutdown in minutes:"
			local initial = 60
			local fn = function(x)
				local min = tonumber(x)
				if not min then
					return
				end
				local cmd = string.format("shutdown -P +%d", min)
				awful.spawn(cmd)
				require("modalisa.ui.echo").show_simple("shutdown", string.format("in %d minutes", min))
			end
			awesome.emit_signal("modalisa::prompt", fn, initial, header, opts)
		end,
	})
end

function M.power_suspend()
	return mt({
		group = "power.suspend",
		desc = "suspend",
		function()
			awful.spawn("suspend")
		end,
		result = { suspend = "" },
	})
end

function M.power_reboot()
	return mt({
		group = "power.reboot",
		desc = "reboot",
		function()
			awful.spawn("reboot")
		end,
		result = { reboot = "" },
	})
end

return M
