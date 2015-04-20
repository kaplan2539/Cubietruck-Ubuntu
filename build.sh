#!/bin/bash

# --- Configuration -------------------------------------------------------------
# Change to your needs
VERSION="ct-ubuntu-0.1"
COMPILE="false"
DEST=~/ct-ubuntu
DISPLAY=3 # "3:hdmi; 4:vga"

HOSTNAME="cubietruck"
NETWORK=lan # wlan, lan
HOSTAPD="false"
KERNELHZ=300HZ # 250HZ, 300HZ, 1000HZ
DEST_LANG="en_US"
DEST_LANGUAGE="en"
# --- End -----------------------------------------------------------------------

SRC=$(pwd)
set -e

# Must be run as root
if [ "$UID" -ne 0 ]
then
  echo "Please run this script as root"
  exit
fi

# Enable WLAN
if [ "$NETWORK" = "wlan" ]
then
  ssid="CUBIE"
  interface=wlan0
  hw_mode=g
  channel=1
  bridge=br0
  wmm_enabled=0
  wpa=2
  preamble=1
  wpa_psk=66eb31d2b48d19ba216f2e50c6831ee11be98e2fa3a8075e30b866f4a5ccda27
  wpa_passphrase=12345678
  wpa_key_mgmt=WPA-PSK
  wpa_pairwise=TKIP
  rsn_pairwise=CCMP
  auth_algs=1
  macaddr_acl=0
fi

echo "Building Cubietruck-Ubuntu in $DEST from $SRC"

echo "------ updating ------"
apt-get update
apt-get upgrade

echo "------ Installing necessary toolchain packages"
apt-get -qq -y install binfmt-support bison build-essential ccache debootstrap flex gawk gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf gettext linux-headers-generic linux-image-generic lvm2 qemu-user-static texinfo texlive u-boot-tools uuid-dev zlib1g-dev unzip libncurses5-dev pkg-config libusb-1.0-0-dev

echo "------ Fetching/Updating repo's from GitHub"
mkdir -p $DEST/output
cp output/uEnv.txt $DEST/output

echo "------ Bootloader"
if [ -d "$DEST/u-boot-sunxi" ]
then
	cd $DEST/u-boot-sunxi ; git pull; cd $SRC
else
	git clone https://github.com/cubieboard/u-boot-sunxi $DEST/u-boot-sunxi
fi
echo "------ Allwinner tools"
if [ -d "$DEST/sunxi-tools" ]
then
	cd $DEST/sunxi-tools; git pull; cd $SRC
else
	git clone https://github.com/linux-sunxi/sunxi-tools.git $DEST/sunxi-tools
fi
echo "------ Hardware configurations"
if [ -d "$DEST/cubie_configs" ]
then
	cd $DEST/cubie_configs; git pull; cd $SRC
else
	git clone https://github.com/cubieboard/cubie_configs $DEST/cubie_configs
fi
echo "------ Patwood's kernel 3.4.75+"
if [ -d "$DEST/linux-sunxi" ]
then
	cd $DEST/linux-sunxi; git pull -f; cd $SRC
else
	git clone https://github.com/patrickhwood/linux-sunxi $DEST/linux-sunxi
fi

echo "------ Applying Patch for 2GB memory"
patch -f $DEST/u-boot-sunxi/include/configs/sunxi-common.h < $SRC/patch/memory.patch || true

echo "------ Applying Patch for high load. Could cause troubles with USB OTG port"
sed -e 's/usb_detect_type     = 1/usb_detect_type     = 0/g' $DEST/cubie_configs/sysconfig/linux/cubietruck.fex > $DEST/cubie_configs/sysconfig/linux/ct.fex

echo "------ Prepare fex files for VGA & HDMI output"
sed -e 's/screen0_output_type.*/screen0_output_type     = 3/g' $DEST/cubie_configs/sysconfig/linux/ct.fex > $DEST/cubie_configs/sysconfig/linux/ct-hdmi.fex
sed -e 's/screen0_output_type.*/screen0_output_type     = 4/g' $DEST/cubie_configs/sysconfig/linux/ct.fex > $DEST/cubie_configs/sysconfig/linux/ct-vga.fex

echo "------ Applying Patch for Kernel "
test -f $SRC/patch/'$KERNELHZ'.patch && patch -f $DEST/linux-sunxi/arch/arm/Kconfig < $SRC/patch/'$KERNELHZ'.patch

echo "------ Copying Kernel config"
cp $SRC/config/kernel.config $DEST/linux-sunxi/

#--------------------------------------------------------------------------------
# Compiling section
#--------------------------------------------------------------------------------
echo "------ Compiling boot loader"
cd $DEST/u-boot-sunxi
make clean CROSS_COMPILE=arm-linux-gnueabihf- && make -j2 'cubietruck' CROSS_COMPILE=arm-linux-gnueabihf-

echo "------ Compiling sunxi tools"
cd $DEST/sunxi-tools
make clean CROSS_COMPILE=arm-linux-gnueabihf- && make fex2bin && make bin2fex
cp fex2bin bin2fex /usr/local/bin/
# hardware configuration
fex2bin $DEST/cubie_configs/sysconfig/linux/ct-vga.fex $DEST/output/script-vga.bin
fex2bin $DEST/cubie_configs/sysconfig/linux/ct-hdmi.fex $DEST/output/script-hdmi.bin

if [ "$COMPILE" = "true" ]
then
  echo "------ Compiling Kernel"
  cd $DEST/linux-sunxi
  make clean CROSS_COMPILE=arm-linux-gnueabihf-

  echo "------ Compiling Kernel Modules"
  # Adding wlan firmware to kernel source
  cd $DEST/linux-sunxi/firmware
  unzip -o $SRC/bin/ap6210.zip
  cd $DEST/linux-sunxi

  make -j2 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- sun7i_defconfig
  # get proven config
  cp $DEST/linux-sunxi/kernel.config $DEST/linux-sunxi/.config
  make -j2 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- uImage modules
  make -j2 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=output modules_install
  make -j2 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_HDR_PATH=output headers_install
fi

#--------------------------------------------------------------------------------
# Creating SD image
#--------------------------------------------------------------------------------
echo "------ Creating SD image"
cd $DEST/output
# create 2GB image and mount image to next free loop device
dd if=/dev/zero of=ct-ubuntu.raw bs=1M count=2000
LOOP0=$(losetup -f)
echo "LOOP0=${LOOP0}"
losetup $LOOP0 ct-ubuntu.raw 

echo "------ Partitionning and Mounting filesystem"
# make image bootable
dd if=$DEST/u-boot-sunxi/u-boot-sunxi-with-spl.bin of=$LOOP0 bs=1024 seek=8

# create one partition starting at 2048 which is default
(echo n; echo p; echo 1; echo; echo; echo w) | fdisk $LOOP0 >> /dev/null || true
# just to make sure
partprobe $LOOP0

LOOP1=$(losetup -f)
# 2048 (start) x 512 (block size) = where to mount partition
losetup -o 1048576 $LOOP1 $LOOP0 

# create filesystem
mkfs.ext4 $LOOP1

echo "------ Creating mount point and mount image"
mkdir -p $DEST/output/sdcard/
mount $LOOP1 $DEST/output/sdcard/

echo "------ Downloading Ubuntu core System"
cd $DEST/output/sdcard/
wget -q http://cdimage.ubuntu.com/ubuntu-core/releases/trusty/release/ubuntu-core-14.04-core-armhf.tar.gz
tar xzf ubuntu-core-14.04-core-armhf.tar.gz
sync
rm ubuntu-core-14.04-core-armhf.tar.gz

cat > $DEST/output/sdcard/etc/motd <<EOF
              _      _        _                       _    
  ___  _   _ | |__  (_)  ___ | |_  _ __  _   _   ___ | | __
 / __|| | | || '_ \ | | / _ \| __|| '__|| | | | / __|| |/ /
| (__ | |_| || |_) || ||  __/| |_ | |   | |_| || (__ |   < 
 \___| \__,_||_.__/ |_| \___| \__||_|    \__,_| \___||_|\_\

EOF

echo "------ Installing customize scripts"
echo "------ Script to Turn of LED blinking"
cp $SRC/scripts/disable_led.sh $DEST/output/sdcard/root
chmod +x $DEST/output/sdcard/root/disable_led.sh
echo "/root/disable_led.sh" > $DEST/output/sdcard/etc/rc.conf

echo "------ Script to Autoresize filesystem at first boot"
cp $SRC/scripts/resize2fs.sh $DEST/output/sdcard/root
chmod +x $DEST/output/sdcard/root/resize2fs.sh
# and startable on boot just execute it once not on every boot!!!
#echo resize2fs.sh >> $DEST/output/sdcard/etc/rc.conf

echo "------ Script to install to NAND chip"
cp $SRC/scripts/nand-install.sh $DEST/output/sdcard/root
chmod +x $DEST/output/sdcard/root/nand-install.sh
cp $SRC/bin/nand1-boot-cubietruck-arch.tgz $DEST/output/sdcard/root

echo "------ Script to install to SATA disk"
cp $SRC/scripts/sata-install.sh $DEST/output/sdcard/root
chmod +x $DEST/output/sdcard/root/sata-install.sh

echo "------ Configuring Hostname"
echo $HOSTNAME > $DEST/output/sdcard/etc/hostname
echo -e "127.0.0.1\tlocalhost" > $DEST/output/sdcard/etc/hosts
echo -e "127.0.0.1\t$HOSTNAME" > $DEST/output/sdcard/etc/hosts

echo "------ Script to install and configure locales"
echo LANG='$DEST_LANG'.UTF-8 > $DEST/output/sdcard/etc/default.conf

echo "------ Creating fstab"
echo 'tmpfs /tmp  tmpfs   defaults,nosuid,size=30%   0   0' >> $DEST/output/sdcard/etc/fstab
echo 'tmpfs /var/log  tmpfs   defaults,nosuid   0   0' >> $DEST/output/sdcard/etc/fstab

echo "------ Configure module list"
cat >> $DEST/output/sdcard/etc/modules <<EOT
hci_uart
gpio_sunxi
bcmdhd
ump
mali
sunxi_gmac
EOT

if [ "$NETWORK" = "lan" ]
then
  echo "------ Configure LAN interface"
  cat >> $DEST/output/sdcard/etc/network/interfaces <<EOT
  auto eth0
  allow-hotplug eth0
  iface eth0 inet dhcp
EOT
fi

if [ "$NETWORK" = "wlan" ]
then
  echo "------ Configure WLAN interface"
  echo "NOTE: use wifi-menu wlan0 to configure"
  cat >> $DEST/output/sdcard/etc/network/interfaces <<EOT
  auto wlan0
  allow-hotplug wlan0
  iface wlan0 inet dhcp
      wpa-ssid SSID 
      wpa-psk xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  # to generate proper encrypted key: wpa_passphrase yourSSID yourpassword
EOT
fi

if [ "$HOSTAPD" = "true" ]
then
  echo "------ Configure and install hostapd"
  echo "NOTE: /etc/modules must be: bcmdhd op_mode=2"

  cat <<EOT >> $DEST/output/sdcard/etc/network/interfaces.hostapd
auto lo br0
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet manual

allow-hotplug wlan0
iface wlan0 inet manual

iface br0 inet dhcp
bridge_ports eth0 wlan0
hwaddress ether # will be added at first boot

EOT

  # copy hostapd from testing binary replace.
  cd $DEST/output/sdcard/usr/sbin/
  tar xvfz $SRC/bin/hostapd21.tgz
  cp $SRC/config/hostapd.conf $DEST/output/sdcard/etc/

fi

echo "------ Enable serial console"
echo T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100 >> $DEST/output/sdcard/etc/inittab

echo "------ Remove the preconfigured boot from prebuild image and the sunxi one"
rm -rf $DEST/output/sdcard/boot/
mkdir $DEST/output/sdcard/boot/
cp $DEST/output/uEnv.txt $DEST/output/sdcard/boot/
cp $DEST/linux-sunxi/arch/arm/boot/uImage $DEST/output/sdcard/boot/

if [ $DISPLAY = 4 ]; then
  echo "------ Enable VGA support"
  cp $DEST/output/script-vga.bin $DEST/output/sdcard/boot/script.bin
else
  echo "------ Enable HDMI support"
  cp $DEST/output/script-hdmi.bin $DEST/output/sdcard/boot/script.bin
fi

echo "------ Preparing modules and firmware"
cp -R $DEST/linux-sunxi/output/lib/modules $DEST/output/sdcard/lib/
cp -R $DEST/linux-sunxi/output/lib/firmware/ $DEST/output/sdcard/lib/

echo "------ Preparing sunxi-tools"
cd $DEST/sunxi-tools
make clean && make -j2 'fex2bin' CC=arm-linux-gnueabihf-gcc && make -j2 'bin2fex' CC=arm-linux-gnueabihf-gcc && make -j2 'nand-part' CC=arm-linux-gnueabihf-gcc
cp fex2bin $DEST/output/sdcard/usr/bin/ 
cp bin2fex $DEST/output/sdcard/usr/bin/
cp nand-part $DEST/output/sdcard/usr/bin/

echo "------ Unmount image"
umount $DEST/output/sdcard/ 
losetup -d $LOOP1
losetup -d $LOOP0

echo "------ Image is ready!"
#gzip $DEST/output/*.raw
echo "use: dd bs=1M if=ct-ubuntu.raw of=dev/sdx;sync"
ls $DEST/output/*.raw
md5sum *.raw
