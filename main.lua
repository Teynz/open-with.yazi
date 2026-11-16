-- open-with.yazi
--
-- Add every desktop application that can open the selected files to yazi's
-- native "Open with" picker.  The apps are discovered through GIO (the same
-- data Nautilus uses) and injected as temporary opener rules at runtime.
--
-- Requirements:
--   * yazi >= 26.5.6 (dynamic rt.open / rt.opener Lua API)
--   * python3 >= 3.11 + PyGObject (Gio, GioUnix)
--
-- Layout (fork):
--   * assets/open-with-gio  all discovery + storage logic, speaks JSON
--   * UI.*                  the only place that draws menus/prompts; swap
--                           these three functions to use another front end
--   * FLOWS                 one function per action: `plugin open-with`,
--                           `... add`, `... remove`; add new actions there
--
-- Install this directory as:
--   ~/.config/yazi/plugins/open-with.yazi

local PREFIX = "openwith_"
local PLUGIN = "open-with"
local PYTHON = os.getenv("OPEN_WITH_PYTHON") or "python3"

-- Fork change (paul): seconds to wait after emitting `open --interactive`
-- before the temporary openers are removed again.  Yazi copies the opener
-- rules into the picker when it is shown (yazi-actor/src/mgr/open_do.rs), so
-- removing them afterwards does not affect the open menu, but keeps the
-- native `O` menu free of stale system-app entries.
local CLEANUP_DELAY = tonumber(os.getenv("OPEN_WITH_CLEANUP_DELAY") or "") or 1.5

-- Fork change (paul): only accept desktop ids made of safe characters.  The
-- id ends up inside an opener `run` string, which yazi also scans for `%`
-- placeholders; ya.quote() protects the shell, this protects the splatter.
local function safe_id(id)
	return id ~= "" and id:match("^[%w%._%-]+$") ~= nil
end

local DEBUG = os.getenv("OPEN_WITH_DEBUG") == "1"

local function dbg(...)
	if not DEBUG then
		return
	end
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	ya.dbg(table.concat(parts, " "))
end

local TYPE_PATS = {
	"text",
	"image",
	"video",
	"application",
	"audio",
	"font",
	"inode",
	"message",
	"model",
	"vector",
	"biosig",
	"chemical",
	"rinex",
	"x%-epoc",
}

local function helper_path()
	return tostring(rt.path.config_dir) .. "/plugins/" .. PLUGIN .. ".yazi/assets/open-with-gio"
end

local function strip_temp(use)
	local out = {}
	for _, name in ipairs(use or {}) do
		if not name:match("^" .. PREFIX) then
			out[#out + 1] = name
		end
	end
	return out
end

-- Keep this in sync with yazi's own mime.local preset: yazi removes the `x-`
-- and `vnd.` prefixes, and uses inode/empty for empty files.  GIO uses
-- shared-mime-info names instead (e.g. application/x-zerosize), so the two
-- must not be mixed when looking up yazi's open rules.
local function normalize_mime(line)
	for _, pat in ipairs(TYPE_PATS) do
		local typ, sub = line:match(string.format("(%s/)([+-.a-zA-Z0-9]+)%%s*$", pat))
		if sub then
			if line:find(typ .. sub, 1, true) == 1 then
				return (typ:gsub("^x%-", "", 1) .. sub:gsub("^x%-", "", 1):gsub("^vnd%.", "", 1))
			end
			return nil
		end
	end
	return nil
end

local function mime_of(path)
	local ok, line = pcall(function()
		local p = io.popen("file -bL --mime-type -- " .. ya.quote(path))
		if not p then
			return nil
		end
		local l = p:read("*l")
		p:close()
		return l
	end)
	if not ok or not line then
		return nil
	end
	return normalize_mime(line)
end

local function is_local(file)
	local ok, regular = pcall(function()
		return file.url.spec.is_regular
	end)
	return ok and regular == true
end

local function is_dir(file)
	local ok, dir = pcall(function()
		return file.cha.is_dir
	end)
	return ok and dir == true
end

local function selected_files()
	local files = {}
	for _, f in pairs(cx.active.selected) do
		files[#files + 1] = f
	end
	if #files == 0 then
		local h = cx.active.current.hovered
		if h then
			files[1] = h
		end
	end
	return files
end

-- Runs in yazi's sync context: this is the only place where cx is safe to
-- read.  We return plain data plus rule ids (ids are small userdata values;
-- returning them from ya.sync() works in yazi 26.9).
local collect = ya.sync(function()
	local files = selected_files()
	if #files == 0 then
		return { error = "No file selected" }
	end

	local out = {}
	local seen = {}
	for _, f in ipairs(files) do
		-- Directories and virtual files do not have a useful GIO "open with"
		-- list here; keep yazi's own openers and skip the system apps.
		if not is_local(f) or is_dir(f) then
			return { native = true }
		end

		local ok, path = pcall(function()
			return tostring(f.path)
		end)
		if not ok or not path or path == "" then
			local ok_url, urlpath = pcall(function()
				return tostring(f.url.path)
			end)
			if ok_url and urlpath and urlpath ~= "" then
				path = urlpath
			else
				return { error = "Cannot resolve the selected file path" }
			end
		end

		if not seen[path] then
			seen[path] = true

			-- cx.active.selected yields base File values (no fs::File:mime()).
			-- Normal file errors are caught here so a mixed selection falls
			-- back to the native picker instead of aborting the sync block.
			local mime
			local ok_mime, value = pcall(function()
				return f:mime()
			end)
			if ok_mime then
				mime = value
			end
			if not mime then
				mime = mime_of(path)
			end
			if not mime then
				return { error = "Cannot determine MIME type for " .. path }
			end

			-- rule matching needs a File userdata accepted by FileRef.  A base
			-- File constructed from url+cha works for both hovered fs.File
			-- values and selected base File values.
			local base
			local ok_base, converted = pcall(function()
				return File(f)
			end)
			if ok_base then
				base = converted
			else
				local ok_table, built = pcall(function()
					return File { url = f.url, cha = f.cha, extra = { link_to = nil } }
				end)
				if not ok_table then
					return { error = "Cannot convert selected file: " .. tostring(built) }
				end
				base = built
			end

			local rule
			for _, r in pairs(rt.open.rules:match({ file = base, mime = mime })) do
				rule = r
				break
			end
			if not rule then
				return { error = "No open rule matches " .. path }
			end

			local use = {}
			for _, name in ipairs(rule.use) do
				use[#use + 1] = name
			end

			out[#out + 1] = {
				path = path,
				mime = mime,
				rule_id = rule.id,
				use = use,
			}
		end
	end

	if #out == 0 then
		return { error = "No file selected" }
	end
	return { files = out }
end)

-- ---------------------------------------------------------------------------
-- Helper bridge
-- ---------------------------------------------------------------------------

local function config_path()
	return tostring(rt.path.config_dir) .. "/open-with.toml"
end

local function label(s)
	return (tostring(s or ""):gsub("[%c]", " "))
end

-- Runs the Python helper and returns its decoded JSON, or nil + message.
local function helper(args, paths)
	local cmd = Command(PYTHON):arg(helper_path()):arg(args)
	if paths then
		cmd = cmd:arg("--"):arg(paths)
	end

	local out, err = cmd:output()
	if not out then
		return nil, "Cannot run the GIO helper: " .. tostring(err)
	end

	local data, decode_err = ya.json_decode(out.stdout)
	if not data then
		local stderr = tostring(out.stderr or "")
		return nil, "Invalid GIO helper output: " .. (stderr ~= "" and stderr or tostring(decode_err))
	end
	if data.error then
		return nil, tostring(data.error)
	end
	return data
end

-- ---------------------------------------------------------------------------
-- UI primitives (yazi-native).  Nothing else calls ya.which / ya.input.
-- ---------------------------------------------------------------------------

local KEYS = "abcdefghijklmnopqrstuvwxyz"
local UI = {}

function UI.notify(message, level)
	ya.notify {
		title = "Open with",
		content = tostring(message),
		timeout = 5,
		level = level or "info",
	}
end

-- items: { { desc = "...", key = "x" (optional) }, ... } -> chosen index or nil.
-- Items without a key get a, b, c, ... in order.
function UI.menu(items)
	local cands, auto = {}, 0
	for i, item in ipairs(items) do
		local key = item.key
		if not key then
			auto = auto + 1
			key = KEYS:sub(auto, auto)
		end
		cands[i] = { on = key, desc = label(item.desc) }
	end
	return ya.which { cands = cands, silent = false }
end

function UI.ask(title)
	local value, event = ya.input {
		title = title,
		pos = { "top-center", y = 3, w = 50 },
	}
	if event == 1 and value and value ~= "" then
		return value
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Temporary openers
-- ---------------------------------------------------------------------------

-- Removes every temporary opener and strips its name from all open rules.
-- Must run in the sync context.
local function purge()
	local old = {}
	for name in pairs(rt.opener) do
		if name:match("^" .. PREFIX) then
			old[#old + 1] = name
		end
	end
	for _, name in ipairs(old) do
		rt.opener[name] = nil
	end

	for _, rule in pairs(rt.open.rules:match()) do
		local use = strip_temp(rule.use)
		if #use ~= #rule.use and #use > 0 then
			rt.open.rules:update({ id = rule.id }, { use = use })
		end
	end
	return #old
end

-- Deferred cleanup.  `gen` guards against a second invocation started within
-- CLEANUP_DELAY: only the newest run cleans up.
local cleanup = ya.sync(function(self, gen)
	if self.gen ~= gen then
		return 0
	end
	local n = purge()
	dbg("cleanup gen=" .. tostring(gen) .. " removed=" .. tostring(n))
	return n
end)

-- Runs in the sync context.  Registers, in menu order:
--   custom openers (config file) -> system apps (GIO) -> Add / Remove / Edit
-- and appends them to the rules matched in collect().  The rule's own
-- openers stay first, so plain Enter/`O` behaviour is never changed.
local install = ya.sync(function(self, state, data, cfg)
	dbg("removed old=" .. tostring(purge()))
	self.gen = (self.gen or 0) + 1

	local bin = helper_path()
	local names, taken = {}, {}
	local function register(key, rule)
		rt.opener[key] = { rule }
		names[#names + 1] = key
	end
	-- GIO does the actual launch, so Terminal=true, flatpak apps and field
	-- codes are handled correctly.
	local function launch_cmd(id)
		return string.format("%s %s --launch %s -- %%s", ya.quote(PYTHON), ya.quote(bin), ya.quote(id))
	end

	for i, c in ipairs(data.custom or {}) do
		local key = PREFIX .. "-custom-" .. i
		if c.app then
			local id = tostring(c.app)
			if safe_id(id) then
				taken[id] = true
				register(key, { run = launch_cmd(id), desc = label(c.name), orphan = true })
			end
		elseif c.run and tostring(c.run) ~= "" then
			register(key, {
				run = tostring(c.run),
				desc = label(c.name),
				block = c.block == true,
				orphan = c.orphan == true,
			})
		end
	end

	for _, app in ipairs(data.apps or {}) do
		local id = tostring(app.id or "")
		if safe_id(id) and not taken[id] then
			local desc = label(app.name or id)
			if app.default then
				desc = "* " .. desc
			end
			register(PREFIX .. id:gsub("[^%w_%-%.]", "_"), { run = launch_cmd(id), desc = desc, orphan = true })
		end
	end

	register(PREFIX .. "-add", {
		run = "ya emit plugin " .. PLUGIN .. " add",
		desc = "[+] Add opener",
	})
	register(PREFIX .. "-remove", {
		run = "ya emit plugin " .. PLUGIN .. " remove",
		desc = "[-] Remove opener",
	})
	register(PREFIX .. "-edit", {
		run = string.format("%s %s --edit --config=%s", ya.quote(PYTHON), ya.quote(bin), ya.quote(cfg)),
		desc = "[~] Edit openers",
		block = true,
	})

	-- Files sharing a rule are updated only once.
	local done = {}
	for _, file in ipairs(state.files) do
		local key = tostring(file.rule_id)
		if not done[key] then
			done[key] = true
			local use = strip_temp(file.use)
			for _, name in ipairs(names) do
				use[#use + 1] = name
			end
			rt.open.rules:update({ id = file.rule_id }, { use = use })
		end
	end

	dbg("installed names=" .. tostring(#names))
	return self.gen
end)

-- ---------------------------------------------------------------------------
-- Flows
-- ---------------------------------------------------------------------------

local function native_picker(message, level)
	if message and message ~= "" then
		UI.notify(message, level or "warn")
	end
	ya.emit("open", { interactive = true })
end

local function paths_of(state)
	local paths = {}
	for _, file in ipairs(state.files) do
		paths[#paths + 1] = file.path
	end
	return paths
end

-- `plugin open-with`: native picker + custom openers + system apps.
local function flow_open()
	local ok, state = pcall(collect)
	if not ok then
		return native_picker("Cannot read yazi state: " .. tostring(state), "error")
	end
	if not state or state.error then
		return native_picker(state and state.error or "No file selected")
	end
	if state.native then
		return native_picker()
	end

	local cfg = config_path()
	local data, err = helper({ "--list", "--config=" .. cfg }, paths_of(state))
	if not data then
		return native_picker(err)
	end
	if data.config_errors and #data.config_errors > 0 then
		UI.notify("open-with.toml: " .. table.concat(data.config_errors, "; "), "warn")
	end

	local installed, gen = pcall(install, state, data, cfg)
	if not installed then
		return native_picker("Cannot install openers: " .. tostring(gen), "error")
	end

	-- The native picker is built from YAZI.opener + YAZI.open, so the
	-- openers installed above show up here together with edit/reveal/etc.
	ya.emit("open", { interactive = true })

	-- Remove the temporary entries once the picker has captured them, so the
	-- native `O` menu stays untouched.
	if CLEANUP_DELAY > 0 then
		ya.sleep(CLEANUP_DELAY)
		pcall(cleanup, gen)
	end
end

-- Shared start of add/remove: selected files + what the helper knows.
local function gather(what)
	local ok, state = pcall(collect)
	if not ok or not state or state.error or state.native then
		local why = (ok and state and state.error) or "nur fuer lokale Dateien (keine Ordner)"
		UI.notify(what .. ": " .. tostring(why), "warn")
		return nil
	end
	local cfg = config_path()
	local data, err = helper({ "--list", "--config=" .. cfg }, paths_of(state))
	if not data then
		UI.notify(err, "error")
		return nil
	end
	if not (data.mimes and data.mimes[1]) then
		UI.notify(what .. ": MIME-Typ unbekannt", "warn")
		return nil
	end
	return data, cfg
end

local function named(list)
	local items = {}
	for i = 1, math.min(#list, #KEYS) do
		items[i] = { desc = list[i].name }
	end
	return items
end

-- Step 1 of "add": apps known for this type, search by name, or a command.
-- Returns { id =, name = } for a desktop app or { run =, name = }.
local function pick_app(apps)
	local items = named(apps)
	local shown = #items
	items[shown + 1] = { key = "/", desc = "Andere App suchen ..." }
	items[shown + 2] = { key = "!", desc = "Eigener Befehl ..." }

	local idx = UI.menu(items)
	if not idx then
		return nil
	elseif idx <= shown then
		return apps[idx]
	end

	if idx == shown + 2 then
		local run = UI.ask("Befehl (%s = Dateien):")
		if not run then
			return nil
		end
		if not run:find("%", 1, true) then
			run = run .. " %s"
		end
		local name = UI.ask("Anzeigename:")
		if not name then
			return nil
		end
		return { run = run, name = name }
	end

	local query = UI.ask("App-Name (Teil genuegt):")
	if not query then
		return nil
	end
	local found, err = helper { "--search=" .. query }
	if not found then
		UI.notify(err, "error")
		return nil
	end
	local hits = found.apps or {}
	if #hits == 0 then
		UI.notify('Keine App gefunden fuer "' .. query .. '"', "warn")
		return nil
	end
	idx = UI.menu(named(hits))
	return idx and hits[idx] or nil
end

-- Step 2 of "add": what the new opener applies to.
-- m/e/b -> own config file (Alt+O only); x -> system-wide XDG association,
-- offered only for desktop apps (XDG cannot store commands or extensions).
local function pick_scope(mime, ext, allow_xdg)
	local items, scopes = {}, {}
	local function option(key, desc, scope)
		items[#items + 1] = { key = key, desc = desc }
		scopes[#scopes + 1] = scope
	end
	option("m", "MIME-Typ: " .. tostring(mime), { mime = mime })
	if ext and ext ~= "" then
		option("e", "Endung: ." .. ext, { ext = ext })
		option("b", "Beides", { mime = mime, ext = ext })
	end
	if allow_xdg then
		option("x", "Systemweit (xdg): " .. tostring(mime), { xdg = true })
	end
	if #items == 1 then
		return scopes[1]
	end

	local scope = scopes[UI.menu(items) or 0]
	if not scope or not scope.xdg then
		return scope
	end
	local role = UI.menu {
		{ key = "a", desc = 'Zu "Oeffnen mit" hinzufuegen' },
		{ key = "s", desc = "Als Standard-App setzen" },
	}
	if not role then
		return nil
	end
	return { xdg = true, default = role == 2 }
end

-- `plugin open-with add`: pick app -> pick scope -> save -> reopen picker.
local function flow_add()
	local data, cfg = gather("Add opener")
	if not data then
		return
	end
	local mime = data.mimes[1]

	local app = pick_app(data.apps or {})
	if not app then
		return
	end
	local is_app = app.run == nil
	if is_app and not safe_id(tostring(app.id or "")) then
		return
	end
	local scope = pick_scope(mime, data.ext, is_app)
	if not scope then
		return
	end

	local args
	if scope.xdg then
		args = { "--xdg-add", "--app=" .. app.id, "--mime=" .. mime }
		if scope.default then
			args[#args + 1] = "--default"
		end
	else
		local what = is_app and ("--app=" .. app.id) or ("--run=" .. app.run)
		args = { "--add", "--config=" .. cfg, what, "--name=" .. label(app.name) }
		if scope.mime then
			args[#args + 1] = "--mime=" .. scope.mime
		end
		if scope.ext then
			args[#args + 1] = "--ext=" .. scope.ext
		end
	end
	local res, err = helper(args)
	if not res then
		return UI.notify(err, "error")
	end

	local name = label(app.name)
	if res.status == "exists" then
		UI.notify(name .. " ist bereits eingetragen")
	elseif res.status == "default" then
		UI.notify(name .. " ist jetzt Standard fuer " .. mime .. " (systemweit)")
	elseif scope.xdg then
		UI.notify(name .. " systemweit hinzugefuegt fuer " .. mime)
	else
		UI.notify(name .. " hinzugefuegt")
	end
	return flow_open()
end

-- `plugin open-with remove`: pick an entry -> delete / hide / xdg-remove.
local function flow_remove()
	local data, cfg = gather("Remove opener")
	if not data then
		return
	end
	local mime = data.mimes[1]

	-- Same order as the menu: custom openers first, then system apps.
	local list = {}
	for _, c in ipairs(data.custom or {}) do
		list[#list + 1] = { name = c.name, index = c.index }
	end
	for _, app in ipairs(data.apps or {}) do
		list[#list + 1] = { name = app.name, id = app.id }
	end
	if #list == 0 then
		return UI.notify("Remove opener: keine eigenen oder System-Eintraege fuer diese Datei")
	end
	local target = list[UI.menu(named(list)) or 0]
	if not target then
		return
	end

	local args, done
	if target.index then
		args = { "--remove", "--config=" .. cfg, "--index=" .. tostring(target.index) }
		done = " entfernt"
	elseif safe_id(tostring(target.id or "")) then
		local how = UI.menu {
			{ key = "h", desc = "Nur hier ausblenden (fuer " .. mime .. ")" },
			{ key = "x", desc = "Systemweit entfernen (xdg)" },
		}
		if how == 1 then
			args = { "--hide", "--config=" .. cfg, "--app=" .. target.id, "--mime=" .. mime }
			done = " ausgeblendet"
		elseif how == 2 then
			args = { "--xdg-remove", "--app=" .. target.id, "--mime=" .. mime }
			done = " systemweit entfernt fuer " .. mime
		end
	end
	if not args then
		return
	end

	local res, err = helper(args)
	if not res then
		return UI.notify(err, "error")
	end
	if res.status == "still-default" then
		UI.notify(label(target.name) .. " bleibt Standard: keine andere App fuer " .. mime, "warn")
	else
		UI.notify(label(target.name) .. done)
	end
	return flow_open()
end

-- Action name (first plugin argument) -> flow.  Default: "open".
local FLOWS = {
	open = flow_open,
	add = flow_add,
	remove = flow_remove,
}

return {
	entry = function(_, job)
		if ya.target_os and ya.target_os() ~= "linux" then
			return native_picker("System application discovery is Linux-only")
		end
		if not rt.open or not rt.opener then
			return native_picker("Yazi 26.5.6+ is required for dynamic openers", "error")
		end

		local action = job and job.args and job.args[1] or "open"
		local flow = FLOWS[tostring(action)]
		if not flow then
			return UI.notify("Unbekannte Aktion: " .. tostring(action), "error")
		end
		return flow()
	end,
}
