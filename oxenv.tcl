#!/usr/bin/tclsh

if {! [info exists status]} {
    set status 0;                   # Whether VM is running
}

proc machine {goal} {
    global status

    switch $goal {
        down {
            if {$status} {
                vbox-manage controlvm Oxenv acpipowerbutton
                after 10000
            }
            set status 0
        }

        up {
            if {! $status} {
                vbox-manage startvm Oxenv
                after 25000
            }
            set status 1
        }
    }
}

proc ssh-cmd {args} {
    set cmd [concat ssh oxenv $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

proc sudo-cmd {args} {
    set cmd [concat ssh oxenv sudo $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

proc apt-get {args} {
    eval [concat sudo-cmd apt-get -y $args]
}

proc vbox-manage {args} {
    set cmd [concat VBoxManage $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

proc clone-vm {} {
    vbox-manage clonevm Oxenv-base --name Oxenv --basefolder [pwd] \
        --register
    vbox-manage modifyvm Oxenv --natpf1 "guestssh,tcp,,2224,,22"
}

proc install-desktop {} {
    machine down
    
    # Insert guest additions CD
    vbox-manage storageattach Oxenv \
        --storagectl IDE --port 1 --device 0 --type dvddrive \
        --medium /usr/share/virtualbox/VBoxGuestAdditions.iso

    machine up

    apt-get install gnupg

    set deb "deb http://archive.raspberrypi.org/debian/ bullseye main\n"
    exec ssh oxenv sudo tee /etc/apt/sources.list.d/raspi.list \
        <<$deb >/dev/null 2>@stderr
    set key [exec wget \
                 https://archive.raspberrypi.org/debian/raspberrypi.gpg.key \
                 -O - 2>@stderr]
    exec ssh oxenv sudo apt-key add - <<$key >@stdout 2>@stderr
    apt-get update
    apt-get upgrade

    # RPi desktop
    apt-get install raspberrypi-ui-mods raspberrypi-net-mods rsync

    # Guest additions
    apt-get install linux-headers-686 build-essential
    sudo-cmd mount /media/cdrom0
    catch {sudo-cmd sh /media/cdrom0/VBoxLinuxAdditions.run}

    # Unneeded fluff
    apt-get remove rp-bookshelf xscreensaver pavucontrol
    apt-get autoremove
    sudo-cmd rm -f /etc/xdg/autostart/light-locker.desktop
}

proc install-tools {} {
    machine up

    # Common tools
    apt-get install mercurial geany geany-plugin-projectorganizer

    # Software for Compilers
    apt-get install \
        ocaml-nox qemu-user gcc-arm-linux-gnueabihf

    # Software for Digital Systems
    apt-get install \
        gcc-arm-none-eabi gdb-multiarch \
        pulseview sigrok-firmware-fx2lafw minicom python3-pip
    sudo-cmd pip3 install pyocd
}

proc install-file {source target} {
    exec ssh oxenv sudo tee $target <$source >/dev/null 2>@stderr
}

proc install-settings {} {
    machine up

    puts ">>> autologin"
    install-file lightdm.conf /etc/lightdm/lightdm.conf

    puts ">>> personal settings"
    exec rsync -av tree/ oxenv: >@stdout 2>@stderr

    machine down; machine up;   # Reboot to log in guest for first time

    puts ">>> remove XDG folders"
    ssh-cmd rm -rf Documents Music Pictures Public Templates Videos
}

set disk0 "[pwd]/Oxenv/Oxenv.vdi"
set disk1 "[pwd]/Oxenv/Oxenv1.vdi"

proc clone-disk {} {
    global disk0 disk1

    machine down

    # Create a disk
    vbox-manage createmedium disk --filename $disk1 \
        --size 8192 --format VDI
    
    # Attach it
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 1 --type hdd --medium $disk1

    machine up

    # Just for safety
    apt-get install parted

    # Clear cache
    apt-get clean

    # Partition, format, mount
    sudo-cmd parted /dev/sdb -a cylinder -- \
        mklabel msdos \
        mkpart primary ext4 2048s -1s \
        set 1 boot on
    sudo-cmd mkfs.ext4 /dev/sdb1
    sudo-cmd mount /dev/sdb1 /mnt

    # Copy files
    sudo-cmd cp -ax / /mnt

    # Fix /etc/fstab
    install-file fstab /mnt/etc/fstab

    # Install grub
    grub-install

    # Stop the machine
    machine down

    # Swap the drives
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 1 --type hdd --medium none
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 0 --type hdd --medium $disk1

    # Boot again
    machine up

    # Update grub one more time
    sudo-cmd update-grub
}

proc unclone-disk {} {
    global disk0 disk1

    machine down

    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 0 --type hdd --medium $disk0

    vbox-manage closemedium disk $disk1 --delete
}

proc grub-install {} {
    sudo-cmd mount --bind /dev /mnt/dev
    sudo-cmd mount --bind /dev/pts /mnt/dev/pts
    sudo-cmd mount --bind /proc /mnt/proc
    sudo-cmd mount --bind /sys /mnt/sys
    sudo-cmd chroot /mnt grub-install /dev/sdb
    sudo-cmd chroot /mnt update-grub
}    

proc create-ova {} {
    machine up

    # Remove SSH id
    ssh-cmd rm .ssh/authorized_keys

    machine down

    # Remove the CD
    vbox-manage storageattach Oxenv \
        --storagectl IDE --port 1 --device 0 --type dvddrive \
        --medium emptydrive

    # Export an OVA file
    vbox-manage export Oxenv -o oxenv.ova
}

proc the-works {} {
    clone-vm
    install-desktop
    install-tools
    install-settings
    clone-disk
    create-ova
    # vbox-manage unregistervm Oxenv --delete
}

if {! $tcl_interactive} {
    the-works
}
