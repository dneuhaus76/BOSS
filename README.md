# BOSS
Die automatisierte Installation ist mit Scripts selbst gemacht
- Ref: https://wiki.debian.org/Debootstrap
- **Warum 2 Stages: Installateion von snapd - Applikationen haben innerhalb chroot Probleme verursacht**, deshalb wurde die Installation so erstellet, dass das "Basis"-System im chroot installiert wird --> danach der Rest mit einem Postinstall-Script. Postinstall - Scripts sollte so gemacht werden, dass es mehrmals durchlaufen könnte um das System zu konfigurieren, jedoch bereits konfigurierte Settings nicht beschädigt. Das Script updated sich bei jedem Run selbst. (Es werden Checks zu unseren Settings durchgeführt - wenn diese failen wird beim nächsten Boot Postinstall erneut durchgeführt, so könnten durch uns Fehler einfach korrigiert oder die Installation erweitert werden).

## Startmedium - USB erstellen
Das muss nur 1-Malig gemacht werden oder man kann mit einem anderen Boot-Medium starten. Kubuntu-Live ist sinnvoll damit man kurz was nachschauen oder Kompatibiliät prüfen kann. 
* Nach dem Vorgang (siehe unten) hat man z.B. einen Grub-Bootloader auf dem USB-Stick - gut schauen dass das richtige Device genommen wird

Man kann das aber auch anders machen - z.B. die Iso mit einem anderen Bootloader starten, nur die Iso benutzen oder die Iso mit dd auf den USB übertragen... Ich zeige hier den Weg nur mit einfachem Bootsektor und den extrahierten Daten der iso!

In der Art könnte am Bootstick sein - Das DiskSchema ist nach unserer Installation aber auch gleich
- 512 MB für ESP/EFI - FAT-DateiSystem
- Rest für Daten

```
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   50G  0 disk 
├─sda1   8:1    0  512M  0 part /boot/efi
└─sda2   8:2    0 49.5G  0 part /
```

Ausgangslage ist ein Linux, welches selbst die "Grub-binaries drauf hat sonst müssen die noch heruntergeladen werden!
(Das ist kein fertiges Script - variablen und Befehle können kopiert werden, fdisk muss von Hand gemacht werden)
```
myDev=/dev/sda
# Cleanup bootsector - falls der Bootsektor nicht richtig gelöscht werden kann
dd if=/dev/zero of="${myDev}" bs=512 count=1

# Hier sind die Antworten die man in fdisk eingeben kann

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

# Format partitions
mkfs.vfat "${myDev}1"
mkfs.ext4 -F "${myDev}2"

# Mount partitions for installation
mount "${myDev}2" /mnt
mkdir -p /mnt/boot/efi
mount "${myDev}1" /mnt/boot/efi

#Das ist nur Grub - ohne etwas anderes
grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --boot-directory=/mnt/boot --removable --recheck --no-nvram ${myDev}
```

## Live System (zum Booten/Testen und Installation starten)
Mein Vorschlag ist (grub nach iso - "extraktion "nochmals" installieren - es gab sonst vereinzelt Probleme mit SecureBoot auf USB):
* Download des Live Zielsystems: https://cdimage.ubuntu.com/kubuntu/releases/24.04.2/release/kubuntu-24.04.2-desktop-amd64.iso
* iso in einen Ordner mounten:
  * sudo mkdir /media/iso
  * sudo mount kubuntu-24.04.2-desktop-amd64.iso /media/iso -o loop
* Dateien vom Iso auf den neuen Stick übertragen (Achtung bei cp: mit cp sollte "-a" verwendet werden):
  * rsync -avzh --progress /media/iso/ /mnt
  * grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --boot-directory=/mnt/boot --removable --recheck --no-nvram ${myDev}
  * ... die Installations-Scripts können auch unter /mnt/ platziert werden - Nach start des Live-Systems sind diese zu finden unter /cdrom/

## Start Installation:
**Installation aus dev** - Das ist möglich - mit z.B. download des Scripts "kubuntu.sh" - jeweils variable im script prüfen: export myBranch="${myBranch:-main}" - ggf. main durch dev ersetzen. Es wird eine systemweite environment Variable angelegt, die dann auch von postinstall "gesehen" wird. Dafault ist immer main (das wird auch keine Variable setzen)
Netzwerkverbindung sicherstellen - am besten "richtig Öffentliches" Netz mit LAN

### Vorgang
* Boot vom USB-Stick (Achtung: Bootreihenfolge!)
* Script mit ausreichend Berechtigung starten - gut auf Drives achten!
![image](https://github.com/user-attachments/assets/ba98efc8-b86c-40d6-8f8d-e955bcf62e8d)
* Gerät wird nach der 1. Phase heruntergefahren **USB-Entfernen** und Gerät am LAN starten --> jetzt wird ohne grafische Oberfläche alles installiert und konfiguriert
* * Gerät erneut starten (es wäre möglich mit "nmtui" ein wifi zu verbinden und die installation komplett mit wifi durchzuführen
*   --> Installationsprozess könnte (und sollte im Moment noch) mit tail -f /var/log/postinstall.log "live" betrachtet werden...
  
Wenn "Postinstall" durch ist wird das Gertä nicht **heruntergefahren** da das Script mehrmals durchlaufen könnte und ich im Moment nicht einen endlos Loop mit Reboots verursachen möchte
