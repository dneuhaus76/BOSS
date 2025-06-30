# BOSS
Die automatisierte Installation ist mit Scripts selbst gemacht
- Ref: https://wiki.debian.org/Debootstrap

## Startmedium - USB erstellen
Das muss nur 1-Malig gemacht werden oder man kann mit einem anderen Boot-Medium starten, jedoch gerade wegen Firmware-Zusammenstellung auf Kubuntu-Live wäre es das beste genau dieses zu verwenden. Nach dieser Funktion "NewDiskSchema" hat man z.B. einen Grub-Bootloader auf dem USB-Stick - gut schauen dass das richtige Device genommen wird

```
echo; lsblk -l
echo "Enter Device name (/dev/x)"
read -r myDev
export myDev="${myDev:-/dev/sda}"

# Check if the device is an eMMC or a hard disk
if [[ $myDev == *mmcblk* ]]; then
    drive_type="eMMC"
    myDev="${myDev}p"
else
    drive_type="HD"
fi

function NewDiskSchema() {
    # Unmount partitions
    umount -l "${myDev}1"
    umount -l "${myDev}2"
    umount -l ${myDev}* 2
	sleep 2s

    # Cleanup bootsector
    dd if=/dev/zero of="${myDev}" bs=512 count=1

    # Create new partition schema
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' <<EOT | fdisk "${myDev}"
g   # GPT bootsector
n   # New partition
    # Default partition number
    # Default start sector
+512M   # 512M for FAT32 EFI System
    # Default answer for change type
t   # Type
1   # Type 1 is EFI System
n   # New partition
2   # Partition 2
    # Default
    # Default size and default type should be ok for Linux
p   # Print table
w   # Write changes
q   # Quit
EOT

    # Format partitions
    sleep 2s
    mkfs.vfat "${myDev}1"
    sleep 2s
    mkfs.ext4 -F "${myDev}2"

    sleep 5s
    # Mount partitions for installation
    mount "${myDev}2" /mnt
    mkdir -p /mnt/boot/efi
    mount "${myDev}1" /mnt/boot/efi

    grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --boot-directory=/mnt/boot --removable --recheck --no-nvram ${myDev}
}
```

## Live System (zum Booten/Testen und Installation starten)
Mein Vorschlag ist:
* Download des Live Zielsystems: https://cdimage.ubuntu.com/kubuntu/releases/24.04.2/release/kubuntu-24.04.2-desktop-amd64.iso
* iso in einen Ordner mounten:
  * sudo mkdir /media/iso
  * sudo mount kubuntu-24.04.2-desktop-amd64.iso /media/iso -o loop
* Dateien vom Iso auf den neuen Stick übertragen (Achtung bei cp: mit cp sollte "-a" verwendet werden):
  * rsync -avzh --progress /media/iso/ /mnt
  * ... die Installations-Scripts können auch unter /mnt/ platziert werden - Nach start des Live-Systems sind diese zu finden unter /cdrom/

## Start Installation:
**Installation aus dev** - Das ist möglich - mit z.B. download des Scripts "kubuntu.sh" - manuelle aktion: export myBranch="${myBranch:-main}" - main durch dev ersetzen. Es wird eine systemweite environment variable angelegt, die dann auch von postinstall "gesehen" wird. Dafault ist immer main (das wird auch keine Variable setzen)
Netzwerkverbindung sicherstellen - am besten "richtig Öffentliches" Netz mit LAN
Boot vom USB-Stick (Achtung: Bootreihenfolge!)
Script mit ausreichend Berechtigung starten - gut auf Drives achten!
![image](https://github.com/user-attachments/assets/ba98efc8-b86c-40d6-8f8d-e955bcf62e8d)
Gerät wird nach der 1. Phase heruntergefahren **USB-Entfernen** und Gerät am LAN starten --> jetzt wird ohne grafische Oberfläche alles installiert und konfiguriert
* Info: Keyboard wird nun erst nach dem Reboot also vom Postinstall gesetzt ($ in passworten wird mit shift + 4 geschrieben!)
  --> Installationsprozess könnte mit tail -f /var/log/postinstall.log "live" betrachtet werden...
  
Wenn "Postinstall" durch ist wird nochmals heruntergefahren - Gerät wäre jetzt aber bereit
