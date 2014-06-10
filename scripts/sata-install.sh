#!/bin/bash
#
# Configuration

DEST=/dev/sda1
FORMAT=yes

clear_console
echo "WARNING"
#
# Do not modify anything below
#

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script."
    exit 1
fi

cat > .install-exclude <<EOF
/dev/*
/proc/*
/sys/*
/media/*
/mnt/*
/run/*
/tmp/*
/boot/*
/root/*
EOF

clear_console
echo "WARNING"
echo "

This script erase your hard drive and copy the contents of NAND to it!

"

echo -n "Proceed (y/n)? (default: n): "
read nandinst

if [ "$nandinst" != "y" ]
then
  exit 0
fi

if [ "$FORMAT" == "yes" ]
then
  mkfs.ext4 $DEST
fi

mount $DEST /mnt

echo "Creating hard drive rootfs ... up to 5 min."
rsync -aH --exclude-from=.install-exclude  /  /mnt
umount /mnt

echo "Changing nand_root= on nand1 partition."
mount /dev/nand1 /mnt
sed -e 's,nand_root=\/dev\/nand2,nand_root='"$DEST"',g' -i /mnt/uEnv.txt
umount /mnt

echo "WARNING"
echo "All done. Press a key to reboot! System needs NAND for boot process! It can't boot directly from hard drive."
rm .install-exclude
read konec
reboot
