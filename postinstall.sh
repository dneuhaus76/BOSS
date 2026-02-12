#!/bin/bash
: '
#https://blog.infected.systems/posts/2024-10-22-reinstalling-my-laptop-with-ubuntu-autoinstall/
#https://github.com/canonical/autoinstall-desktop/blob/main/autoinstall.yaml
#https://www.reddit.com/r/Ubuntu/comments/1ceun0e/xrdp_extremely_slow/
#only shutdown if nologin is removed
# if ! [ -f /etc/nologin ]; then poweroff; fi
#journalctl -u $sname -f

version 1.0 - 2026-02-03
version 1.1 - 2026-02-04
version 1.2 - 2026-02-06 (kaccounts-integration kaccounts-providers)
version 1.3 - 2026-02-10 (Element Desktop, krita als snap infolge Problemen)
'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $SCRIPT_DIR
echo "workdir: $(pwd)"

export myBranch="${myBranch:-main}"
export productname="$(dmidecode -s system-product-name)"
export LANG="de_CH.UTF-8"
export DEBIAN_FRONTEND=noninteractive
export checkcount=0
#export LANGUAGE="de:fr:it:en_US"
log=/var/log/postinstall.log
sname=postinstall.service
fname=postinstall.sh
#noLoginMsg="Das System ist während des Postinstalls gesperrt - es wird zum Abschluss heruntergefahren"
source /etc/environment
#diese variablen müssen nach /etc/environment stehen
gitUrl="https://raw.githubusercontent.com/dneuhaus76/BOSS/refs/heads/${myBranch}/postinstall.sh"

echo "[ $(date) ]: Postinstall [${productname}] gestartet - Umgebung: ${myBranch}" >> "${log}"

# no login while processing script
#echo "${noLoginMsg}" >/etc/nologin
#mkdir -p /etc/issue.d

#functions
function CheckNetwork(){
  # Maximale Anzahl der Versuche
  MAX_ATTEMPTS=10
  # Wartezeit zwischen den Versuchen in Sekunden
  WAIT_TIME=60

  # Schleife für die maximalen Versuche
  for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
    echo "Versuch $attempt von $MAX_ATTEMPTS: Prüfe Verbindung zu www.google.ch..." | tee -a "${log}"
    ping -c2 -4 www.google.ch >/dev/null 2>&1

    # Überprüfe den Exit-Code des Ping-Befehls
    if [ $? -eq 0 ]; then
      echo "Netzwerk ist verbunden."
      #echo "$(ip addr)" | tee -a "${log}"
      echo "$(nmcli)" | tee -a "${log}"
      return 0
    else
      echo "Netzwerk nicht verbunden. Warte ${WAIT_TIME} Sekunden vor dem nächsten Versuch..." | tee -a "${log}"
    fi
    sleep "${WAIT_TIME}"
  done
  echo "[error]...Fehler bei CheckNetwork" | tee -a "${log}"
  echo "Netzwerk nicht verbunden - Netzwerk-Verbindung herstellen oder für wifi mit nmtui und neustarten" | tee -a "${log}"
  systemctl stop ${sname} #wenn script gestoppt wird es sofort beendet
  return 1
}

function Install-CitrixFix(){
    #ToDo - AntwortDatei für d-i
    #Ref: https://docs.citrix.com/en-us/citrix-workspace-app-for-linux
    #Manueller-Test: /opt/Citrix/ICAClient/selfservice --icaroot /opt/Citrix/ICAClient
    echo "starte funktion Install-CitrixFix" | tee -a "${log}"
    #If installed skip all
    if dpkg -s libwebkit2gtk-4.0-dev >/dev/null; then
        echo "libwebkit2gtk-4.0-dev ist bereits installiert - skippe die installation" | tee -a "${log}"
        return 0
    fi

    debconf-set-selections <<< "icaclient devicetrust/install_devicetrust select no"
    debconf-set-selections <<< "icaclient app_protection/install_app_protection select no"
    apt install -yq net-tools
    apt-add-repository -y deb http://us.archive.ubuntu.com/ubuntu jammy main
    apt-add-repository -y deb http://us.archive.ubuntu.com/ubuntu jammy-updates main
    apt-add-repository -y deb http://us.archive.ubuntu.com/ubuntu jammy-security main
    apt update
    apt install -y libwebkit2gtk-4.0-dev
    dpkg -i '/bossfiles/icaclient_25.05.0.44_amd64.deb'
    if [ $? -ne 0 ]; then
        echo "[error]...Fehler bei dpkg Paketinstallation von icaclient" >> "${log}"
    fi
    apt-add-repository -ry deb http://us.archive.ubuntu.com/ubuntu jammy main
    apt-add-repository -ry deb http://us.archive.ubuntu.com/ubuntu jammy-updates main
    apt-add-repository -ry deb http://us.archive.ubuntu.com/ubuntu jammy-security main
    apt update

    #Check
    if ! dpkg -s libwebkit2gtk-4.0-dev >/dev/null; then
        echo "[error]...Fehler bei check von libwebkit2gtk-4.0-dev" >> "${log}"
        checkcount=$(( ${checkcount}+1 ))
        return 1
    fi
    return 0
}

function Stop-Services(){
  lstService="unattended-upgrades clamonaccess clamav-freshclam"
  for service in $lstService; do
    systemctl stop ${service}
  done
}

function XRDPConfig(){
	#xrdp + spezialkonfiguration für virtuelle maschinen
	PATTERN="tcp_send_buffer_bytes"
	NEW_LINE="tcp_send_buffer_bytes=4194304"
	CONFIG_FILE="/etc/xrdp/xrdp.ini"
	if ! [ -f "${CONFIG_FILE}.orig" ]; then
  	 cp "$CONFIG_FILE" "${CONFIG_FILE}.orig"
	fi
	if systemd-detect-virt -q || [[ "${productname,,}" == "virtual machine" ]]; then
  	 echo "Virtual Machine anpassung für xrdp"
  	 sed -i 's/^port=3389$/port=vsock:\/\/-1:3389/' "$CONFIG_FILE"
  	 sed -i 's/^security_layer=negotiate$/security_layer=rdp/' "$CONFIG_FILE"
	fi
	
	#rdp performance erhöhen
	if ! grep -q "^${NEW_LINE}" "$CONFIG_FILE"; then
 	 echo "Füge die neue Zeile '$NEW_LINE' unter dem Muster '$PATTERN' ein..."
 	 sed -i "/$PATTERN/a\\
$NEW_LINE" "$CONFIG_FILE"
	fi
	
	file=/etc/sysctl.d/xrdp.conf
	if ! [ -f ${file} ]; then 
 	 echo "net.core.wmem_max: $(sysctl -n net.core.wmem_max)"
 	 echo "net.core.wmem_max = 8388608">${file}
	fi
}

function Configure-ClamAV(){
#REF: https://gist.github.com/maligree/25a349e25ac31dd652c91e87e0b44e48
#ref to check: journalctl -fu clamonaccess
#test a virus signature - echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /home/$USER/eicar.txt ;cat /home/$USER/eicar.txt

CONFIG_FILE="/etc/clamav/clamd.conf"
#cfg
if ! [ -f "${CONFIG_FILE}.orig" ]; then
  cp "$CONFIG_FILE" "${CONFIG_FILE}.orig"
  sed -i 's/^OnAccessMaxFileSize .*/OnAccessMaxFileSize 20M/' "$CONFIG_FILE"
cat <<EOF >> ${CONFIG_FILE}
OnAccessExcludeUname clamav
OnAccessPrevention true
OnAccessIncludePath /home
OnAccessIncludePath /opt
OnAccessExcludePath /proc
OnAccessExcludePath /sys
OnAccessExcludePath /dev
EOF
fi

#service
cat <<EOF >/etc/systemd/system/clamonaccess.service
Description=ClamAV On-Access Scanning
After=clamav-daemon.service
Wants=clamav-daemon.service

[Service]
ExecStart=/usr/sbin/clamonacc --foreground --fdpass --remove
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

#Check
if ! [ -f /etc/systemd/system/clamonaccess.service ]; then
    echo "[error]...Fehler bei konfiguration von clamonaccess.service" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
fi

systemctl enable clamonaccess
}


function Install-Forticlientvpn(){
#install
  if [ -f /bossfiles/forticlient_vpn_7.4.3.1736_amd64.deb ]; then
    apt install -fy libappindicator3-1 libdbusmenu-glib4 libdbusmenu-gtk3-4 libnss3-tools
    dpkg -i /bossfiles/forticlient_vpn_7.4.3.1736_amd64.deb
  fi

  if [ -f /bossfiles/vpnhosts.txt ]; then
    INPUTFILE=/bossfiles/vpnhosts.txt
    DESTFILE=/etc/hosts
    while read ip name; do
      echo "suche name: $name"
      if ! grep -iq "${name}$" "$DESTFILE"; then
        echo "...füge Eintrag für ${name} hinzu"
        sed -i "/127.0.1.1/a\\$ip $name" "$DESTFILE"
      fi
    done < $INPUTFILE | sort -r
  fi

  if [ -f /bossfiles/forticlient_config.sh ]; then
    echo "user config fortinet vpn client"
    runuser -l mitarbeiter -c 'bash /bossfiles/forticlient_config.sh'
  fi
}

function Install-certificates(){
	if [ -f /bossfiles/admin_certs.tar ]; then
	  echo "extract and install admin - certificates"
	  mkdir -v /usr/local/share/ca-certificates/admin
	  tar -v -xf "/bossfiles/admin_certs.tar" -C "/usr/local/share/ca-certificates/admin"
	  update-ca-certificates
	fi
}


function Manage-apt-prio(){
echo "add mozilla-repo"
#add-apt-repository ppa:mozillateam/ppa -y
#apt-add-repository -y deb https://ppa.launchpadcontent.net/mozillateam/ppa noble main
if [ -f /bossfiles/mozillateam-ubuntu-ppa-noble.sources ]; then
 cp -v /bossfiles/mozillateam-ubuntu-ppa-noble.sources /etc/apt/sources.list.d/
fi
if [ ! -f /etc/apt/sources.list.d/mozillateam-ubuntu-ppa-noble.sources ]; then
    echo "[error].../etc/apt/sources.list.d/mozillateam-ubuntu-ppa-noble.sources" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
fi

echo "APT Pakete firefox höher priorisieren"
cat <<EOF > /etc/apt/preferences.d/mozilla-firefox
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001

Package: firefox*
Pin: origin snapcraft.io
Pin-Priority: -1
EOF

if [ ! -f /etc/apt/preferences.d/mozilla-firefox ]; then
    echo "[error].../etc/apt/preferences.d/mozilla-firefox" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
fi

echo "APT Pakete firefox höher priorisieren"
cat <<EOF > /etc/apt/preferences.d/mozilla-thunderbird
Package: thunderbird*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001

Package: thunderbird*
Pin: origin snapcraft.io
Pin-Priority: -1
EOF

if [ ! -f /etc/apt/preferences.d/mozilla-thunderbird ]; then
    echo "[error].../etc/apt/preferences.d/mozilla-thunderbird" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
fi
}


function Mozilla-AddPolicyFile(){
local POLFILELOC="$1"
echo "erstelle ${POLFILELOC}"
if [ ! -d "$(dirname "${POLFILELOC}")" ]; then
	mkdir -pv "$(dirname "${POLFILELOC}")"
fi
cat <<EOT >"${POLFILELOC}"
{
	"policies": {
		"Certificates": {
			"ImportEnterpriseRoots": true ,
			"Install": [
				"/usr/local/share/ca-certificates/admin/SwissGovernment-E-Intra01.crt",
				"/usr/local/share/ca-certificates/admin/SwissGovernment-E-Root01.crt"
			]
		}
	}
}
EOT

if [ ! -f "${POLFILELOC}" ]; then
    echo "[error]...${POLFILELOC}" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
fi
}


function Install-CustomizedElement(){
	MATRIX_DEFAULT_SERVER_NAME="pocboss.admin.ch"
	wget -qO /usr/share/keyrings/element-io-archive-keyring.gpg \
	https://packages.element.io/debian/element-io-archive-keyring.gpg

cat <<'EOF'>/etc/apt/sources.list.d/element-io.list
deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main
EOF

apt-get update -y
apt-get install -y element-desktop

install -d -m 0755 /etc/skel/.config/Element
cat <<EOF >/etc/skel/.config/Element/config.json
{
  "default_server_name": "${MATRIX_DEFAULT_SERVER_NAME}"
}
EOF

chmod 0644 /etc/skel/.config/Element/config.json
}

# main
#echo "postinstall gestartet \d \t - ${productname}" >'/etc/issue.d/01-boss-install'
#Test internet connection
echo "Starte Netzwerkcheck..."
CheckNetwork || echo "[error]...Netzwerkcheck"
#CheckNetwork || sysctl stop ${sname} #exit 1

#wegen möglicher Probleme Dienste zum stoppen
Stop-Services

#echo "postinstall wird verarbeitet - das kann etwas dauern" >>'/etc/issue.d/01-boss-install'
#systemctl restart getty@tty1
#locale aktivieren
if ! [ -f /etc/locale.gen.bkp ]; then
  cp -v /etc/locale.gen /etc/locale.gen.bkp
fi
LOCALES="de_CH.UTF-8 fr_CH.UTF-8 it_CH.UTF-8 en_US.UTF-8"
for LOC in $LOCALES; do
  if grep -q "^# ${LOC}" /etc/locale.gen; then
    sed -i "/^# ${LOC}/s/^# //g" /etc/locale.gen
  fi
done
locale-gen
update-locale LANG=de_CH.UTF-8

#zertifikate früh installieren
Install-certificates

#snapd - apt - priorisierung
Manage-apt-prio

#add mozilla policy
Mozilla-AddPolicyFile "/usr/lib/firefox/distribution/policies.json"
Mozilla-AddPolicyFile "/usr/lib/thunderbird/distribution/policies.json"

#Softwareliste - geht auch fast mit allen snaps - falls probleme wie projectlibre siehe weiter unten
varlist="
kde-plasma-desktop sddm sddm-theme-breeze kwin-x11 plasma-nm konsole systemsettings network-manager dolphin ark snapd
language-selector-common fonts-dejavu fonts-freefont-ttf language-pack-en language-pack-de language-pack-fr language-pack-it language-pack-kde-en language-pack-kde-de language-pack-kde-fr language-pack-kde-it
polkitd-pkla xrdp
okular
firefox firefox-locale-en firefox-locale-de firefox-locale-fr firefox-locale-it
thunderbird thunderbird-locale-en thunderbird-locale-de thunderbird-locale-fr thunderbird-locale-it
libreoffice
flameshot
shotcut
vlc
gimp
scribus
inkscape
manuskript
rawtherapee
keepassxc
kaccounts-integration kaccounts-providers
unattended-upgrades clamav clamav-daemon clamav-freshclam clamtk
"

myInstall="apt install -yq"
apt update
apt upgrade -y
apt autoremove -y
dpkg --configure -a --force-confnew
apt install -fy
$myInstall
for i in $varlist; do
 echo "verarbeite $i:" >> "${log}"
 $myInstall "$i"
 if [ $? -ne 0 ]; then
    echo "[error]...Fehler bei Paketinstallation von $i" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
 fi
done

#Infolge Problemen Element
Install-CustomizedElement

#wegen möglicher Probleme Dienste zum stoppen
Stop-Services


#snap that have explicit to be installed by snap command
snaplist="projectlibre krita"
for i in $snaplist; do
  echo "verarbeite $i:" >> "${log}"
  snap install "$i" >> "${log}"
  if [ $? -ne 0 ]; then
    echo "[error]...Fehler bei snap Paketinstallation" >> "${log}"
    checkcount=$(( ${checkcount}+1 ))
  fi
done

#add language packs
$myInstall $(check-language-support -l en) $(check-language-support -l de) $(check-language-support -l fr) $(check-language-support -l it) >> "${log}"
if [ $? -ne 0 ]; then
  echo "[error]...Fehler bei Paketinstallation von languagepacks" >> "${log}"
  checkcount=$(( ${checkcount}+1 ))
fi


#Install-CitrixFix & check
#Install-CitrixFix || echo "[error]...Install-CitrixFix"


#autoremove
apt upgrade -y
apt autoremove -y

#add user & usermod - boss existiert durch kubuntu
id "boss" >/dev/null 2>&1
if ! [ $? -eq 0 ]; then
  myUserpw='$6$Q4mEIbASFCAmwxCZ$Uy5.P.CnxwfXYBrcAvo.xjGf6EJi3py.FTCFHfWcnpQSVS5GYm6E4aTh6/Sh.y1OSZ/6HxzH.cnDyOSPWzh/60'
  useradd -m -s /bin/bash -c 'boss (sudo)' -G adm,audio,sudo,users,video -p "${myUserpw}" "boss" >> "${log}"
fi
usermod -aG adm,audio,video,netdev,plugdev,users "boss" >> "${log}"

id "mitarbeiter" >/dev/null 2>&1
if ! [ $? -eq 0 ]; then
  myUserpw='$6$cs1uZZfrRhHzgC4U$lE4/hsyd.blFC2qaNxvHDDOKdD0QgFe3FNacx62iq9Uw40XMLuRZgvGh3IENM3rznmKPL0yqqV5xtjyhIFWxR.'
  useradd -m -s /bin/bash -c 'mitarbeiter' -G users -p "${myUserpw}" "mitarbeiter" >> "${log}"
fi


#manage groups
adduser xrdp ssl-cert >> "${log}"


#Installation oder Konfiguration über funktionen
XRDPConfig
Configure-ClamAV
Install-Forticlientvpn
if [ -f /bossfiles/createScripts_Christian.sh ]; then
  echo "add user creation script"
  bash /bossfiles/createScripts_Christian.sh
fi
echo "check Christian-Script"


#ufw
ufw enable
ufw default allow outgoing


#ufw allow 22 >> "${log}"
#ufw allow 3389 >> "${log}"


#policy
mkdir -p /etc/polkit-1/localauthority/50-local.d
cat <<EOF >/etc/polkit-1/localauthority/50-local.d/47-allow-networkd.pkla
[Allow Network Control all Users]
Identity=unix-user:*
Action=org.freedesktop.NetworkManager.network-control
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF


# Log
ufw status >> "${log}"


#enable login & poweroff
/bin/rm -f /etc/nologin


#dienste konfigurieren
systemctl enable clamav-freshclam


# update postinstall.sh
#if curl --output /dev/null --silent --fail -r 0-0 "${gitUrl}"; then
#  curl -o /usr/local/bin/${fname} --silent "${gitUrl}"
#  echo "file from: ${gitUrl} download complete" >> "${log}"
#fi

## Auwertung ob fehler sonst - rerun nächstes Mail -- Vorsicht gefahr für endlose loops
#Service deaktivieren nach Ausführung - wenn Checkcount > 1 dann Update des postinstalls und aktivieren
if (( $checkcount > 0 )); then
  echo "[error]... in den Checks sind [${checkcount}] Fehler aufgetreten - update postinstall & rerun beim nächsten Start" >> "${log}"
  systemctl enable ${sname} >> "${log}"
  else
  systemctl disable ${sname} >> "${log}"
 if [ ${myStagingPhase} == "BaseSystem" ]; then
  sed -i '/^myStagingPhase=/d' /etc/environment
  poweroff -fp
 fi
fi
echo "In den Checks sind [${checkcount}] Fehler aufgetreten" >> "${log}"
echo "[ $(date) ]: Postinstall abgeschlossen" >> "${log}"
#rm '/etc/issue.d/01-boss-install'
#rm '/etc/issue'
#systemctl restart getty@tty1
