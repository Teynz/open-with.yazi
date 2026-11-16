# open-with.yazi – geprüfter Fork

Privater Fork von [lantwn/yazi-openway-plugin](https://github.com/lantwn/yazi-openway-plugin),
Stand Upstream-Commit `924da87ee952079bb82a6dcd9ed28f35fa19906d` (2026-10-29).
Geprüft gegen Yazi **26.9.1** (Quellcode-Tag `v26.9.1`, Commit `8dd895c6`).

Keine automatischen Updates: Upstream-Änderungen werden nur nach erneuter Prüfung übernommen.

## Ergebnis der Prüfung

| Punkt | Befund |
|---|---|
| Netzwerkzugriffe | keine |
| Ausführung fremder Befehle | nur `file -bL --mime-type` (Fallback) und der eigene Python-Helfer; Pfade per `ya.quote` bzw. als Argumentliste |
| Schreibzugriffe | Upstream: `Gio.AppInfo.set_as_last_used_for_type()` schreibt `~/.config/mimeapps.list` → im Fork abgeschaltet (s. u.) |
| Yazi-API | `rt.opener` (Index/NewIndex/Pairs), `rt.open.rules` (`match`/`update`), `ya.sync`-State, `ya.sleep`, `ya.emit("open", { interactive = true })` – alle in 26.9.1 vorhanden |
| MIME-Normalisierung | identisch mit Yazis `mime-local.lua` (entfernt `x-` und `vnd.`) |
| Lizenz | MIT, Hinweis in `LICENSE` bleibt erhalten |

## Änderungen ggü. Upstream

1. **Kein stilles Ändern der xdg-Standards** (`assets/open-with-gio`)
   `set_as_last_used_for_type()` läuft nur noch mit `OPEN_WITH_REMEMBER=1`.
   Upstream schrieb bei jedem Start einer App nach `[Added Associations]`; für
   Typen ohne expliziten `[Default Applications]`-Eintrag ändert das, was
   `xdg-open` systemweit startet.

2. **Natives `O`-Menü bleibt sauber** (`main.lua`)
   Upstream ließ die temporären `openwith_*`-Opener bis zum nächsten Aufruf in
   den Regeln stehen; sie tauchten dann im normalen `O`-Menü auf. Der Fork
   entfernt sie `OPEN_WITH_CLEANUP_DELAY` Sekunden (Standard 1.5) nach dem
   Öffnen des Menüs. Yazi kopiert die Opener beim Anzeigen des Menüs
   (`yazi-actor/src/mgr/open_do.rs`), die Auswahl funktioniert also weiter.
   Ein Generationszähler verhindert, dass ein älterer Aufruf die Einträge
   eines neueren entfernt.

3. **Desktop-IDs nur aus sicheren Zeichen** (`main.lua`)
   IDs mit Zeichen außerhalb `[A-Za-z0-9._-]` werden übersprungen. Die ID
   landet im `run`-String eines Openers, den Yazi zusätzlich nach
   `%`-Platzhaltern durchsucht.

4. **Beispiel-Keymap auf `<A-o>`** (`examples/keymap.toml`)
   Yazis Standardbelegung `O` bleibt unangetastet.

## Erweiterung: eigene Opener (Branch `tui-editor`)

Das `Alt+O`-Menü endet mit zwei Einträgen:

- **`[+] Add opener`**: komplett in Yazi. App wählen (für den Typ bekannte
  Apps als Tastenmenü, `/` sucht per Name), dann Geltung `m` MIME, `e` Endung
  oder `b` beides. Direkt belegbar: `plugin open-with add`.
- **`[~] Edit openers`**: öffnet `~/.config/yazi/open-with.toml` in
  `$VISUAL`/`$EDITOR`. Reihenfolge im Menü = Reihenfolge in der Datei.

Menü-Reihenfolge: Opener der Yazi-Regel, eigene Opener, System-Apps, Add/Edit.
`O` und `Enter` bleiben unverändert; `yazi.toml` und `mimeapps.list` werden
nicht angefasst.

```toml
[[opener]]
name   = "Okular"
app    = "org.kde.okular.desktop"   # oder: run = 'mpv --no-video %s'
mime   = "application/pdf"          # Muster wie "image/*" erlaubt
ext    = ["pdf"]                    # und/oder Endungen
block  = false                      # nur bei run
orphan = true                       # nur bei run
```

System-Apps ausblenden (nur im `Alt+O`-Menü, xdg bleibt unverändert):

```toml
[[hide]]
app  = "Firefox"      # Name wie im Menü oder Desktop-ID
mime = "image/*"      # optional, ebenso ext; ohne beides: überall
```

Fehlerhafte Einträge werden einzeln übersprungen und gemeldet.

### Aufbau (für spätere Erweiterungen)

| Teil | Aufgabe |
|---|---|
| `assets/open-with-gio` | gesamte Logik (GIO, Config lesen/schreiben), gibt JSON aus: `--list`, `--search`, `--add`, `--edit`, `--launch` |
| `UI.menu` / `UI.ask` / `UI.notify` in `main.lua` | einzige Stelle, die Yazi-Menüs zeichnet |
| `FLOWS` in `main.lua` | eine Funktion pro Aktion (`open`, `add`) |

Neue Einstellung: in `normalize_entry()` und `public()` (Python) ergänzen und
in `install()` (Lua) auswerten. Externes TUI: ruft dieselben Helfer-Befehle
auf, `main.lua` braucht dann nur einen Opener, der es startet.

Tests: `python3 tests/test_config.py` und `lua5.4 tests/mock_yazi.lua main.lua`
(Yazi-Mock, prüft Abläufe und Reihenfolge, ersetzt keinen Test in Yazi).

## Installation

Als Drop-in nach `~/.config/yazi/plugins/open-with.yazi/` (Verzeichnisname
ist Pflicht, der Helfer-Pfad wird daraus gebildet). `install.sh` aus Upstream
wird nicht verwendet.

Abhängigkeiten (Arch): `python` (>= 3.11), `python-gobject`, `glib2`, `file`.

## Bekannte Grenzen (Upstream)

- Ordner, Papierkorb und Remote-Pfade öffnen das normale Menü ohne System-Apps.
- Das Menü hat keine Suche; bei vielen Apps scrollen.
- Apps mit `Terminal=true` startet GIO in einem eigenen Terminal
  (`xdg-terminal-exec` bzw. GIOs Terminalliste), nicht in kitty-in-Yazi.
- Abhängig von Yazis experimenteller dynamischer Opener-API: nach
  Yazi-Updates prüfen. Fällt sie weg, öffnet `<A-o>` das normale Menü.
