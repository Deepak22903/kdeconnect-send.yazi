-- Run from the repository root: lua tests/test_share.lua
-- Only KDE Connect and Yazi APIs are faked; mktemp and zip execute for real.
local root = assert(os.getenv("TEST_ROOT"), "Set TEST_ROOT to a scratch directory")
local plugin_path = os.getenv("PLUGIN_PATH") or "main.lua"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function run(cmd)
	local ok = os.execute(cmd)
	assert(ok, cmd)
end
run("mkdir -p " .. quote(root .. "/input/Test folder/nested"))
local f = assert(io.open(root .. "/input/Test folder/nested/data.txt", "w")); f:write("test payload\n"); f:close()
local function scenario(paths, options)
	options = options or {}
	local sends, notices, calls = {}, {}, {}
	_G.Url = function(s) return s end
	_G.fs = { cha = function(path)
		local ok = os.execute("test -d " .. quote(path))
		if ok == true then return { is_dir = true } end
		if os.execute("test -e " .. quote(path) .. " -o -L " .. quote(path)) == true then return { is_dir = false } end
		return nil, "not found"
	end, remove = function(_, path) return os.remove(path) end }
	_G.cx = { active = { selected = {}, current = { hovered = { url = paths[1] } } } }
	if #paths > 1 then
		for _, path in ipairs(paths) do cx.active.selected[path] = true end
		setmetatable(cx.active.selected, { __len = function() return #paths end })
	end
	_G.ya = { sync = function(fn) return fn end, notify = function(n) notices[#notices + 1] = n end,
		which = function() return options.device_choice end }
	_G.Command = setmetatable({ PIPED = 1 }, { __call = function(_, name)
		local cmd = { name = name, args = {}, environment = {} }
		function cmd:env(key, value) self.environment[key] = value; return self end
		function cmd:arg(a) self.args[#self.args + 1] = a; return self end
		function cmd:cwd(p) self.dir = tostring(p); return self end
		function cmd:stdout(_) return self end
		function cmd:stderr(_) return self end
		function cmd:spawn()
			calls[#calls + 1] = self
			if options.missing_zip and name == "zip" then return nil, "zip not found" end
			return { wait_with_output = function()
				if name == "kdeconnect-cli" then
					if self.args[1] == "-a" then
						return { status = { success = true }, stdout = options.devices or "- Test Phone: test-id (paired and reachable)\n1 device found\n", stderr = "" }
					end
					sends[#sends + 1] = self.args[2]
					return { status = { success = not options.send_failure }, stdout = "", stderr = options.send_failure and "offline" or "" }
				end
				local argv = {}
				for _, a in ipairs(self.args) do argv[#argv + 1] = quote(a) end
				local line = quote(name) .. " " .. table.concat(argv, " ")
				for key, value in pairs(self.environment) do line = key .. "=" .. quote(value) .. " " .. line end
				if name == "zip" and options.zipopt then
					line = "ZIPOPT=" .. quote(options.zipopt) .. " ZIP=" .. quote(options.zipopt) .. " " .. line
				end
				if self.dir then line = "cd " .. quote(self.dir) .. " && " .. line end
				if options.zip_failure and name == "zip" then
					local partial = assert(io.open(self.args[5], "w")); partial:write("partial zip"); partial:close()
					return { status = { success = false }, stdout = "", stderr = "No space left on device" }
				end
				local pipe = assert(io.popen("(" .. line .. ") 2>&1"))
				local output = pipe:read("*a"); local ok = pipe:close()
				return { status = { success = ok == true }, stdout = ok and output or "", stderr = ok and "" or output }
			end }
		end
		return cmd
	end })
	local plugin = assert(loadfile(plugin_path))()
	plugin:entry({})
	return sends, notices, calls
end
local sends, notices = scenario({ root .. "/input/Test folder" })
assert(#sends == 1, "directory should be archived and queued instead of rejected: " .. (notices[#notices] and notices[#notices].content or "no notification"))
assert(sends[1]:match("Test folder%.zip$"), "archive must keep the folder name")
assert(io.open(sends[1], "rb")):close() -- Must survive CLI return: transfer is asynchronous.
run("python -c " .. quote("import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist()); assert z.read('Test folder/nested/data.txt') == b'test payload\\n'") .. " " .. quote(sends[1]))
print("PASS: directories become real store-only ZIPs, preserving structure and lifetime")

local ordinary = root .. "/input/Test folder/nested/data.txt"
local direct, _, calls = scenario({ ordinary })
assert(#direct == 1 and direct[1] == ordinary, "regular files should not be archived")
assert(#calls == 2, "regular files should only list devices and share")
print("PASS: ordinary files remain unchanged")

local mixed = scenario({ ordinary, root .. "/input/Test folder" })
assert(#mixed == 2, "mixed file/folder selections should queue both")
local repeated = scenario({ root .. "/input/Test folder/" })
assert(#repeated == 1 and repeated[1] ~= sends[1], "repeat sends use unique locations and accept trailing slash")
print("PASS: mixed selections and repeat sends")

local failed, errors = scenario({ root .. "/input/Test folder" }, { missing_zip = true })
assert(#failed == 0 and errors[#errors].content:match("zip not found"), "missing zip should not queue a transfer")
failed, errors, calls = scenario({ root .. "/input/Test folder" }, { zip_failure = true })
assert(#failed == 0 and errors[#errors].content:match("No space left"), "failed ZIP creation should not queue a transfer")
local partial_path = calls[#calls].args[5]
assert(not io.open(partial_path, "rb"), "failed preparation must remove the partial ZIP")
assert(os.execute("test ! -d " .. quote(partial_path:match("^(.*)/"))) == true, "failed preparation must remove its private directory")
print("PASS: missing zip and archive failures are surfaced")

local none, _, no_calls = scenario({ root .. "/input/Test folder" }, { devices = "0 devices found\n" })
assert(#none == 0 and #no_calls == 1, "no devices should not create an archive")
local cancelled, _, cancel_calls = scenario({ root .. "/input/Test folder" }, { devices = "- Phone A: a (paired and reachable)\n- Phone B: b (paired and reachable)\n" })
assert(#cancelled == 0 and #cancel_calls == 1, "cancelled device picker should not create an archive")
print("PASS: no-device and cancellation avoid unnecessary ZIP creation")

local queued, offline = scenario({ root .. "/input/Test folder" }, { send_failure = true })
assert(#queued == 1 and io.open(queued[1], "rb")):close()
local has_error, has_location = false, false
for _, n in ipairs(offline) do
	if n.level == "error" and n.content:match("offline") then has_error = true end
	if n.content:find(queued[1], 1, true) then has_location = true end
end
assert(has_error and has_location, "failed send preserves ZIP and reports retry location")
print("PASS: failed sends retain their archives without claiming success")

local unusual = root .. "/input/- odd ' ; $(touch INJECTED) ü"
run("mkdir -p " .. quote(unusual))
f = assert(io.open(unusual .. "/payload", "w")); f:write("safe"); f:close()
run("ln -sfn " .. quote(root .. "/input/Test folder") .. " " .. quote(unusual .. "/external"))
local special = scenario({ unusual })
assert(#special == 1, "unusual folder names must work")
run("python -c " .. quote("import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert len(z.infolist()) == 3; assert not any('data.txt' in i.filename for i in z.infolist()); assert all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist())") .. " " .. quote(special[1]))
assert(not io.open(root .. "/input/INJECTED"), "filename must never execute shell syntax")
print("PASS: spaces, quotes, Unicode, leading dashes and external symlinks")

local safety = root .. "/input/Environment safety"
run("mkdir -p " .. quote(safety))
f = assert(io.open(safety .. "/source.txt", "w")); f:write("must survive"); f:close()
local safe_send = scenario({ safety }, { zipopt = "-m" })
assert(#safe_send == 1, "hostile ZIP options should not prevent archiving")
assert(io.open(safety .. "/source.txt", "rb"), "inherited ZIPOPT/ZIP must not delete source files"):close()
print("PASS: inherited ZIPOPT and ZIP cannot delete source files")
