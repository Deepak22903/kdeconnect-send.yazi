-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Helper to run commands and capture output
local function run_command(cmd_name, args)
	local cmd = Command(cmd_name)
	for _, arg in ipairs(args) do
		cmd:arg(arg)
	end

	local child, err = cmd
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if not child then
		return nil, err
	end

	return child:wait_with_output()
end

-- Sync block to fetch selected file paths
local get_selected_paths = ya.sync(function()
	local tab = cx.active
	local selected = tab.selected
	local paths = {}

	if #selected == 0 then
		local h = tab.current.hovered
		if h then
			table.insert(paths, tostring(h.url))
		end
	else
		for url, _ in pairs(selected) do
			table.insert(paths, tostring(url))
		end
	end
	return paths
end)

return {
	entry = function(_, job)
		-- 1. Get selected file paths
		local paths = get_selected_paths()
		if #paths == 0 then
			ya.notify({
				title = "KDE Connect Send",
				content = "No files selected.",
				level = "warn",
				timeout = 3,
			})
			return
		end

		-- 2. Check for directories (KDE Connect sharing works best for regular files)
		for _, path in ipairs(paths) do
			local cha, err = fs.cha(Url(path))
			if cha and cha.is_dir then
				ya.notify({
					title = "KDE Connect Send",
					content = "Sending directories is not supported. Please select files only.",
					level = "error",
					timeout = 5,
				})
				return
			end
		end

		-- 3. Get available KDE Connect devices
		local output, err = run_command("kdeconnect-cli", { "-a" })
		if err or not output.status.success then
			local msg = err and tostring(err) or (output and output.stderr or "Unknown error")
			-- If it's just "0 devices found", it might be reported in stderr or stdout
			if msg:match("0 devices found") or (output and output.stdout:match("0 devices found")) then
				ya.notify({
					title = "KDE Connect Send",
					content = "No available KDE Connect devices found.",
					level = "warn",
					timeout = 5,
				})
			else
				ya.notify({
					title = "KDE Connect Error",
					content = "Failed to list devices: " .. msg,
					level = "error",
					timeout = 5,
				})
			end
			return
		end

		-- 4. Parse devices
		local devices = {}
		local stdout = output.stdout or ""
		for line in stdout:gmatch("[^\r\n]+") do
			-- Extract name and ID, then optionally status
			local name, id = line:match("[%-%s]*(.-):%s*([^%s%(%)]+)")
			if name and id then
				local status = line:match("%((.-)%)") or "available"
				table.insert(devices, {
					name = name:gsub("^%s*(.-)%s*$", "%1"), -- Trim whitespace
					id = id,
					status = status,
				})
			end
		end

		if #devices == 0 then
			-- Check if stdout contains a "0 devices found" type message
			if stdout:match("0 devices found") or stdout:match("no devices") then
				ya.notify({
					title = "KDE Connect Send",
					content = "No available KDE Connect devices found.",
					level = "warn",
					timeout = 5,
				})
			else
				ya.notify({
					title = "KDE Connect Error",
					content = "Could not parse devices. Output was: " .. stdout:sub(1, 50) .. (stdout:len() > 50 and "..." or ""),
					level = "error",
					timeout = 10,
				})
			end
			return
		end

		-- 5. Select Device
		local device_id = nil
		local device_name = ""

		if #devices == 1 then
			device_id = devices[1].id
			device_name = devices[1].name
		else
			local cands = {}
			for i, dev in ipairs(devices) do
				table.insert(cands, { on = tostring(i), desc = string.format("%s (%s)", dev.name, dev.status) })
			end

			local idx = ya.which({ cands = cands })
			if not idx or not devices[idx] then
				return
			end
			device_id = devices[idx].id
			device_name = devices[idx].name
		end

		-- 6. Send files
		local success_count = 0
		for _, path in ipairs(paths) do
			local send_output, send_err = run_command("kdeconnect-cli", { "--share", path, "--device", device_id })
			if send_err or (send_output and not send_output.status.success) then
				local msg = send_err and tostring(send_err) or (send_output and send_output.stderr or "Unknown error")
				ya.notify({
					title = "KDE Connect Error",
					content = "Failed to send " .. path .. ": " .. msg,
					level = "error",
					timeout = 5,
				})
			else
				success_count = success_count + 1
			end
		end

		-- 7. Final status
		if success_count > 0 then
			ya.notify({
				title = "KDE Connect Send",
				content = string.format("Successfully sent %d/%d files to %s", success_count, #paths, device_name),
				level = "info",
				timeout = 5,
			})
		end
	end,
}
