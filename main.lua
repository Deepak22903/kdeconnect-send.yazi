-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Function to run a command and get its output
local function run_command(cmd_args)
	-- Function content unchanged...
	ya.dbg("[kdeconnect-send] Running command: ", table.concat(cmd_args, " "))
	local child, err = Command(cmd_args[1]):args(cmd_args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if err then
		ya.err("[kdeconnect-send] Spawn error: ", err)
		return nil, err
	end
	local output, wait_err = child:wait_with_output()
	ya.dbg("[kdeconnect-send] wait_with_output finished.")
	if wait_err then
		ya.err("[kdeconnect-send] Wait error received: ", wait_err)
		return nil, wait_err
	end
	if not output then
		ya.err("[kdeconnect-send] Wait finished but output object is nil.")
		return nil, Error("Command wait returned nil output")
	end
	ya.dbg("[kdeconnect-send] Command Status Success: ", output.status.success)
	ya.dbg("[kdeconnect-send] Command Status Code: ", output.status.code)
	ya.dbg("[kdeconnect-send] Command Stdout: ", output.stdout or "nil")
	ya.dbg("[kdeconnect-send] Command Stderr: ", output.stderr or "nil")
	if output.stderr and output.stderr:match("^0 devices found") then
		ya.dbg("[kdeconnect-send] Command reported 0 devices found in stderr. Returning empty.")
		return "", nil
	end
	if not output.status.success then
		local error_msg = "Command failed with code "
			.. tostring(output.status.code or "unknown")
			.. ": "
			.. cmd_args[1]
		if output.stderr and #output.stderr > 0 then
			error_msg = error_msg .. "\nStderr: " .. output.stderr
		end
		if output.stdout and #output.stdout > 0 then
			error_msg = error_msg .. "\nStdout: " .. output.stdout
		end
		ya.err("[kdeconnect-send] Command execution failed: ", error_msg)
		return nil, Error(error_msg)
	end
	return output.stdout, nil
end

-- Get selected files AND check for directories (requires sync context)
-- Returns: list of regular file paths, boolean indicating if a directory was selected
local get_selection_details = ya.sync(function() -- Renamed function
	ya.dbg("[kdeconnect-send] Entering get_selection_details sync block")
	local selected_map = cx.active.selected
	local regular_files = {}
	local directory_selected = false -- Flag to track if a directory is selected

	for idx, url in pairs(selected_map) do
		if url then
			-- url.is_regular is the simplest check available in sync context
			-- We assume if it's not regular, it might be a directory we don't want to send.
			if url.is_regular then
				local file_path = tostring(url)
				table.insert(regular_files, file_path)
			else
				-- If it's not a regular file, set the directory flag
				-- We could check url.cha.is_dir but that requires async fs.cha()
				ya.dbg("[kdeconnect-send] Non-regular file selected (likely directory): ", tostring(url))
				directory_selected = true
			end
		else
			ya.err("[kdeconnect-send] Encountered nil URL at index: ", idx)
		end
	end
	ya.dbg(
		"[kdeconnect-send] Exiting get_selection_details sync block. Found regular files: ",
		#regular_files,
		" Directory selected: ",
		directory_selected
	)
	-- Return both the list and the flag
	return regular_files, directory_selected
end)

return {
	entry = function(_, job)
		ya.dbg("[kdeconnect-send] Plugin entry point triggered.") -- Debug log

		-- 1. Get selection details (files and directory flag)
		local selected_files, directory_selected = get_selection_details() -- Call updated function

		-- *** Add check for directory selection FIRST ***
		if directory_selected then
			ya.warn("[kdeconnect-send] Directory selected. Exiting.")
			ya.notify({
				title = "KDE Connect Send",
				content = "Cannot send directories. Please select regular files only.",
				level = "error", -- Use error level
				timeout = 7,
			})
			return -- Exit if a directory was selected
		end

		-- Proceed only if no directory was selected
		ya.dbg("[kdeconnect-send] No directory selected. Checking number of regular files.")
		ya.dbg("[kdeconnect-send] Type of selected_files: ", type(selected_files))
		local len = -1
		if type(selected_files) == "table" then
			len = #selected_files
		end
		ya.dbg("[kdeconnect-send] Length of selected_files (#): ", len)

		-- If no *regular* files selected (and no directories were selected either), show notification and exit
		if len == 0 then
			ya.dbg("[kdeconnect-send] Length is 0. No regular files selected. Showing notification.") -- Debug
			ya.notify({
				title = "KDE Connect Send",
				content = "No regular files selected. Please select at least one file to send.", -- Adjusted message slightly
				level = "warn",
				timeout = 5,
			})
			return
		elseif len > 0 then
			ya.dbg("[kdeconnect-send] Length is > 0. Proceeding with device check.") -- Debug
		else
			-- This case handles potential errors from get_selection_details if it didn't return a table
			ya.err("[kdeconnect-send] Error determining selected files. Type: ", type(selected_files), ". Exiting.")
			ya.notify({
				title = "Plugin Error",
				content = "Could not determine selected files.",
				level = "error",
				timeout = 5,
			})
			return
		end

		-- 2. Get KDE Connect devices (Only runs if len > 0 and no directory selected)
		ya.dbg("[kdeconnect-send] Attempting to list KDE Connect devices with 'kdeconnect-cli -l'...") -- Debug log
		local devices_output, err = run_command({ "kdeconnect-cli", "-l" })

		-- Check for errors from run_command first
		if err then
			ya.err("[kdeconnect-send] Failed to list devices command: ", tostring(err), ". Exiting.") -- Error log
			ya.notify({
				title = "KDE Connect Error",
				content = "Failed to run kdeconnect-cli -l: " .. tostring(err),
				level = "error",
				timeout = 5,
			})
			return
		end

		-- Check if run_command returned empty string (meaning "0 devices found")
		if not devices_output or devices_output == "" then
			ya.dbg("[kdeconnect-send] No connected devices reported by kdeconnect-cli. Exiting silently.") -- Debug log
			-- Removed notification here previously to prevent hang
			return
		end

		-- 3. Parse devices (unchanged)
		local devices = {}
		local device_list_str = "Available Devices:\n"
		local has_reachable = false
		ya.dbg("[kdeconnect-send] Parsing device list (standard format)...")
		local pattern = "^%-%s*(.+):%s*([%w_]+)%s*%((.-)%)$"
		for line in devices_output:gmatch("[^\r\n]+") do
			local name, id, status_line = line:match(pattern)
			if id and name and status_line then
				local is_reachable = status_line:match("reachable")
				name = name:match("^%s*(.-)%s*$")
				if is_reachable then
					table.insert(devices, { id = id, name = name })
					device_list_str = device_list_str .. "- " .. name .. " (ID: " .. id .. ")\n"
					has_reachable = true
				else
					device_list_str = device_list_str .. "- " .. name .. " (ID: " .. id .. ") - Unreachable\n"
				end
			else
				ya.warn("[kdeconnect-send] Could not parse device line with pattern: ", line)
			end
		end

		-- Check if any *reachable* devices were found after parsing
		if not has_reachable then
			ya.dbg(
				"[kdeconnect-send] No *reachable* devices found after parsing. Exiting silently. List:\n",
				device_list_str
			)
			-- Removed notification here previously to prevent hang
			return
		end

		-- 4. Select Device (unchanged, includes single device auto-select and multi-device prompt)
		local device_id = nil
		if #devices == 1 then
			device_id = devices[1].id
			local device_name = devices[1].name
			ya.dbg(
				"[kdeconnect-send] Only one reachable device found: ",
				device_name,
				" (",
				device_id,
				"). Using automatically."
			)
			ya.notify({
				title = "KDE Connect Send",
				content = "Sending to only available device: " .. device_name,
				level = "info",
				timeout = 3,
			})
		else
			-- Prompting logic (unchanged, might still hang on recv)
			ya.dbg("[kdeconnect-send] Multiple reachable devices found. Prompting user...")
			local input_title = device_list_str .. "\nEnter Device ID to send " .. #selected_files .. " files to:"
			local default_value = devices[1].id
			local device_id_input =
				ya.input({ title = input_title, value = default_value, position = { "center", w = 70 } })
			if not device_id_input then
				ya.err("[kdeconnect-send] Failed to create input prompt. Exiting.")
				ya.notify({
					title = "Plugin Error",
					content = "Could not create input prompt.",
					level = "error",
					timeout = 5,
				})
				return
			end
			ya.dbg("[kdeconnect-send] Input prompt created. Waiting for user input... (Might hang)")
			local received_id, event = device_id_input:recv()
			ya.dbg("[kdeconnect-send] Input received. Device ID: ", received_id or "nil", " Event: ", event or "nil")
			if event ~= 1 or not received_id or #received_id == 0 then
				ya.warn("[kdeconnect-send] Input cancelled or invalid (event=" .. tostring(event) .. "). Exiting.")
				ya.notify({ title = "KDE Connect Send", content = "Send cancelled.", level = "info", timeout = 3 })
				return
			end
			device_id = received_id
		end

		-- 5. Validate Device ID (unchanged)
		local valid_id = false
		local target_device_name = "Unknown"
		for _, d in ipairs(devices) do
			if d.id == device_id then
				valid_id = true
				target_device_name = d.name
				break
			end
		end
		if not valid_id then
			ya.err("[kdeconnect-send] Invalid or unreachable Device ID selected: ", device_id, ". Exiting.")
			ya.notify({
				title = "KDE Connect Send",
				content = "Invalid or unreachable Device ID selected: " .. device_id,
				level = "error",
				timeout = 5,
			})
			return
		end
		ya.dbg(
			"[kdeconnect-send] Device ID validated: ",
			device_id,
			" (",
			target_device_name,
			"). Starting file send loop..."
		)

		-- 6. Send files (unchanged)
		local success_count = 0
		local error_count = 0
		for i, file_path in ipairs(selected_files) do
			ya.dbg(
				"[kdeconnect-send] Sending file ",
				i,
				"/",
				#selected_files,
				": ",
				file_path,
				" to ",
				target_device_name
			)
			local _, send_err = run_command({ "kdeconnect-cli", "--share", file_path, "--device", device_id })
			if send_err then
				error_count = error_count + 1
				ya.err("[kdeconnect-send] Failed to send file ", file_path, " to ", device_id, ": ", tostring(send_err))
				ya.notify({
					title = "KDE Connect Error",
					content = "Failed to send: " .. file_path .. "\n" .. tostring(send_err),
					level = "error",
					timeout = 5,
				})
			else
				success_count = success_count + 1
			end
		end

		-- 7. Final Notification (unchanged)
		local final_message =
			string.format("Sent %d/%d files to %s.", success_count, #selected_files, target_device_name)
		local final_level = "info"
		if error_count > 0 then
			final_message = string.format(
				"Sent %d/%d files to %s. %d failed.",
				success_count,
				#selected_files,
				target_device_name,
				error_count
			)
			final_level = "warn"
		end
		if success_count == 0 and error_count > 0 then
			final_level = "error"
		end
		ya.dbg("[kdeconnect-send] Send process completed. Success: ", success_count, " Failed: ", error_count)
		ya.notify({ title = "KDE Connect Send Complete", content = final_message, level = final_level, timeout = 5 })
		ya.dbg("[kdeconnect-send] Plugin execution finished.")
	end,
}
