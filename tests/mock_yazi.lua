-- Minimaler Yazi-Mock: prueft Ablauf und Reihenfolge, nicht Yazi selbst.
local calls, replies, whichq, inputq, emitted, notes = {}, {}, {}, {}, {}, {}
local st = {}
local rules = { { id = 7, use = { "edit", "reveal" } } }
local opener = {}
rt = { path = { config_dir = "/cfg" }, opener = opener,
  open = { rules = {
    match = function() return rules end,
    update = function(_, m, t) for _, r in ipairs(rules) do if r.id == m.id then r.use = t.use end end end } } }
local hov = { url = { spec = { is_regular = true } }, cha = { is_dir = false }, path = "/h/a b.pdf",
  mime = function() return "application/pdf" end }
cx = { active = { selected = {}, current = { hovered = hov } } }
File = function(f) return f end
local C = {}; C.__index = C
function C:arg(a) if type(a) == "table" then for _, v in ipairs(a) do self.a[#self.a + 1] = v end else self.a[#self.a + 1] = a end return self end
function C:output() calls[#calls + 1] = self.a; return { stdout = "x", stderr = "" } end
Command = function(bin) return setmetatable({ a = { bin } }, C) end
ya = { sync = function(f) return function(...) return f(st, ...) end end,
  quote = function(s) return "'" .. s .. "'" end, dbg = function() end, sleep = function() end,
  target_os = function() return "linux" end,
  json_decode = function() return table.remove(replies, 1) end,
  which = function(t) whichq.last = t.cands; return table.remove(whichq, 1) end,
  input = function() return table.remove(inputq, 1), 1 end,
  notify = function(t) notes[#notes + 1] = t.content end,
  emit = function(n, a) emitted[#emitted + 1] = n end }
local plugin = dofile(arg[1])
local ok = true
local function check(c, m) print((c and "PASS " or "FAIL ") .. m); ok = ok and c end
local LIST = function() return { mimes = { "application/pdf" }, ext = "pdf", config_errors = {},
  apps = { { id = "org.kde.okular.desktop", name = "Okular", default = true }, { id = "gimp.desktop", name = "GIMP" },
           { id = "evil;rm.desktop", name = "Evil" } },
  custom = { { name = "Mein GIMP", app = "gimp.desktop", block = false, orphan = true, index = 1 },
             { name = "mpv audio", run = "mpv --no-video %s", block = true, orphan = false, index = 3 } } } end

-- 1) open
ya.sleep = function() st.snapshot = table.concat(rules[1].use, ",") end
replies = { LIST() }
plugin.entry(nil, { args = {} })
check(st.snapshot == "edit,reveal,openwith_-custom-1,openwith_-custom-2,openwith_org.kde.okular.desktop,openwith_-add,openwith_-remove,openwith_-edit",
  "Reihenfolge: Regel, custom, System (ohne Duplikat/unsichere ID), Add, Remove, Edit\n     " .. tostring(st.snapshot))
check(emitted[1] == "open", "nativer Picker geoeffnet")
check(table.concat(rules[1].use, ",") == "edit,reveal" and next(opener) == nil, "Cleanup: Regel + Opener wieder sauber")
check(table.concat(calls[1], " ") == "python3 /cfg/plugins/open-with.yazi/assets/open-with-gio --list --config=/cfg/open-with.toml -- /h/a b.pdf", "Helfer-Aufruf list")

-- Inhalte der Opener pruefen (ohne Cleanup)
ya.sleep = function()
  check(opener["openwith_-custom-2"][1].run == "mpv --no-video %s" and opener["openwith_-custom-2"][1].block == true, "custom run + block")
  check(opener["openwith_-custom-1"][1].run:find("--launch 'gimp.desktop' -- %s", 1, true) ~= nil, "custom app startet ueber Helfer")
  check(opener["openwith_org.kde.okular.desktop"][1].desc == "* Okular", "Standard-App markiert")
  check(opener["openwith_-add"][1].run == "ya emit plugin open-with add", "Add-Eintrag")
  check(opener["openwith_-edit"][1].block == true and opener["openwith_-edit"][1].run:find("--edit --config='/cfg/open-with.toml'", 1, true) ~= nil, "Edit-Eintrag")
end
replies = { LIST() }; plugin.entry(nil, { args = {} })

-- 2) add: App b (GIMP), Scope "beides"
ya.sleep = function() end
calls, notes = {}, {}
replies = { LIST(), { status = "added" }, LIST() }
whichq = { 2, 3 }
plugin.entry(nil, { args = { "add" } })
check(table.concat(calls[2], " ") == "python3 /cfg/plugins/open-with.yazi/assets/open-with-gio --add --config=/cfg/open-with.toml --app=gimp.desktop --name=GIMP --mime=application/pdf --ext=pdf", "add: Helfer-Argumente (both)")
check(notes[1] == "GIMP hinzugefuegt" and #calls == 3, "add: Meldung + Menue erneut geoeffnet")

-- 3) add ueber Suche, Scope Endung
calls = {}; replies = { LIST(), { apps = { { id = "vlc.desktop", name = "VLC" } } }, { status = "exists" }, LIST() }
whichq = { 4, 1, 2 }; inputq = { "vlc" }  -- 4 = "/"
plugin.entry(nil, { args = { "add" } })
check(calls[2][3] == "--search=vlc", "add: Suche")
check(table.concat(calls[3], " "):find("--app=vlc.desktop --name=VLC --ext=pdf", 1, true) ~= nil and not table.concat(calls[3], " "):find("--mime", 1, true), "add: nur Endung")

-- 4) Abbruch im Menue -> nichts geschrieben
calls = {}; replies = { LIST() }; whichq = {}
plugin.entry(nil, { args = { "add" } })
check(#calls == 1, "add: Esc bricht ab, kein Schreibzugriff")

-- 5) Ordner -> nativer Picker / Add-Hinweis; unbekannte Aktion
hov.cha.is_dir = true; emitted, calls, notes = {}, {}, {}
plugin.entry(nil, { args = {} }); check(emitted[1] == "open" and #calls == 0, "Ordner: nativer Picker ohne Helfer")
plugin.entry(nil, { args = { "add" } }); check(#calls == 0 and notes[1]:find("lokale Dateien", 1, true) ~= nil, "Ordner: add meldet Hinweis")
plugin.entry(nil, { args = { "nope" } }); check(notes[#notes]:find("Unbekannte Aktion", 1, true) ~= nil, "unbekannte Aktion")

-- 6) add systemweit (xdg): als Standard / nur hinzufuegen
hov.cha.is_dir = false
local function run(action, which, input, reps)
  calls, notes = {}, {}; whichq = which; inputq = input or {}; replies = reps
  plugin.entry(nil, { args = { action } })
end
local function line(i) return table.concat(calls[i], " ") end
run("add", { 1, 4, 2 }, nil, { LIST(), { status = "default" }, LIST() })
check(line(2):find("--xdg-add --app=org.kde.okular.desktop --mime=application/pdf --default", 1, true) ~= nil, "add x + s: xdg Standard")
check(whichq.last[1].on == "a" and whichq.last[2].on == "s", "add x: Rollenfrage a/s")
run("add", { 1, 4, 1 }, nil, { LIST(), { status = "added" }, LIST() })
check(line(2):find("--xdg-add", 1, true) ~= nil and not line(2):find("--default", 1, true) and not line(2):find("--config", 1, true), "add x + a: ohne --default, ohne Config")
run("add", { 1, 4 }, nil, { LIST() })
check(#calls == 1, "add x: Esc bei Rolle bricht ab")

-- 7) eigener Befehl: %s wird ergaenzt, kein x im Scope-Menue
run("add", { 5, 1 }, { "mpv --no-video", "mpv Audio" }, { LIST(), { status = "added" }, LIST() })
check(line(2):find("--run=mpv --no-video %s --name=mpv Audio --mime=application/pdf", 1, true) ~= nil and not line(2):find("--app", 1, true), "add !: Befehl + Name")
run("add", { 5 }, { "mpv --no-video", "mpv Audio" }, { LIST() })
check(#whichq.last == 3 and whichq.last[3].on == "b", "add !: Scope ohne x")

-- 8) remove: eigener Eintrag (Index aus Datei), ausblenden, xdg
run("remove", { 2 }, nil, { LIST(), { status = "removed", name = "mpv audio" }, LIST() })
check(line(2):find("--remove --config=/cfg/open-with.toml --index=3", 1, true) ~= nil and notes[1] == "mpv audio entfernt", "remove: eigener Eintrag per Datei-Index")
run("remove", { 3, 1 }, nil, { LIST(), { status = "added" }, LIST() })
check(line(2):find("--hide --config=/cfg/open-with.toml --app=org.kde.okular.desktop --mime=application/pdf", 1, true) ~= nil, "remove: System-App nur hier ausblenden")
run("remove", { 3, 2 }, nil, { LIST(), { status = "still-default" }, LIST() })
check(line(2):find("--xdg-remove --app=org.kde.okular.desktop --mime=application/pdf", 1, true) ~= nil and notes[1]:find("bleibt Standard", 1, true) ~= nil, "remove: xdg + Hinweis still-default")
run("remove", { 5, 2 }, nil, { LIST() })
check(#calls == 1, "remove: unsichere ID wird nicht angefasst")
run("remove", {}, nil, { LIST() })
check(#calls == 1, "remove: Esc bricht ab")
print(ok and "GESAMT OK" or "GESAMT FEHLER")
