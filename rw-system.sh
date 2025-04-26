#!/system/bin/sh

if [ -z "$debug" ] && [ -f /cache/phh-log ];then
	mkdir -p /cache/phh
	debug=1 exec sh -x "$(readlink -f -- "$0")" > /cache/phh/logs 2>&1
else
    # Allow accessing logs from system app
    # Protected via SELinux for other apps
    chmod 0755 /cache/phh
    chmod 0644 /cache/phh/logs
fi

if [ -f /cache/phh-adb ];then
    setprop ctl.stop adbd
    setprop ctl.stop adbd_apex
    mount -t configfs none /config
    rm -Rf /config/usb_gadget
    mkdir -p /config/usb_gadget/g1

    echo 0x12d1 > /config/usb_gadget/g1/idVendor
    echo 0x103A > /config/usb_gadget/g1/idProduct
    mkdir -p /config/usb_gadget/g1/strings/0x409
    echo phh > /config/usb_gadget/g1/strings/0x409/serialnumber
    echo phh > /config/usb_gadget/g1/strings/0x409/manufacturer
    echo phh > /config/usb_gadget/g1/strings/0x409/product

    mkdir /config/usb_gadget/g1/functions/ffs.adb
    mkdir /config/usb_gadget/g1/functions/mtp.gs0
    mkdir /config/usb_gadget/g1/functions/ptp.gs1

    mkdir /config/usb_gadget/g1/configs/c.1/
    mkdir /config/usb_gadget/g1/configs/c.1/strings/0x409
    echo 'ADB MTP' > /config/usb_gadget/g1/configs/c.1/strings/0x409/configuration

    mkdir /dev/usb-ffs
    chmod 0770 /dev/usb-ffs
    chown shell:shell /dev/usb-ffs
    mkdir /dev/usb-ffs/adb/
    chmod 0770 /dev/usb-ffs/adb
    chown shell:shell /dev/usb-ffs/adb

    mount -t functionfs -o uid=2000,gid=2000 adb /dev/usb-ffs/adb

    /apex/com.android.adbd/bin/adbd &

    sleep 1
    echo none > /config/usb_gadget/g1/UDC
    ln -s /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/c.1/f1
    ls /sys/class/udc |head -n 1 > /config/usb_gadget/g1/UDC

    sleep 2
    echo 2 > /sys/devices/virtual/android_usb/android0/port_mode
fi

vndk="$(getprop persist.sys.vndk)"
[ -z "$vndk" ] && vndk="$(getprop ro.vndk.version |grep -oE '^[0-9]+')"

if [ "$vndk" = 26 ];then
	resetprop_phh ro.vndk.version 26
fi

setprop sys.usb.ffs.aio_compat true

if getprop ro.vendor.build.fingerprint | grep -q -i -e Blackview/BV9500Plus;then
    setprop persist.adb.nonblocking_ffs true
else
    setprop persist.adb.nonblocking_ffs false
fi

fixSPL() {
    if [ "$(getprop ro.product.cpu.abi)" = "armeabi-v7a" ]; then
        setprop ro.keymaster.mod 'AOSP on ARM32'
    else
        setprop ro.keymaster.mod 'AOSP on ARM64'
    fi
    img="$(find /dev/block -type l -iname kernel"$(getprop ro.boot.slot_suffix)" | grep by-name | head -n 1)"
    [ -z "$img" ] && img="$(find /dev/block -type l -iname boot"$(getprop ro.boot.slot_suffix)" | grep by-name | head -n 1)"
    if [ -n "$img" ]; then
    #Rewrite SPL/Android version if needed
    # Read Android version from vbmeta (often trustkernel's root of trust)
    Arelease="$(strings -n 2 /dev/block/by-name/vbmeta* | grep -A1 com.android.build.system.os_version | grep -E '^[0-9]+$' | sort -n | head -n1)"
    # Otherwise read it from boot.img
    [ -z "$Arelease" ] && Arelease="$(getSPL "$img" android)"
    spl="$(getSPL "$img" spl)"
    setprop ro.keymaster.xxx.release "${Arelease}"
    setprop ro.keymaster.xxx.security_patch "$spl"
    if [ -z "$Arelease" ] || [ -z "$spl" ];then
        return 0
    fi
    # Some devices will want true vbmeta_state and verifiedbootstate
    # Setup those properties redirect for "keymaster" prop redirects
    setprop ro.keymaster.xxx.vbmeta_state unlocked
    setprop ro.keymaster.xxx.verifiedbootstate orange

    if getprop ro.vendor.build.fingerprint |grep -q -i samsung/j6lte;then
        setprop debug.phh.props.ter@3.0-service keymaster
        setprop debug.phh.props.mcDriverDaemon keymaster
    fi

    # Found on Cubot Pocket 3: trustkernel work only on stock model name or AOSP GSI model name
    if [ -f /vendor/bin/hw/android.hardware.keymaster@4.1-service.trustkernel ] && [ -f /proc/tkcore/tkcore_log ];then
        setprop debug.phh.props.teed keymaster
        # Process name is android.hardware.keymaster@4.1-service.trustkernel
        setprop debug.phh.props.ice.trustkernel keymaster
    fi

        setprop ro.keymaster.brn Android

        if getprop ro.vendor.build.fingerprint |grep -qiE 'samsung.*star.*lte';then
            additional="/apex/com.android.vndk.v28/lib64/libsoftkeymasterdevice.so /apex/com.android.vndk.v29/lib64/libsoftkeymasterdevice.so"
        else
            getprop ro.vendor.build.fingerprint | grep -qiE '^samsung/' && return 0
        fi
        for f in \
            /vendor/lib64/hw/android.hardware.keymaster@3.0-impl-qti.so /vendor/lib/hw/android.hardware.keymaster@3.0-impl-qti.so \
            /system/lib64/vndk-26/libsoftkeymasterdevice.so /vendor/bin/teed \
            /apex/com.android.vndk.v26/lib/libsoftkeymasterdevice.so  \
            /apex/com.android.vndk.v26/lib64/libsoftkeymasterdevice.so  \
            /system/lib64/vndk/libsoftkeymasterdevice.so /system/lib/vndk/libsoftkeymasterdevice.so \
            /system/lib/vndk-26/libsoftkeymasterdevice.so \
            /system/lib/vndk-27/libsoftkeymasterdevice.so /system/lib64/vndk-27/libsoftkeymasterdevice.so \
	    /vendor/lib/libkeymaster3device.so /vendor/lib64/libkeymaster3device.so \
        /vendor/lib/libMcTeeKeymaster.so /vendor/lib64/libMcTeeKeymaster.so \
        /vendor/lib/hw/libMcTeeKeymaster.so /vendor/lib64/hw/libMcTeeKeymaster.so $additional; do
            [ ! -f "$f" ] && continue
            # shellcheck disable=SC2010
            ctxt="$(ls -lZ "$f" | grep -oE 'u:object_r:[^:]*:s0')"
            b="$(echo "$f" | tr / _)"

            cp -a "$f" "/mnt/phh/$b"
            sed -i \
                -e 's/ro.build.version.release/ro.keymaster.xxx.release/g' \
                -e 's/ro.build.version.security_patch/ro.keymaster.xxx.security_patch/g' \
                -e 's/ro.product.model/ro.keymaster.mod/g' \
                -e 's/ro.product.brand/ro.keymaster.brn/g' \
                "/mnt/phh/$b"
            chcon "$ctxt" "/mnt/phh/$b"
            mount -o bind "/mnt/phh/$b" "$f"
        done
        if [ "$(getprop init.svc.keymaster-3-0)" = "running" ]; then
            setprop ctl.restart keymaster-3-0
        fi
        if [ "$(getprop init.svc.teed)" = "running" ]; then
            setprop ctl.restart teed
        fi
    fi
}

changeKeylayout() {
    mpk="/mnt/phh/keylayout"
    cp -a /system/usr/keylayout /mnt/phh/keylayout
    changed=false
    if getprop ro.vendor.build.fingerprint |
        grep -qE -e "^samsung"; then
        changed=true

        cp /system/phh/samsung-gpio_keys.kl /mnt/phh/keylayout/gpio_keys.kl
        cp /system/phh/samsung-sec_touchscreen.kl /mnt/phh/keylayout/sec_touchscreen.kl
        cp /system/phh/samsung-sec_touchkey.kl /mnt/phh/keylayout/sec_touchkey.kl
        chmod 0644 /mnt/phh/keylayout/gpio_keys.kl /mnt/phh/keylayout/sec_touchscreen.kl
    fi
}

if [ "$(getprop ro.product.vendor.manufacturer)" = motorola ] && getprop ro.vendor.product.name |grep -qE '^lima';then
    for l in lib lib64;do
        for f in mt6771 lima;do
            mount /mnt/phh/empty /vendor/$l/hw/keystore.$f.so
        done
    done
    setprop persist.sys.overlay.devinputjack true
fi

if ! getprop ro.vendor.build.fingerprint |grep samsung/;then
    if mount -o remount,rw /system; then
        resize2fs "$(grep ' /system ' /proc/mounts | cut -d ' ' -f 1)" || true
    else
        mount -o remount,rw /
        major="$(stat -c '%D' /.|sed -E 's/^([0-9a-f]+)([0-9a-f]{2})$/\1/g')"
        minor="$(stat -c '%D' /.|sed -E 's/^([0-9a-f]+)([0-9a-f]{2})$/\2/g')"
        mknod /dev/tmp-phh b $((0x$major)) $((0x$minor))
        blockdev --setrw /dev/tmp-phh
        resize2fs /dev/root || true
        resize2fs /dev/tmp-phh || true
    fi
    mount -o remount,ro /system || true
    mount -o remount,ro / || true
fi

mkdir -p /mnt/phh/
mount -t tmpfs -o rw,nodev,relatime,mode=755,gid=0 none /mnt/phh || true
mkdir /mnt/phh/empty_dir
touch /mnt/phh/empty
fixSPL

changeKeylayout

mount /mnt/phh/empty /vendor/bin/vendor.samsung.security.proca@1.0-service || true

foundFingerprint=false
for manifest in /vendor/manifest.xml /vendor/etc/vintf /odm/etc/vintf;do
	if grep -q \
		-e android.hardware.biometrics.fingerprint \
		-r $manifest;then
			foundFingerprint=true
	fi
done

if [ "$foundFingerprint" = false ];then
    mount -o bind /mnt/phh/empty /system/etc/permissions/android.hardware.fingerprint.xml
fi

if ! grep android.hardware.bluetooth /vendor/manifest.xml && ! grep android.hardware.bluetooth /vendor/etc/vintf/manifest.xml; then
    mount -o bind /mnt/phh/empty /system/etc/permissions/android.hardware.bluetooth.xml
    mount -o bind /mnt/phh/empty /system/etc/permissions/android.hardware.bluetooth_le.xml
fi

if getprop ro.hardware | grep -qF qcom && [ -f /sys/class/backlight/panel0-backlight/max_brightness ] &&
    grep -qvE '^255$' /sys/class/backlight/panel0-backlight/max_brightness; then
    setprop persist.sys.qcom-brightness "$(cat /sys/class/backlight/panel0-backlight/max_brightness)"
fi

if getprop ro.vendor.build.fingerprint | grep -q full_k50v1_64 || getprop ro.hardware | grep -q mt6580; then
    setprop persist.sys.overlay.nightmode false
fi

if grep -qF 'mkdir /data/.fps 0770 system fingerp' vendor/etc/init/hw/init.mmi.rc; then
    mkdir -p /data/.fps
    chmod 0770 /data/.fps
    chown system:9015 /data/.fps

    chown system:9015 /sys/devices/soc/soc:fpc_fpc1020/irq
    chown system:9015 /sys/devices/soc/soc:fpc_fpc1020/irq_cnt
fi

if getprop ro.build.fingerprint | grep -iq \
    -e motorola/channel; then
    mount -o bind /mnt/phh/empty_dir /vendor/lib64/soundfx
    mount -o bind /mnt/phh/empty_dir /vendor/lib/soundfx
    setprop ro.audio.ignore_effects true
fi

mount -o bind /mnt/phh/empty /vendor/lib/libpdx_default_transport.so
mount -o bind /mnt/phh/empty /vendor/lib64/libpdx_default_transport.so

mount -o bind /mnt/phh/empty /vendor/overlay/SysuiDarkTheme/SysuiDarkTheme.apk || true
mount -o bind /mnt/phh/empty /vendor/overlay/SysuiDarkTheme/SysuiDarkThemeOverlay.apk || true

#If we have both Samsung and AOSP power hal, take Samsung's
if [ -f /vendor/bin/hw/vendor.samsung.hardware.miscpower@1.0-service ] && [ "$vndk" -lt 28 ]; then
    mount -o bind /mnt/phh/empty /vendor/bin/hw/android.hardware.power@1.0-service
fi

if [ "$vndk" = 27 ] || [ "$vndk" = 26 ]; then
    mount -o bind /system/phh/libnfc-nci-oreo.conf /system/etc/libnfc-nci.conf
fi

if busybox_phh unzip -p /vendor/app/ims/ims.apk classes.dex | grep -qF -e Landroid/telephony/ims/feature/MmTelFeature -e Landroid/telephony/ims/feature/MMTelFeature; then
    mount -o bind /mnt/phh/empty /vendor/app/ims/ims.apk
fi

if getprop ro.hardware | grep -qF exynos; then
    setprop debug.sf.latch_unsignaled 1
fi

if getprop ro.vendor.build.fingerprint | grep -qiE '^samsung'; then
    if getprop ro.hardware | grep -q qcom; then
        setprop persist.sys.overlay.devinputjack false
    fi
fi

if [ $(find /vendor/etc/audio -type f |wc -l) -le 3 ];then
	mount -o bind /mnt/phh/empty_dir /vendor/etc/audio || true
fi

if [ -n "$(getprop ro.boot.product.hardware.sku)" ] && [ -z "$(getprop ro.hw.oemName)" ];then
	setprop ro.hw.oemName "$(getprop ro.boot.product.hardware.sku)"
fi

if getprop ro.vendor.build.fingerprint | grep -qiE '^samsung/' && [ "$vndk" -ge 28 ];then
	setprop persist.sys.phh.samsung_fingerprint 0
	#obviously broken perms
	if [ "$(stat -c '%U' /sys/class/sec/tsp/cmd)" == "root" ] &&
		[ "$(stat -c '%G' /sys/class/sec/tsp/cmd)" == "root" ];then

		chcon u:object_r:sysfs_ss_writable:s0 /sys/class/sec/tsp/ear_detect_enable
		chown system /sys/class/sec/tsp/ear_detect_enable

		chcon u:object_r:sysfs_ss_writable:s0 /sys/class/sec/tsp/cmd{,_list,_result,_status}
		chown system /sys/class/sec/tsp/cmd{,_list,_result,_status}

		chown system /sys/class/power_supply/battery/wc_tx_en
		chcon u:object_r:sysfs_app_writable:s0 /sys/class/power_supply/battery/wc_tx_en
	fi

	if [ "$(stat -c '%U' /sys/class/sec/tsp/input/enabled)" == "root" ] &&
		[ "$(stat -c '%G' /sys/class/sec/tsp/input/enabled)" == "root" ];then
			chown system:system /sys/class/sec/tsp/input/enabled
			chcon u:object_r:sysfs_ss_writable:s0 /sys/class/sec/tsp/input/enabled
			setprop ctl.restart sec-miscpower-1-0
	fi
	if [ "$(stat -c '%U' /sys/class/camera/flash/rear_flash)" == "root" ] &&
		[ "$(stat -c '%G' /sys/class/camera/flash/rear_flash)" == "root" ];then
        chown system:system /sys/class/camera/flash/rear_flash
        chcon u:object_r:sysfs_camera_writable:s0 /sys/class/camera/flash/rear_flash
    fi
fi

setprop ctl.stop console
copyprop() {
    p="$(getprop "$2")"
    if [ "$p" ]; then
        resetprop_phh "$1" "$(getprop "$2")"
    fi
}
if [ -f /system/phh/secure ] || [ -f /metadata/phh/secure ];then
    copyprop ro.build.device ro.vendor.build.device
    copyprop ro.system.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.bootimage.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.build.fingerprint ro.vendor.build.fingerprint
    copyprop ro.build.device ro.vendor.product.device
    copyprop ro.product.system.device ro.vendor.product.device
    copyprop ro.product.device ro.vendor.product.device
    copyprop ro.product.system.device ro.product.vendor.device
    copyprop ro.product.device ro.product.vendor.device
    copyprop ro.product.system.name ro.vendor.product.name
    copyprop ro.product.name ro.vendor.product.name
    copyprop ro.product.system.name ro.product.vendor.device
    copyprop ro.product.name ro.product.vendor.device
    copyprop ro.system.product.brand ro.vendor.product.brand
    copyprop ro.product.brand ro.vendor.product.brand
    copyprop ro.product.system.model ro.vendor.product.model
    copyprop ro.product.model ro.vendor.product.model
    copyprop ro.product.system.model ro.product.vendor.model
    copyprop ro.product.model ro.product.vendor.model
    copyprop ro.build.product ro.vendor.product.model
    copyprop ro.build.product ro.product.vendor.model
    copyprop ro.system.product.manufacturer ro.vendor.product.manufacturer
    copyprop ro.product.manufacturer ro.vendor.product.manufacturer
    copyprop ro.system.product.manufacturer ro.product.vendor.manufacturer
    copyprop ro.product.manufacturer ro.product.vendor.manufacturer
    (getprop ro.vendor.build.security_patch; getprop ro.keymaster.xxx.security_patch) |sort |tail -n 1 |while read v;do
        [ -n "$v" ] && resetprop_phh ro.build.version.security_patch "$v"
    done

    resetprop_phh ro.build.user nobody
    resetprop_phh ro.build.host android-build
    resetprop_phh ro.build.tags release-keys
    resetprop_phh ro.product.build.tags release-keys
    resetprop_phh ro.system.build.tags release-keys
    resetprop_phh ro.system_ext.build.tags release-keys
    resetprop_phh ro.vendor.build.tags release-keys
    resetprop_phh ro.boot.vbmeta.device_state locked
    resetprop_phh ro.boot.verifiedbootstate green
    resetprop_phh ro.boot.flash.locked 1
    resetprop_phh ro.boot.veritymode enforcing
    resetprop_phh ro.boot.warranty_bit 0
    resetprop_phh ro.warranty_bit 0
    resetprop_phh ro.debuggable 0
    resetprop_phh ro.secure 1
    resetprop_phh ro.build.type user
    resetprop_phh ro.product.build.type user
    resetprop_phh ro.system.build.type user
    resetprop_phh ro.system_ext.build.type user
    resetprop_phh ro.vendor.build.type user
    resetprop_phh --delete ro.build.selinux

    resetprop_phh ro.adb.secure 1

    # Hide system/xbin/su
    mount /mnt/phh/empty_dir /system/xbin
    mount /mnt/phh/empty_dir /system/app/me.phh.superuser
    mount /mnt/phh/empty /system/xbin/phh-su
else
    mkdir /mnt/phh/xbin
    chmod 0755 /mnt/phh/xbin
    chcon u:object_r:system_file:s0 /mnt/phh/xbin

    #phh-su will bind over this empty file to make a real su
    touch /mnt/phh/xbin/su
    chcon u:object_r:system_file:s0 /mnt/phh/xbin/su

    mount -o bind /mnt/phh/xbin /system/xbin
fi

for abi in "" 64;do
    f=/vendor/lib$abi/libstagefright_foundation.so
    if [ -f "$f" ];then
        for vndk in 26 27 28 29;do
            mount "$f" /system/system_ext/apex/com.android.vndk.v$vndk/lib$abi/libstagefright_foundation.so
        done
    fi
done

setprop ro.product.first_api_level "$vndk"

if getprop ro.boot.boot_devices |grep -v , |grep -qE .;then
    ln -s /dev/block/platform/$(getprop ro.boot.boot_devices) /dev/block/bootdevice
fi

if [ -c /dev/dsm ];then
    # /dev/dsm is a magic device on Kirin chipsets that teecd needs to access.
    # Make sure that permissions are right.
    chown system:system /dev/dsm
    chmod 0660 /dev/dsm

    # The presence of /dev/dsm indicates that we have a teecd,
    # which needs /sec_storage and /data/sec_storage_data

    mkdir -p /data/sec_storage_data
    chown system:system /data/sec_storage_data
    chcon -R u:object_r:teecd_data_file:s0 /data/sec_storage_data

    if mount | grep -q " on /sec_storage " ; then
        # /sec_storage is already mounted by the vendor, don't try to create and mount it
        # ourselves. However, some devices have /sec_storage owned by root, which means that
        # the fingerprint daemon (running as system) cannot access it.
        chown -R system:system /sec_storage
        chmod -R 0660 /sec_storage
        chcon -R u:object_r:teecd_data_file:s0 /sec_storage
    else
        # No /sec_storage provided by vendor, mount /data/sec_storage_data to it
        mount /data/sec_storage_data /sec_storage
        chown system:system /sec_storage
        chcon u:object_r:teecd_data_file:s0 /sec_storage
    fi
fi

# Fix sprd adf for surfaceflinger to start
# Somehow the names of the device nodes are incorrect on Android 10; fix them by mknod
if [ -e /dev/sprd-adf-dev ];then
    mknod -m666 /dev/adf0 c 250 0
    mknod -m666 /dev/adf-interface0.0 c 250 1
    mknod -m666 /dev/adf-overlay-engine0.0 c 250 2
    restorecon /dev/adf0 /dev/adf-interface0.0 /dev/adf-overlay-engine0.0

    # SPRD GL causes crashes in system_server (not currently observed in other processes)
    # Tell the system to avoid using hardware acceleration in system_server.
    setprop ro.config.avoid_gfx_accel true
fi

# Fix sensor services crashing on SPRD devices with Pie vendor
if getprop ro.hardware.keystore | grep -iq sprd && [ "$vndk" -le 28 ]; then
    setprop persist.sys.phh.disable_sensor_direct_report true
fi

if getprop ro.build.overlay.deviceid |grep -qE '^RMX';then
    resetprop_phh ro.vendor.gsi.build.flavor byPass
    setprop sys.phh.xx.brand realme
fi

if grep -q -F ro.separate.soft /odm/build.prop;then
	setprop ro.separate.soft "$(sed -nE 's/^ro.separate.soft=(.*)/\1/p' /odm/build.prop)"
fi

if getprop ro.build.overlay.deviceid |grep -qE '^RMX';then
    chmod 0660 /sys/devices/platform/soc/soc:fpc_fpc1020/{irq,irq_enable,wakelock_enable}
    if [ "$(stat -c '%U' /sys/devices/platform/soc/soc:fpc_fpc1020/irq)" == "root" ] &&
		[ "$(stat -c '%G' /sys/devices/platform/soc/soc:fpc_fpc1020/irq)" == "root" ];then
            chown system:system /sys/devices/platform/soc/soc:fpc_fpc1020/{irq,irq_enable,wakelock_enable}
            setprop persist.sys.phh.fingerprint.nocleanup true
    fi
fi

if [ "$vndk" -le 28 ] && getprop ro.hardware |grep -q -e mt6761 -e mt6763 -e mt6765 -e mt6785 -e mt8768 -e mt6779 -e mt6771 -e mt8766;then
    setprop debug.stagefright.ccodec 0
fi

if getprop ro.omc.build.version |grep -qE .;then
	for f in $(find /odm -name \*.apk);do
		mount /mnt/phh/empty $f
	done
fi

if getprop ro.vendor.build.fingerprint |grep -qiE \
        -e Nokia/Plate2 \
        -e razer/cheryl ; then
    setprop media.settings.xml "/vendor/etc/media_profiles_vendor.xml"
fi
resetprop_phh service.adb.root 0

# This is for Samsung Galaxy devices with HBM FOD
# On those devices, a magic Layer usageBits switches to "mask_brightness"
# But default is 255, so set it to max instead
cat /sys/class/backlight/*/max_brightness |sort -n |tail -n 1 > /sys/class/lcd/panel/mask_brightness

if getprop ro.vendor.build.fingerprint |grep -qiE '^samsung/' && \
        grep -q sysfs_lcd_writable /vendor/etc/selinux/vendor_file_contexts && \
        ! grep -q vendor_sysfs_graphics /vendor/etc/selinux/vendor_file_contexts ;then
    for f in /sys/class/lcd/panel/actual_mask_brightness /sys/class/lcd/panel/mask_brightness /sys/class/lcd/panel/device/backlight/panel/brightness /sys/class/backlight/panel0-backlight/brightness;do
        if [ "$(stat -c '%U' "$f")" == "root" ] || [ "$(ls -lZ "$f" | grep -oE 'u:object_r:[^:]*:s0')" == "u:object_r:sysfs:s0" ];then
            chcon u:object_r:sysfs_lcd_writable:s0 $f
            chmod 0644 $f
            chown system:system $f
        fi
    done

    setprop persist.sys.phh.fod.samsung true
fi

if getprop ro.vendor.build.fingerprint | grep -q -e samsung/o1s -e samsung/t2s -e samsung/p3s; then
    setprop persist.sys.phh.ultrasonic_udfps true
fi

resetprop_phh ro.bluetooth.library_name libbluetooth.so

setprop vendor.display.res_switch_en 1

resetprop_phh ro.control_privapp_permissions log

if [ -f /vendor/etc/init/vendor.ozoaudio.media.c2@1.0-service.rc ];then
    if [ "$vndk" -le 29 ]; then
        mount /system/etc/seccomp_policy/mediacodec.policy /vendor/etc/seccomp_policy/codec2.vendor.base.policy
    fi
fi

if [ "$vndk" -le 27 ];then
    setprop persist.sys.phh.no_present_or_validate true
fi

[ -d /mnt/vendor/persist ] && mount /mnt/vendor/persist /persist

for f in $(find /sys -name fts_gesture_mode);do
    setprop persist.sys.phh.focaltech_node "$f"
done

if [ "$vndk" -le 27 ] && [ -f /vendor/bin/mnld ];then
    setprop persist.sys.phh.sdk_override /vendor/bin/mnld=26
fi

if [ "$vndk" -le 30 ];then
	# On older vendor the default behavior was to disable color management
	# Don't override vendor value, merely add a fallback
	setprop ro.surface_flinger.use_color_management false
fi

if [ "$(stat -c '%U'  /dev/nxp_smartpa_dev)" == "root" ] &&
	[ "$(stat -c '%G' /dev/nxp_smartpa_dev)" == "root" ];then
    chown root:audio /dev/nxp_smartpa_dev
    chmod 0660 /dev/nxp_smartpa_dev
fi

if [ -f /vendor/bin/ccci_rpcd ];then
    setprop debug.phh.props.ccci_rpcd vendor
fi

mount /mnt/phh/empty /vendor/etc/permissions/samsung.hardware.uwb.xml
mount /mnt/phh/empty /vendor/bin/install-recovery.sh

if getprop ro.vendor.radio.default_network |grep -qE '[0-9]';then
  setprop ro.telephony.default_network $(getprop ro.vendor.radio.default_network)
fi

# On those Unisoc chips, Android's bluetooth stack will try to send a LE_EXTENDED_SCAN command, which isn't actually supported
# The support of that command inherits from a "le vendor version". Force this at 0 to disable the use of that command
if getprop ro.vendor.gnsschip |grep -q -e marlin3 -e marlin3lite || getprop ro.board.platform |grep -q msm8996;then
    setprop persist.sys.bt.max_vendor_cap 0
fi

if getprop ro.boot.hardware.sku | grep -q -e fuxi -e nuwa -e ishtar; then
    setprop ro.surface_flinger.set_idle_timer_ms 1000

    setprop ro.surface_flinger.set_touch_timer_ms 800

    setprop ro.surface_flinger.set_display_power_timer_ms 4000

    setprop debug.sf.frame_rate_multiple_threshold 120

fi

if getprop ro.boot.hardware.sku | grep -q -e taoyao -e cupid -e daumier; then
    setprop ro.surface_flinger.set_idle_timer_ms 1000

    setprop ro.surface_flinger.set_touch_timer_ms 800

    setprop ro.surface_flinger.set_display_power_timer_ms 4000

    setprop debug.sf.frame_rate_multiple_threshold 120
fi

# Override media volume steps
resetprop_phh ro.config.media_vol_steps 25
resetprop_phh ro.config.media_vol_default 8

# Fix for non-AMOLED Transsion devices where brightness would be dimmer than usual
if [ -n "$(getprop ro.vendor.transsion.backlight_12bit)" ];then
    setprop ro.vendor.transsion.backlight_hal.optimization $(getprop ro.vendor.transsion.backlight_12bit)
fi

# Enable pen mode on Lenovo/goodix
echo 1 > /sys/devices/platform/goodix_ts.0/support_pen
