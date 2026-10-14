-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Helper to run commands and capture output
local function run_command(cmd_name, args, cwd, environment)
	local cmd = Command(cmd_name)
	for key, value in pairs(environment or {}) do
		cmd:env(key, value)
	end
	if cwd then
		cmd:cwd(cwd)
	end
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

-- KDE Connect queues transfers, so archives must outlive kdeconnect-cli.
-- Keep them in private temporary directories, never overwrite adjacent files.
local function prepare_share(path)
	local cha, err = fs.cha(Url(path))
	if not cha then
		return nil, "Could not inspect " .. path .. ": " .. tostring(err)
	end
	if not cha.is_dir then
		return path
	end

	local normalized = path:gsub("/+$", "")
	local parent, name = normalized:match("^(.*)/([^/]+)$")
	if not name then
		return nil, "Cannot archive a filesystem root: " .. path
	end
	if parent == "" then parent = "/" end

	local temp, temp_err = run_command("mktemp", { "-d", "-t", "kdeconnect-send.XXXXXX" })
	if not temp or not temp.status.success then
		return nil, "Could not create temporary directory: " .. tostring(temp_err or (temp and temp.stderr))
	end
	local temp_dir = temp.stdout:gsub("\n$", "")
	local archive = temp_dir .. "/" .. name .. ".zip"
	ya.notify({
		title = "KDE Connect Send",
		content = "Packing " .. name .. " into a ZIP without compression...",
		level = "info",
		timeout = 5,
	})
	-- Run from the parent to preserve the folder name without absolute paths.
	-- Store symlinks as links: do not pull in data outside the selected folder.
	-- Ignore inherited defaults: ZIPOPT=-m would delete the source folder.
	local output, zip_err = run_command("zip", { "-0", "-r", "-q", "-y", archive, "--", "./" .. name }, parent,
		{ ZIPOPT = "", ZIP = "" })
	if not output or not output.status.success then
		-- No transfer was queued, so partial output is safe to remove.
		local removed, remove_err = true, nil
		if fs.cha(Url(archive)) then
			removed, remove_err = fs.remove("file", Url(archive))
		end
		local dir_removed, dir_err = fs.remove("dir", Url(temp_dir))
		local message = "Could not archive " .. path .. ": " .. tostring(zip_err or (output and output.stderr))
		if not removed or not dir_removed then
			message = message .. "\nCould not clean temporary location " .. temp_dir .. ": " .. tostring(remove_err or dir_err)
		end
		return nil, message
	end
	return archive, nil, archive
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

		-- 6. Archive directories and queue transfers only after device selection.
		local success_count = 0
		local archives = {}
		for _, path in ipairs(paths) do
			local share_path, prepare_err, archive = prepare_share(path)
			if archive then archives[#archives + 1] = archive end
			local send_output, send_err
			if share_path then
				send_output, send_err = run_command("kdeconnect-cli", { "--share", share_path, "--device", device_id })
			end
			if prepare_err or send_err or not send_output or not send_output.status.success then
				local msg = prepare_err or (send_err and tostring(send_err)) or (send_output and send_output.stderr) or "Unknown error"
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

		-- Archives cannot be deleted on CLI exit: the daemon may still need them.
		if #archives > 0 then
			ya.notify({
				title = "KDE Connect ZIPs",
				content = "Temporary ZIPs kept until you delete them after the transfer finishes:\n" .. table.concat(archives, "\n"),
				level = "info",
				timeout = 15,
			})
		end

		-- 7. Final status
		if success_count > 0 then
			ya.notify({
				title = "KDE Connect Send",
				content = string.format("Queued %d/%d items for sending to %s", success_count, #paths, device_name),
				level = "info",
				timeout = 5,
			})
		end
	end,
}
