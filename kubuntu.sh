#!/bin/bash
: '
echo text
#https://wiki.debian.org/Debootstrap
#setxkbmap -layout ch
$(openssl passwd -6 pwtohash)
#if ! wget -q --spider www.google.ch ; then
#if ! curl -s --head www.google.ch | grep "200 OK" >/dev/null; then
# treiber von live cd kopieren - nur wenn nötig so machen
#if [ ! -d /mnt/lib/firmware ]; then
#  mkdir -vp /mnt/lib/firmware
#fi
#if [ -d /lib/firmware ]; then
#    rsync -a --ignore-existing /lib/firmware/ /mnt/lib/firmware/
#fi
'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $SCRIPT_DIR
echo "workdir: $(pwd)"

export myBranch="${myBranch:-dev}"
export myDebugMode="n"
export myUsername="benutzer"
export mySite="http://ch.archive.ubuntu.com/ubuntu/"
export LANG="de_CH.UTF-8"
#export LANGUAGE="en:de:fr:it"
export fname=postinstall.sh
export sname=postinstall.service
export productname="$(dmidecode -s system-product-name)"
export log=/var/log/install.log
export DEBIAN_FRONTEND=noninteractive

# check current mode
echo;[ -d /sys/firmware/efi ] && echo "EFI boot on HDD" || echo "Legacy boot on HDD"; echo

#network check
ping -c2 -4 www.google.ch >/dev/null
if [ $? -ne 0 ]; then
  echo; echo "...is network connected?"
 # Exit 1
  read
fi

#root check
if [ $EUID -ne 0 ]; then
 echo; echo "Script muss mit root rechten gestartet werden"
 read
 exit 1
fi

# disable ipv6 during this installation - otherwise performance may be slow
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null

echo; echo "Enter Computername (kubuntu)"
read -r myComputername

echo; lsblk -o NAME,SIZE,MOUNTPOINT | grep -v 'loop'; echo
echo; echo "Enter Device name (/dev/nvme0n1)"
myDev=""
read -r myDev

export myComputername="${myComputername:-kubuntu}"
export myDist="${myDist:-noble}"
export myDev="${myDev:-/dev/sda}"
export myPart="$myDev"
export cryptName="cryptroot"

# Check if the device is an eMMC or a hard disk
if [[ $myDev == *sd* ]]; then
    drive_type=""
else
    drive_type="disk"
    myPart="${myDev}p"
fi

function NewDiskSchema() {
    # Variablen sollten extern gesetzt sein:
    # myDev, myPart, cryptName

    # Versuche sauber zu schließen (nur falls offen)
    if [ -e /dev/mapper/"${cryptName}" ]; then
        umount /dev/mapper/"${cryptName}" >/dev/null 2>&1 || true
        cryptsetup luksClose "${cryptName}" >/dev/null 2>&1 || true
    fi

    # Unmount mögliche Partitionen
    umount "${myPart}"* >/dev/null 2>&1 || true
    umount -l "${myPart}"* >/dev/null 2>&1 || true
    umount -R /mnt >/dev/null 2>&1 || true
    umount -Rl /mnt >/dev/null 2>&1 || true

    sleep 1s

    # Cleanup bootsector (vorsichtig, beabsichtigt)
    dd if=/dev/zero of="${myDev}" bs=512 count=1 >/dev/null 2>&1 || true

    # Create new partition schema mit parted
    parted -s "${myDev}" \
      mklabel gpt \
      mkpart primary fat32 1MiB 513MiB \
      set 1 esp on \
      mkpart primary ext4 513MiB 100%
    if [ $? -ne 0 ]; then echo "...parted Fehler aufgetreten"; fi

    # Kernel Partitionstabelle neu einlesen
    partprobe "${myDev}" >/dev/null 2>&1 || true
    sleep 1s
    udevadm settle >/dev/null 2>&1 || true
    sleep 1s

    # Format EFI
    mkfs.vfat "${myPart}1" >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo "...mkfs.vfat Fehler"; fi

    mkfs.ext4 -F "${myPart}2" >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo "...mkfs.ext4 Fehler"; fi

    # Mount partitions for installation
    mount -v "${myPart}2" /mnt
    if ! $(mountpoint -q /mnt) ; then echo "/mnt nicht gemountet"; read; fi
    mkdir -p /mnt/boot/efi
    mount -v "${myPart}1" /mnt/boot/efi
    sleep 2s
    if ! mountpoint -q /mnt/boot/efi ; then echo "/mnt/boot/efi nicht gemountet"; read; fi

# Schreibe fstab (überschreiben, nicht anhängen) mit UUID
mkdir -p /mnt/etc
fs_efi_uuid=$(blkid -s UUID -o value ${myPart}1)
fs_root_uuid=$(blkid -s UUID -o value ${myPart}2)

cat <<EOT > /mnt/etc/fstab
UUID=${fs_efi_uuid} /boot/efi vfat umask=0077 0 1
UUID=${fs_root_uuid} / ext4 defaults 0 1
EOT

}

function NewOSInstall() {
  echo "start debootstrap"
    apt update
    apt install -y ubuntu-keyring debian-archive-keyring curl
    apt install -y debootstrap
        debootstrap --no-check-gpg --arch=amd64 ${myDist} /mnt ${mySite} >/dev/null
}

function MyDebianChroot() {
  echo "start in chroot"

# Mounte notwendige Dateisysteme
mount --types proc /proc /mnt/proc
mount --rbind /sys /mnt/sys
mount --rbind /dev /mnt/dev

# Chroote in das Debian-System
LANG=$LANG chroot /mnt /bin/bash <<CHROOT_SCRIPT

# hostname
echo "${myComputername}" >/etc/hostname

# hosts
cat  <<EOT >/etc/hosts
127.0.0.1 localhost
127.0.1.1 ${myComputername}

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOT

# sources
cat <<EOT >/etc/apt/sources.list
deb ${mySite} ${myDist} main restricted universe
deb http://security.ubuntu.com/ubuntu/ ${myDist}-security main restricted universe
deb ${mySite} ${myDist}-updates main restricted universe
EOT

# Aktualisiere apt und beziehe firmware aus sources
apt update
apt install -y linux-firmware ubuntu-drivers-common fwupd
ubuntu-drivers install

# must have
apt install -y nano sudo ssh curl locales console-setup
unlink /etc/localtime; ln -s /usr/share/zoneinfo/Europe/Zurich /etc/localtime

# ubuntu problem secureboot-structure - directory missing
mkdir -pv /boot/efi/EFI/ubuntu

if systemd-detect-virt -q || [[ "${productname,,}" == "virtual machine" ]]; then
  echo "Virtual Machine" >> ${log}
  apt install -y grub-efi-amd64-signed shim-signed grub-common linux-image-virtual linux-azure linux-tools-virtual
else
  echo "Physische Machine: ${productname}" >> ${log}
  apt install -y grub-efi-amd64-signed shim-signed grub-common linux-image-generic
fi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
apt install -y plymouth-theme-kubuntu-logo
update-initramfs -u
update-grub


# Network Manager configuration
apt install -y network-manager
systemctl enable NetworkManager.service

cat <<EOT >/etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
EOT
chmod 600 /etc/netplan/01-network-manager-all.yaml

# set keyboard to swiss german
cat <<EOT >/etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="ch"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOT

# Ende des Chroots
CHROOT_SCRIPT

# add a user +sudo and a pw
myUserpw='$6$Q4mEIbASFCAmwxCZ$Uy5.P.CnxwfXYBrcAvo.xjGf6EJi3py.FTCFHfWcnpQSVS5GYm6E4aTh6/Sh.y1OSZ/6HxzH.cnDyOSPWzh/60'
#echo "sudo benutzer wird erzeugt mit pw: ${myUserpw}"
useradd --root /mnt -m -s /bin/bash -c 'boss (sudo)' -G adm,sudo -p "${myUserpw}" "boss"

# Setze Umgebungsvariable nur wenn dev
if [ "$myBranch" == "dev" ]; then
    if ! grep -q "^myBranch=" "/mnt/etc/environment"; then
      echo 'myBranch="dev"' >>"/mnt/etc/environment"
    fi
fi

# Setze Staging-Umgebungsvarialbe
if ! grep -q "^myStagingPhase=" "/mnt/etc/environment"; then
    echo 'myStagingPhase="BaseSystem"' >>"/mnt/etc/environment"
fi

# Update vom netz oder lokales file soll ueberschreiben (sonst ist Netz die source)
gitUrl="https://raw.githubusercontent.com/dneuhaus76/BOSS/refs/heads/${myBranch}/postinstall.sh"
if curl --output /dev/null --silent --fail -r 0-0 "${gitUrl}"; then
  curl -o /mnt/usr/local/bin/${fname} --silent ${gitUrl}
fi

# lokales file - update überschreibt das vom Netz
if [ -f $fname ]; then
  cp -fv "${fname}" /mnt/usr/local/bin/
fi

# kopiere und handling für bossfiles inkl. skeleton
if [ "$(ls -A ./bossfiles/*)" ]; then
  mkdir -vp /mnt/bossfiles
  cp -fv ./bossfiles/* /mnt/bossfiles/
  mkdir -vp /mnt/etc/skel/Desktop
  cp -fv ./bossfiles/{ReadMe.txt,'portal pocboss.desktop'} /mnt/etc/skel/Desktop/
fi



#MyStage 2 Chroot
LANG=$LANG chroot /mnt /bin/bash <<CHROOT_SCRIPT

# Weitere Anpassungen oder Installationen können hier erfolgen

#starte Task
cat  <<EOT >/etc/systemd/system/${sname}
[Unit]
Description=Post-Install Skript BOSS
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/${fname}
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOT

systemctl enable ${sname}

#Checks
#echo "Einige Checks: für $(hostname) ${productname}"
#ls -R /boot/efi/EFI && lsblk -f && sudo efibootmgr -v
#dmesg | grep -i firmware

checkcount=0
chkfiles="
/etc/fstab
/etc/hostname
/etc/hosts
/etc/apt/sources.list
/etc/netplan/01-network-manager-all.yaml
/usr/local/bin/${fname}
/etc/systemd/system/${sname}
/etc/default/keyboard
"

for i in ${chkfiles}; do
 echo "prüfe $i:"
  if [ -f $i ]; then
    cat -n $i
  else
    echo "...datei nicht gefunden"
    checkcount=$(( ${checkcount}+1 ))
 fi
 echo
done
if [ ${checkcount} > 0 ]; then
  echo "In den Checks sind [${checkcount}] Fehler aufgetreten!"
fi
# Ende des Chroots
CHROOT_SCRIPT

if ! [ -f /mnt/usr/local/bin/${fname} ]; then
  echo "Datei nicht vorhanden: /mnt/usr/local/bin/${fname}"
  read
fi

        # Bereinige und unmounte
        umount -R /mnt >/dev/null 2>&1
  sleep 1s
}

# Main
NewDiskSchema
NewOSInstall
MyDebianChroot

# Cleanup
umount -Rl /mnt >/dev/null 2>&1

#Check
#read -p "poweroff? (y/n): " continue_response
#if [ $continue_response == "y" ]; then
echo "Basis-installation abgeschlossen ${productname}"
echo 
echo "Die nächste Phase benötigt beim Reboot Netzwerk - Netzwerk-Verbindung herstellen z.B mit nmtui"
echo 
echo "weiter mit Taste"
read
#echo "Wait 60 seconds to poweroff"
#sleep 60s
poweroff -p
#fi
