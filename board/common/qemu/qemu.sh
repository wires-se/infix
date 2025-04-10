#!/bin/sh
# This script can be used to start an Infix OS image in Qemu.  It reads
# either a .config, generated from Config.in, or qemu.cfg from a release
# tarball, for the required configuration data.
#
# Debian/Ubuntu users can change the configuration post-release, install
# the kconfig-frontends package:
#
#    sudo apt install kconfig-frontends
#
# and then call this script with:
#
#    ./qemu.sh -c
#
# To bring up a menuconfig dialog.  Select `Exit` and save the changes.
# For more help, see:_
#
#    ./qemu.sh -h
#
# shellcheck disable=SC3037

# Local variables
imgdir=$(readlink -f "$(dirname "$0")")
prognm=$(basename "$0")

usage()
{
    echo "Usage:"
    echo " $prognm [opts] [ARGS]"
    echo
    echo "Options:"
    echo "  -c     Run menuconfig to change Qemu settings"
    echo "  -h     This help text"
    echo "  -k     Keep generated qemu.run script (name shown at end)"
    echo
    echo "Arguments:"
    echo "  ARGS1  Args before the '--' separator are for kernel space"
    echo "  --     Separator"
    echo "  ARGS2  Args after the '--' separator are for the init process"
    echo "         Also, qemu.cfg has QEMU_APPEND which can affect this."
    echo
    echo "Example:"
    echo "  qemu.sh -- finit.debug"
    echo "___________________________________________________________________"
    echo "Note: 'kconfig-frontends' package (Debian/Ubuntu) must be installed"
    echo "      for -c to work: sudo apt install kconfig-frontents"

    exit 1
}

die()
{
    echo "$@" >&2
    exit 1
}

load_qemucfg()
{
    tmp=$(mktemp -p /tmp)

    grep ^CONFIG_QEMU_ "$1" >"$tmp"
    # shellcheck disable=SC1090
    .  "$tmp"
    rm "$tmp"

    [ "$CONFIG_QEMU_MACHINE" ] || die "Missing QEMU_MACHINE"
    [ "$CONFIG_QEMU_ROOTFS"  ] || die "Missing QEMU_ROOTFS"

    [ -n "$CONFIG_QEMU_KERNEL" ] && [ -n "$CONFIG_QEMU_BIOS" ] \
	&& die "QEMU_KERNEL conflicts with QEMU_BIOS"

    [ -z "$CONFIG_QEMU_KERNEL" ] && [ -z "$CONFIG_QEMU_BIOS" ] \
	&& die "QEMU_KERNEL or QEMU_BIOS must be set"
}

loader_args()
{
    if [ "$CONFIG_QEMU_BIOS" ]; then
	echo -n "-bios $CONFIG_QEMU_BIOS "
    elif [ "$CONFIG_QEMU_KERNEL" ]; then
	echo -n "-kernel $CONFIG_QEMU_KERNEL "
    fi
}

append_args()
{
    if [ "$CONFIG_QEMU_CONSOLE_VIRTIO" ]; then
	echo -n "console=hvc0 "
    elif [ "$CONFIG_QEMU_x86_64" ]; then
	echo -n "console=ttyS0 "
    elif [ "$CONFIG_QEMU_aarch64" ]; then
	echo -n "console=ttyAMA0 "
    else
	die "Unknown console"
    fi

    if [ "$CONFIG_QEMU_ROOTFS_INITRD" = "y" ]; then
	# Size of initrd, rounded up to nearest kb
	size=$((($(stat -c %s "$CONFIG_QEMU_ROOTFS") + 1023) >> 10))
	echo -n "root=/dev/ram0 ramdisk_size=${size} "
    elif [ "$CONFIG_QEMU_ROOTFS_VSCSI" = "y" ]; then
	echo -n "root=PARTLABEL=primary "
    fi

    if [ "$V" != "1" ]; then
	echo -n "quiet "
    else
	echo -n "debug "
    fi

    echo -n "${QEMU_APPEND} ${QEMU_EXTRA_APPEND} "
}

rootfs_args()
{
    if [ "$CONFIG_QEMU_ROOTFS_INITRD" = "y" ]; then
	echo -n "-initrd $CONFIG_QEMU_ROOTFS "
    elif [ "$CONFIG_QEMU_ROOTFS_MMC" = "y" ]; then
	echo -n "-device sdhci-pci "
	echo -n "-device sd-card,drive=mmc "
	echo -n "-drive id=mmc,file=$CONFIG_QEMU_ROOTFS,if=none,format=raw "
    elif [ "$CONFIG_QEMU_ROOTFS_VSCSI" = "y" ]; then
	echo -n "-drive file=qemu.qcow2,if=virtio,format=qcow2,bus=0,unit=0 "
    fi
}

serial_args()
{
    echo -n "-display none "
    echo -n "-device virtio-serial "

    echo -n "-chardev stdio,id=console0,mux=on "
    echo -n "-mon chardev=console0 "

    if [ "$CONFIG_QEMU_CONSOLE_VIRTIO" ]; then
	echo -n "-device virtconsole,nr=0,name=console,chardev=console0 "
    elif [ "$CONFIG_QEMU_CONSOLE_SERIAL" ]; then
	echo -n "-serial chardev:console0 "
    else
	die "Unknown console"
    fi

    echo -n "-chardev socket,id=gdbserver,path=gdbserver.sock,server=on,wait=off "
    echo -n "-device virtconsole,nr=1,name=gdbserver,chardev=gdbserver "
}

usb_args()
{
    USBSTICK="usb.vfat"
    if ! [ -f $USBSTICK ]; then
	dd if=/dev/zero of=${USBSTICK} bs=8M count=1 >/dev/null 2>&1

	if command -v mkfs.vfat >/dev/null; then
	    mkfs.vfat -n "log" $USBSTICK >/dev/null 2>&1
	else
	    if command -v mkfs.exfat >/dev/null; then
		mkfs.exfat -L "log" $USBSTICK >/dev/null 2>&1
	    fi
	fi
    fi

    echo -n "-drive if=none,id=usbstick,format=raw,file=$USBSTICK "
    echo -n "-usb "
    echo -n "-device usb-ehci,id=ehci "
    echo -n "-device usb-storage,bus=ehci.0,drive=usbstick "
}

rw_args()
{
    [ "$CONFIG_QEMU_RW" ] ||  return

    if ! [ -f "aux.ext4" ]; then
	dd if=/dev/zero of="aux.ext4" bs=1M count=1 >/dev/null 2>&1
	mkfs.ext4 -L aux "aux.ext4" >/dev/null 2>&1
    fi
    echo -n "-drive file=aux.ext4,if=virtio,format=raw,bus=0,unit=3 "

    if ! [ -f "$CONFIG_QEMU_RW" ]; then
	dd if=/dev/zero of="$CONFIG_QEMU_RW" bs=16M count=1 >/dev/null 2>&1
	mkfs.ext4 -L cfg "$CONFIG_QEMU_RW" >/dev/null 2>&1
    fi

    echo -n "-drive file=$CONFIG_QEMU_RW,if=virtio,format=raw,bus=0,unit=1 "

    if [ "$CONFIG_QEMU_RW_VAR_OPT" ]; then
	if ! [ -f "$CONFIG_QEMU_RW_VAR" ]; then
	    dd if=/dev/zero of="$CONFIG_QEMU_RW_VAR" bs=$CONFIG_QEMU_RW_VAR_SIZE count=1 >/dev/null 2>&1
	    mkfs.ext4 -L var "$CONFIG_QEMU_RW_VAR" >/dev/null 2>&1
	fi

	echo -n "-drive file=$CONFIG_QEMU_RW_VAR,if=virtio,format=raw,bus=0,unit=2 "
    fi
}

host_args()
{
    [ "$CONFIG_QEMU_HOST" ] || return

    echo -n "-virtfs local,path=$CONFIG_QEMU_HOST,security_model=none,writeout=immediate,mount_tag=hostfs "
}

net_dev_args()
{
    name="e$1"
    mac=$(printf "02:00:00:00:00:%02x" "$1")

    echo -n "-device $CONFIG_QEMU_NET_MODEL,netdev=$name,mac=$mac "
    echo "$name	$mac" >>"$mactab"
}

rocker_port_args()
{
    sw=$1
    port=$2
    name="sw${sw}p${port}"
    mac=$(printf "02:00:00:00:%02x:%02x" "$sw" "$port")

    echo -n "-netdev tap,id=$name,ifname=$name,script=no,downscript=no "
    echo "$name	$mac" >> "$mactab"
}

net_args()
{
    # Infix will pick up this file via fwcfg and install it to /etc
    mactab=${imgdir}/mactab
    :> "$mactab"
    echo -n "-fw_cfg name=opt/mactab,file=$mactab "

    if [ "$CONFIG_QEMU_NET_BRIDGE" = "y" ]; then
	echo -n "-netdev bridge,id=e1,br=$CONFIG_QEMU_NET_BRIDGE_DEV "
	net_dev_args 1
    elif [ "$CONFIG_QEMU_NET_TAP" = "y" ]; then
	for i in $(seq 1 "$CONFIG_QEMU_NET_TAP_N"); do
	    echo -n "-netdev tap,id=e$i,ifname=qtap$i "
	    net_dev_args "$i"
	done
    elif [ "$CONFIG_QEMU_NET_ROCKER" = "y" ]; then
	sw=sw0			# Only single switch support atm.
	echo -n "-device '{\"driver\":\"rocker\", \"name\":\"${sw}\", "
	echo -n "\"fp_start_macaddr\":\"02:00:00:00:00:01\", "
	echo -n "\"ports\":["
	for i in $(seq 1 "$CONFIG_QEMU_NET_PORTS"); do
	    [ "$i" -gt 1 ] && echo -n ", "
	    echo -n "\"${sw}p${i}\""
	done
	echo -n "]}' "
	for i in $(seq 1 "$CONFIG_QEMU_NET_PORTS"); do
	    rocker_port_args 0 "$i"
	done
    elif [ "$CONFIG_QEMU_NET_USER" = "y" ]; then
	[ "$CONFIG_QEMU_NET_USER_OPTS" ] && useropts=",$CONFIG_QEMU_NET_USER_OPTS"
	echo -n "-netdev user,id=e1${useropts} "
	net_dev_args 1
    else
	echo -n "-nic none"
    fi
}

# Vital Product data
vpd_args()
{
    [ "$CONFIG_QEMU_VPD" = "y" ] || return

    vpd_file="${imgdir}/vpd"

    if ! [ -f "$vpd_file" ]; then
	onieprom="${imgdir}/onieprom"

	# This is you QEMU factory/default password:
	pwhash=$(echo -n "admin" | mkpasswd -s -m sha256crypt)

	cat <<EOF | "$onieprom" -e >"$vpd_file"
{
  "manufacture-date": "$(date +"%m/%d/%Y %H:%M:%S")",
  "vendor-extension": [
    [
      61046,
      "{\"pwhash\":\"$pwhash\"}"
    ]
  ]
}
EOF
    fi
    echo -n "-fw_cfg name=opt/vpd,file=$vpd_file"
}

wdt_args()
{
    echo -n "-device i6300esb "
}

random_date()
{
    rand=$(($(date +%_s) * $$ + $(date +%N | sed 's/^0*//')))
    when=$((rand % 7258118400)) # 1970 - 2200
    date -d "@$when" +"%Y-%m-%dT%H:%M:%S"
}

rtc_args()
{
    rtc="${CONFIG_QEMU_RTC:-utc}"
    clock="${CONFIG_QEMU_CLOCK:-host}"
    if [ "$rtc" = "random" ]; then
	rtc=$(random_date)
    fi

    echo -n "-rtc base=$rtc,clock=$clock"
}

gdb_args()
{
    echo -n "-chardev socket,id=gdbqemu,path=gdbqemu.sock,server=on,wait=off "
    echo -n "-gdb chardev:gdbqemu"
}

run_qemu()
{
    if [ "$CONFIG_QEMU_ROOTFS_VSCSI" = "y" ]; then
	if ! qemu-img check "qemu.qcow2"; then
	    rm -f "qemu.qcow2"
	fi
	if [ ! -f "qemu.qcow2" ]; then
	    echo "Creating qcow2 disk image for Qemu ..."
	    qemu-img create -f qcow2 -o backing_file="$CONFIG_QEMU_ROOTFS" \
		     -F qcow2 "qemu.qcow2" > /dev/null
	fi
    fi

    read -r qemu <<EOF
	$CONFIG_QEMU_MACHINE -nodefaults -m $CONFIG_QEMU_MACHINE_RAM \
	  $(loader_args) \
	  $(rootfs_args) \
	  $(serial_args) \
	  $(rw_args) \
	  $(usb_args) \
	  $(host_args) \
	  $(net_args) \
	  $(wdt_args) \
	  $(rtc_args) \
	  $(vpd_args) \
	  $(gdb_args) \
	  $CONFIG_QEMU_EXTRA
EOF
    # Save resulting command to a script, because I cannot for the life
    # of me figure out how to embed the JSON snippet for Rocker and run
    # it here without issues, spent way too much time on it -- Joachim
    run=$(mktemp -t run.qemu.XXX)
    echo "#!/bin/sh" > "$run"
    if [ "$CONFIG_QEMU_KERNEL" ]; then
	echo "$qemu -append \"$(append_args)\" $*" >> "$run"
    else
	echo "$qemu $*" >> "$run"
    fi
    chmod +x "$run"

    echo "Starting Qemu  ::  Ctrl-a x -- exit | Ctrl-a c -- toggle console/monitor"
    line=$(stty -g)
    stty raw
    $run
    stty "$line"
    if [ -n "$keep" ]; then
	echo "Keeping generated qemu.run script: $run"
    else
	rm "$run"
    fi
}

dtb_args()
{
    [ "$CONFIG_QEMU_LOADER_UBOOT" ] || return

    if [ "$CONFIG_QEMU_DTB_EXTEND" ]; then
	# On the current architecture, QEMU will generate an internal
	# DT based on the system configuration.

	# So we extract a copy of that
	run_qemu -M dumpdtb=qemu.dtb >/dev/null 2>&1

	# Extend it with the environment and signing information in
	# u-boot.dtb.
	echo "qemu.dtb u-boot.dtb" | \
	    xargs -n 1 dtc -I dtb -O dts | \
	    { echo "/dts-v1/;"; sed  -e 's:/dts-v[0-9]\+/;::'; } | \
	    dtc >qemu-extended.dtb 2>/dev/null

	# And use the combined result to start the instance
	echo -n "-dtb qemu-extended.dtb "
    else
	# Otherwise we just use the unmodified one
	echo -n "-dtb u-boot.dtb "
    fi
}

generate_dot()
{
    [ "$CONFIG_QEMU_NET_TAP" = "y" ] || return

    hostports="<qtap1> qtap1"
    targetports="<e1> e1"
    edges="host:qtap1 -- target:e1 [kind=mgmt];"
    for tap in $(seq 2 $((CONFIG_QEMU_NET_TAP_N - 1))); do
	hostports="$hostports | <qtap$tap> qtap$tap "
	targetports="$targetports | <e$tap> e$tap "
	edges="$edges host:qtap$tap -- target:e$tap;"
    done
    cat >qemu.dot <<EOF
graph "qemu" {
	layout="neato";
	overlap="false";
	esep="+20";

        node [shape=record, fontname="monospace"];
	edge [color="cornflowerblue", penwidth="2"];

	host [
	    label="host | { $hostports }"
	    pos="0,0!",

	    kind="controller",
	];

        target [
	    label="{ $targetports } | target",
	    pos="10,0!",

	    kind="infix",
	];

	$edges
}
EOF
}

menuconfig()
{
    grep -q QEMU_MACHINE Config.in || die "$prognm: must be run from the output/images directory"
    command -v kconfig-mconf >/dev/null || die "$prognm: cannot find kconfig-mconf for menuconfig"
    exec kconfig-mconf Config.in
}

scriptdir=$(dirname "$(readlink -f "$0")")
cd "$scriptdir" || (echo "Failed cd to $scriptdir"; exit 1)

while [ "$1" != "" ]; do
    case $1 in
	-c)
	    menuconfig
	    ;;
	-h)
	    usage
	    ;;
	-k)
	    keep=true
	    ;;
	*)
	    break
    esac
    shift
done

if [ -f .config ]; then
    # Customized settings from 'qemu.sh -c'
    load_qemucfg .config
else
    # Shipped defaults from release tarball
    load_qemucfg qemu.cfg
fi

if [ -z "$QEMU_EXTRA_APPEND" ]; then
    QEMU_EXTRA_APPEND="$*"
fi

generate_dot

run_qemu $(dtb_args)
