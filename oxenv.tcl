#!/usr/bin/tclsh

set enable(digisys) 1
set enable(compilers) 1

if {! [info exists status]} {
    set status(Oxenv-base) 0
    set status(Oxenv) 0
}

# machine (up|down) -- start or stop the Oxenv VM
proc machine {mc goal} {
    global status

    switch $goal {
        down {
            if {$status($mc)} {
                puts "Machine $mc down"
                vbox-manage controlvm $mc acpipowerbutton
                after 25000
            }
            set status($mc) 0
        }

        up {
            if {! $status($mc)} {
                puts "Machine $mc up"
                vbox-manage startvm $mc --type headless
                after 25000
            }
            set status($mc) 1
        }
    }
}

# shell -- shell command on host
proc shell {args} {
    eval [concat exec $args >@stdout 2>@stderr]
}

# ssh-cmd -- shell command on guest via ssh
proc ssh-cmd {args} {
    set cmd [concat ssh oxenv $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

# sudo-base -- shell command as root on base
proc sudo-base {args} {
    set cmd [concat ssh oxenv-base sudo $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

# sudo-cmd -- shell command as root on guest
proc sudo-cmd {args} {
    set cmd [concat ssh oxenv sudo $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

# apt-get -- run apt-get as root on guest
proc apt-get {args} {
    eval [concat sudo-cmd apt-get -y $args]
}

# vbox-manage -- VBoxManage command
proc vbox-manage {args} {
    set cmd [concat VBoxManage $args]
    puts ">>> $cmd"
    eval [concat exec $cmd >@stdout 2>@stderr]
}

# clone-vm -- clone the Oxenv-base VM as Oxenv
proc clone-vm {} {
    machine Oxenv-base down
    vbox-manage clonevm Oxenv-base --name Oxenv --basefolder [pwd] \
        --register
    vbox-manage modifyvm Oxenv --natpf1 "guestssh,tcp,,2224,,22"
}

# install-desktop -- install the RPi desktop
proc install-desktop {} {
    machine Oxenv down
    
    # Insert guest additions CD
    vbox-manage storageattach Oxenv \
        --storagectl IDE --port 1 --device 0 --type dvddrive \
        --medium /usr/share/virtualbox/VBoxGuestAdditions.iso

    machine Oxenv up

    # Populate the cache
    exec ssh oxenv sudo tar xvzf - -C /var/cache/apt/archives <packages.tgz

    # Install gnupg to enable importing of repository keys
    apt-get install gnupg

    # Add to apt sources
    set deb "deb http://archive.raspberrypi.org/debian/ bullseye main\n"
    exec ssh oxenv sudo tee /etc/apt/sources.list.d/raspi.list \
        <<$deb >/dev/null 2>@stderr
    set key [exec wget \
                 https://archive.raspberrypi.org/debian/raspberrypi.gpg.key \
                 -O - 2>@stderr]
    exec ssh oxenv sudo apt-key add - <<$key >@stdout 2>@stderr
    apt-get update
    apt-get dist-upgrade

    # Install the desktop
    apt-get install raspberrypi-ui-mods raspberrypi-net-mods rsync

    # Install guest additions
    apt-get install linux-headers-686 build-essential
    sudo-cmd mount /media/cdrom0
    catch {sudo-cmd sh /media/cdrom0/VBoxLinuxAdditions.run}

    # Remove unneeded fluff
    apt-get remove rp-bookshelf xscreensaver pavucontrol
    apt-get autoremove
    sudo-cmd rm -f /etc/xdg/autostart/light-locker.desktop
}

# install-tools -- install software for courses
proc install-tools {} {
    global enable

    machine Oxenv up

    # Common tools
    apt-get install mercurial geany geany-plugin-projectorganizer \
        geany-plugin-vc

    if {$enable(compilers)} {
        # Software for Compilers
        apt-get install \
            gcc ocaml-nox qemu-user gcc-arm-linux-gnueabihf tcl
    }

    # Software for Digital Systems (omitting pulseview)
    if {$enable(digisys)} {
        apt-get install \
            gcc-arm-none-eabi gdb-multiarch \
            minicom python3-pip
        sudo-cmd pip3 install pyocd

        # Save about 1GB of libraries for architectures we don't use
        sudo-cmd rm -r /usr/lib/arm-none-eabi/lib/thumb/v\[78\]* \
            /usr/lib/arm-none-eabi/newlib/thumb/nofp \
            /usr/lib/arm-none-eabi/lib/arm
    }
}

# install-file -- install a configuration file
proc install-file {source target} {
    exec ssh oxenv sudo tee $target <$source >/dev/null 2>@stderr
}

# install-settings -- install various settings
proc install-settings {} {
    global enable

    machine Oxenv up

    puts ">>> autologin"
    install-file lightdm.conf /etc/lightdm/lightdm.conf

    puts ">>> personal settings"
    shell rsync -av tree/ oxenv:

    # Reboot to log in guest for first time
    machine Oxenv down; machine Oxenv up

    puts ">>> dialout for guest"
    sudo-cmd addgroup guest dialout

    puts ">>> remove XDG folders"
    ssh-cmd rm -rf Documents Music Pictures Public Templates Videos

    if ($enable(digisys)) {
        puts ">>> udev rules"
        install-file 50-mbed.rules /etc/udev/rules.d/50-mbed.rules
    }
}

set disk0 "[pwd]/Oxenv/Oxenv.vdi"
set disk1 "[pwd]/Oxenv/Oxenv1.vdi"

# clone-disk -- clone the VM disk to compact free space
proc clone-disk {} {
    global disk0 disk1

    machine Oxenv down

    # Create a disk
    vbox-manage createmedium disk --filename $disk1 \
        --size 8192 --format VDI
    
    # Attach it
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 1 --type hdd --medium $disk1

    machine Oxenv up; after 10000

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
    machine Oxenv down

    # Swap the drives
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 1 --type hdd --medium none
    vbox-manage storageattach Oxenv \
        --storagectl SATA --port 0 --type hdd --medium $disk1

    # Boot again
    machine Oxenv up

    # Update grub one more time
    sudo-cmd update-grub
}

proc unclone-disk {} {
    global disk0 disk1

    machine Oxenv down

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

proc sanitise {} {
    machine Oxenv up

    # Remove SSH id
    ssh-cmd rm .ssh/authorized_keys
}

proc create-ova {} {
    machine Oxenv down

    # Remove the CD
    vbox-manage storageattach Oxenv \
        --storagectl IDE --port 1 --device 0 --type dvddrive \
        --medium emptydrive

    # Export an OVA file
    shell rm -f oxenv.ova
    vbox-manage export Oxenv -o oxenv.ova
}

proc update-cache {} {
    sudo-cmd apt-get autoclean
    exec ssh oxenv sh -c \
        {"cd /var/cache/apt/archives; tar cvfz - *.deb"} >new.tgz 2>@stderr
}

proc update-base {} {
    machine Oxenv-base up
    sudo-base apt-get update
    sudo-base apt-get upgrade -y
}
 
proc tidy-up {} {
    global disk0 disk1

    machine Oxenv-base down
    machine Oxenv down
    vbox-manage unregistervm Oxenv --delete
    if {[file exists $disk0]} {vbox-manage closemedium $disk0 --delete}
    if {[file exists $disk1]} {vbox-manage closemedium $disk1 --delete}
    if {[file exists Oxenv]} {file delete Oxenv}
}

proc the-works {} {
    update-base
    clone-vm
    install-desktop
    install-tools
    install-settings
    update-cache
    clone-disk
    sanitise
    create-ova
}

proc menu {} {
    puts "update-base"
    puts "clone-vm"
    puts "install-desktop"
    puts "install-tools"
    puts "install-settings"
    puts "update-cache"
    puts "clone-disk"
    puts "sanitise"
    puts "create-ova"
    puts ""
    puts "tidy-up"
}
    

if {$tcl_interactive} {
    menu
} else {
    the-works
}
