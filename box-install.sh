#!/bin/sh
# Event-Suite-Box installieren oder aktualisieren (läuft auf dem Raspberry Pi als root).
#
# Ein Befehl (Pi am Internet, Raspberry Pi OS Lite 64 Bit):
#   curl -fsSL https://raw.githubusercontent.com/jannisniederhoff-debug/timecode-releases/main/box-install.sh | sudo sh
# Ohne Internet (Programmdatei + dieses Skript per USB-Stick):
#   sudo sh install.sh /media/<stick>/EventSuite-Box-<version>-linux-arm64
# Optionen (hinter dem Befehl, bei "curl … | sudo sh -s -- --rack"):
#   --mini        HiFiBerry DAC2 Pro XLR (Overlay eintragen) – Standard
#   --rack        Behringer UMC1820 per USB (kein HiFiBerry-Overlay)
#   --no-config   /boot/firmware/config.txt nicht anfassen
#   --no-reboot   nach Änderungen an config.txt nicht selbst neu starten
#
# Was das Skript tut (nur was nötig ist, vorher Sicherung):
#   1. Programm nach /opt/eventsuite-box/eventsuite-box (Download aus dem öffentlichen
#      Release-Repo mit SHA-256-Prüfung, oder die Datei vom Stick).
#   2. systemd-Dienst eventsuite-box (startet beim Booten, Neustart nach Absturz nach 2 s;
#      Echtzeit-Priorität setzt das Programm selbst für die Audio-Threads).
#   3. config.txt: HiFiBerry-Overlay dtoverlay=hifiberry-dacplus-pro (HiFiBerry: DAC2 Pro /
#      DAC2 Pro XLR ab Kernel 6.1.77, https://www.hifiberry.com/docs/data-sheets/datasheet-dac2-pro-xlr/),
#      force_eeprom_read=0 (HiFiBerry: „Configuring Linux 4.x or higher“), Onboard-Ton aus
#      (dtparam=audio=on auskommentiert, vc4-kms-v3d mit ,noaudio). Sicherung:
#      config.txt.vor-eventsuite-box. Danach Neustart.
#   4. Netzwerk (NetworkManager): kabelgebundene Verbindung bekommt zusätzlich eine
#      169.254-Adresse (für „Laptop direkt an der Box“ ohne Router).
# Erneut ausführen = aktualisieren/reparieren; Einstellungen in /var/lib/eventsuite-box bleiben.
set -eu

BASE=${EVENTSUITE_BOX_BASE:-https://raw.githubusercontent.com/jannisniederhoff-debug/timecode-releases/main}
# tests only: everything below a folder, no systemctl/nmcli/reboot
R=${EVENTSUITE_BOX_TESTROOT:-}
SYSTEMCTL=systemctl
[ -z "$R" ] || SYSTEMCTL=true
DIR=$R/opt/eventsuite-box
BIN=$DIR/eventsuite-box
DATA=$R/var/lib/eventsuite-box
UNIT=$R/etc/systemd/system/eventsuite-box.service

say() { printf '%s\n' "$*"; }
fail() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

VARIANT=auto
CONFIG=yes
REBOOT=yes
SRC=""
for a in "$@"; do
	case "$a" in
	--mini) VARIANT=mini ;;
	--rack) VARIANT=rack ;;
	--no-config) CONFIG=no ;;
	--no-reboot) REBOOT=no ;;
	-*) fail "unbekannte Option $a" ;;
	*) SRC=$a ;;
	esac
done

[ -n "$R" ] || [ "$(id -u)" = 0 ] || fail "bitte mit sudo starten (sudo sh install.sh …)"
case "$(uname -m)" in
aarch64 | arm64) KEY=linux-arm64 ;;
x86_64 | amd64) KEY=linux-amd64 ;;
*) fail "dieser Rechner ($(uname -m)) wird nicht unterstützt – Raspberry Pi OS 64 Bit nötig (nicht 32 Bit)" ;;
esac

say "== Event-Suite-Box installieren =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() { # url file
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		fail "weder curl noch wget gefunden"
	fi
}

# --- 1. Programm
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || fail "Datei $SRC nicht gefunden"
	cp "$SRC" "$TMP/eventsuite-box"
	say "Programm vom Stick: $SRC"
else
	say "Lade die aktuelle Version …"
	fetch "$BASE/box-latest.json" "$TMP/box-latest.json" || fail "Update-Info nicht ladbar – Internet da? ($BASE/box-latest.json)"
	# the manifest is indented JSON (scripts/release.sh): read url/sha256 of our key
	URL=$(awk -v k="\"$KEY\"" 'index($0,k){f=1} f && /"url"/ {gsub(/.*"url": *"|".*/,""); print; exit}' "$TMP/box-latest.json")
	SUM=$(awk -v k="\"$KEY\"" 'index($0,k){f=1} f && /"sha256"/ {gsub(/.*"sha256": *"|".*/,""); print; exit}' "$TMP/box-latest.json")
	VER=$(awk '/"version"/ {gsub(/.*"version": *"|".*/,""); print; exit}' "$TMP/box-latest.json")
	[ -n "$URL" ] && [ -n "$SUM" ] || fail "keine Programmdatei für $KEY in der Update-Info"
	fetch "$URL" "$TMP/eventsuite-box" || fail "Download fehlgeschlagen: $URL"
	GOT=$(sha256sum "$TMP/eventsuite-box" | awk '{print $1}')
	[ "$GOT" = "$SUM" ] || fail "Prüfsumme stimmt nicht – Download beschädigt, nichts verändert"
	say "Version $VER geladen, Prüfsumme ok."
fi
chmod 755 "$TMP/eventsuite-box"
"$TMP/eventsuite-box" -version >/dev/null 2>&1 || fail "die Programmdatei läuft auf diesem Pi nicht (falsche Datei? 32-Bit-System?)"
mkdir -p "$DIR" "$DATA"
cp "$TMP/eventsuite-box" "$BIN.new"
mv -f "$BIN.new" "$BIN"
say "Programm: $BIN ($("$BIN" -version))"

# --- 2. Dienst
cat >"$TMP/unit" <<'EOF'
[Unit]
Description=Event-Suite-Box (Netzwerk-Audio)
Wants=network-online.target
After=network-online.target sound.target

[Service]
ExecStart=/opt/eventsuite-box/eventsuite-box -data /var/lib/eventsuite-box
Restart=always
RestartSec=2
# the audio threads raise themselves to real-time priority (SCHED_FIFO)
LimitRTPRIO=99
LimitMEMLOCK=infinity
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$(dirname "$UNIT")"
if ! cmp -s "$TMP/unit" "$UNIT" 2>/dev/null; then
	cp "$TMP/unit" "$UNIT"
	say "Dienst eingerichtet: $UNIT"
fi

# --- 3. config.txt
CHANGED=no
CFG=$R/boot/firmware/config.txt
[ -f "$CFG" ] || CFG=$R/boot/config.txt
if [ "$CONFIG" = yes ] && [ -f "$CFG" ]; then
	if [ "$VARIANT" = auto ]; then
		VARIANT=mini
		grep -qi umc1820 "$R/proc/asound/cards" 2>/dev/null && VARIANT=rack
	fi
	cp "$CFG" "$TMP/config.txt"
	C="$TMP/config.txt"
	# onboard sound off (HDMI): only lines that are exactly like this
	if grep -q '^dtparam=audio=on' "$C"; then
		sed -i 's/^dtparam=audio=on/#dtparam=audio=on  # Event-Suite-Box: Onboard-Ton aus/' "$C"
	fi
	if grep -q '^dtoverlay=vc4-kms-v3d$' "$C"; then
		sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,noaudio/' "$C"
	fi
	if [ "$VARIANT" = mini ] && ! grep -q '^dtoverlay=hifiberry' "$C"; then
		{
			echo ""
			echo "[all]"
			echo "# Event-Suite-Box: HiFiBerry DAC2 Pro XLR (Overlay laut HiFiBerry-Datenblatt, Kernel >= 6.1.77)"
			echo "dtoverlay=hifiberry-dacplus-pro"
			grep -q '^force_eeprom_read=0' "$C" || echo "force_eeprom_read=0"
		} >>"$C"
	fi
	if ! cmp -s "$C" "$CFG"; then
		[ -f "$CFG.vor-eventsuite-box" ] || cp "$CFG" "$CFG.vor-eventsuite-box"
		cp "$C" "$CFG"
		CHANGED=yes
		say "$CFG angepasst (Sicherung: $CFG.vor-eventsuite-box)"
	fi
fi

# --- 4. Netzwerk: zusätzlich 169.254-Adresse (Laptop direkt an der Box)
if [ -z "$R" ] && command -v nmcli >/dev/null 2>&1; then
	nmcli -t -f NAME,TYPE connection show 2>/dev/null | while IFS=: read -r NAME TYPE; do
		[ "$TYPE" = 802-3-ethernet ] || continue
		if nmcli connection modify "$NAME" ipv4.link-local enabled ipv4.dhcp-timeout infinity 2>/dev/null; then
			say "Netzwerk „$NAME“: DHCP + zusätzlich 169.254-Adresse"
		else
			say "Hinweis: „$NAME“ – 169.254-Adresse nicht einstellbar (NetworkManager zu alt?)"
		fi
	done
fi

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable eventsuite-box >/dev/null 2>&1
HOST=$(hostname)
if [ "$CHANGED" = yes ] && [ "$REBOOT" = yes ]; then
	say ""
	say "Fertig. Die Box startet in 10 Sekunden neu (wegen config.txt)."
	say "Danach: http://$HOST.local:8095/ im Browser öffnen."
	[ -n "$R" ] || { sleep 10; systemctl reboot; }
	exit 0
fi
$SYSTEMCTL restart eventsuite-box
[ -n "$R" ] || sleep 2
say ""
if $SYSTEMCTL is-active --quiet eventsuite-box; then
	say "Fertig – die Box läuft."
else
	say "Der Dienst läuft nicht – Fehler ansehen mit: journalctl -u eventsuite-box -n 50"
fi
[ "$CHANGED" = yes ] && say "Bitte neu starten (sudo reboot), damit config.txt wirkt."
say "Status-Seite: http://$HOST.local:8095/  (oder http://<Adresse>:8095/)"
for ip in $(hostname -I 2>/dev/null); do
	case "$ip" in *:*) ;; *) say "   http://$ip:8095/" ;; esac
done
