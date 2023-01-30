#!/bin/bash
set -eo pipefail

## Default to X88-Pro-B (RK3318)
ver="${1:-x88pro_b_3318}"
#ver="${1:-t9_3328}"

[[ $# -ge 1 ]] && shift 1
if [[ $# -ge 0 ]]; then
  armbian_extra_flags=("$@")
  echo "Passing additional args to Armbian ${armbian_extra_flags[*]}"
else
  armbian_extra_flags=("")
fi

C=$(pwd)
A=../../armbian
P="rkbox_${ver}"
B="current"
if [[ ${ver} == "t9_3328" || ${ver} == "x88pro_b_3318" ]]
then
  echo "rk3318 box selected, rockchip64 kernel"
  T="rk3318-box"
  K="rockchip64"
else
  echo "rk322x box selected, rk322x kernel"
  T="rk322x-box"
  K="rk322x"
fi

# Make sure we grab the right version
ARMBIAN_VERSION=$(cat ${A}/VERSION)

# Custom patches
echo "Adding custom patches"
ls "${C}/patches/"
mkdir -p "${A}"/userpatches/kernel/"${K}"-"${B}"/
rm -rf "${A}"/userpatches/kernel/"${K}"-"${B}"/*.patch
cp "${C}"/patches/*.patch "${A}"/userpatches/kernel/"${K}"-"${B}"/

# Custom kernel Config
if [ -e "${C}"/kernel-config/linux-"${K}"-"${B}".config ]
then
  echo "Copy custom Kernel config"
  ls "${C}"/kernel-config/linux-"${K}"-"${B}".config
  cp "${C}"/kernel-config/linux-"${K}"-"${B}".config "${A}"/userpatches/
fi

# Select specific Kernel and/or U-Boot version
rm -rf "${A}"/userpatches/lib.config
if [ -e "${C}"/kernel-ver/"${P}".config ]
then
  echo "Copy specific kernel/uboot version config"
  cp "${C}"/kernel-ver/"${P}"*.config "${A}"/userpatches/lib.config
fi

cd ${A}
ARMBIAN_HASH=$(git rev-parse --short HEAD)
echo "Building for $P -- with Armbian ${ARMBIAN_VERSION} -- $B"

./compile.sh BOARD="${T}" BRANCH="${B}" RELEASE=buster KERNEL_CONFIGURE=no EXTERNAL=yes BUILD_KSRC=no BUILD_DESKTOP=no BUILD_ONLY=u-boot,kernel,armbian-firmware "${armbian_extra_flags[@]}"

echo "Done!"

cd "${C}"
echo "Creating platform ${P} files"
[[ -d ${P} ]] && rm -rf "${P}"
mkdir -p "${P}"/u-boot
mkdir -p "${P}"/lib/firmware
mkdir -p "${P}"/boot/overlay-user
# Keep a copy for later just in case
cp "${A}/output/debs/linux-headers-${B}-${K}_${ARMBIAN_VERSION}"_* "${C}"

dpkg-deb -x "${A}/output/debs/linux-dtb-${B}-${K}_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/linux-image-${B}-${K}_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/linux-u-boot-${B}-${T}_${ARMBIAN_VERSION}"_* "${P}"
dpkg-deb -x "${A}/output/debs/armbian-firmware_${ARMBIAN_VERSION}"_* "${P}"

# Copy bootloader, dtb and image
if [[ ${T} == "rk3318-box" ]]
then
  echo "Select rk3318-box bootloader, dtb and image"
  cp "${P}"/usr/lib/linux-u-boot-${B}-*/idbloader.img "${P}/u-boot"
  cp "${P}"/usr/lib/linux-u-boot-${B}-*/u-boot.itb "${P}/u-boot"
  mv "${P}"/boot/dtb* "${P}"/boot/dtb
  mv "${P}"/boot/vmlinuz* "${P}"/boot/Image
else
  echo "Select rk322x-box bootloader, dtb and image"
  cp "${P}"/usr/lib/linux-u-boot-${B}-*/u-boot-rk322x-with-spl.bin "${P}/u-boot"
  mv "${P}"/boot/dtb* "${P}"/boot/dtb
  mv "${P}"/boot/vmlinuz* "${P}"/boot/zImage
fi

# Clean up unneeded parts
rm -rf "${P}/lib/firmware/.git"
rm -rf "${P:?}/usr" "${P:?}/etc"

# Compile and copy over overlay(s) files
for dts in "${C}"/overlay-user/overlays-"${P}"/*.dts; do
  dts_file=${dts%%.*}
  if [ -s "${dts_file}.dts" ]
  then
    echo "Compiling ${dts_file}"
    dtc -O dtb -o "${dts_file}.dtbo" "${dts_file}.dts"
    cp "${dts_file}.dtbo" "${P}"/boot/overlay-user
  fi
done

# Compile and copy custom dtb files
for dts in "${C}"/custom-dtb/*.dts; do
  dts_file=${dts%%.*}
  if [ -s "${dts_file}.dts" ]
  then
    echo "Compiling ${dts_file}"
    dtc -I dts -O dtb -o "${dts_file}.dtb" "${dts_file}.dts"
    mv "${dts_file}.dtb" "${P}"/boot/dtb/rockchip
  fi
done


# Copy and compile boot script
cp "${A}"/config/bootscripts/boot-"${K}".cmd "${P}"/boot/boot.cmd
mkimage -C none -A arm -T script -d "${P}"/boot/boot.cmd "${P}"/boot/boot.scr

# Signal mainline kernel
touch "${P}"/boot/.next

# Prepare boot parameters
cp "${C}"/bootparams/"${P}".armbianEnv.txt "${P}"/boot/armbianEnv.txt

echo "Creating device tarball.."
tar cJf "${P}_${B}.tar.xz" "$P"

echo "Renaming tarball for Build scripts to pick things up"
mv "${P}_${B}.tar.xz" "${P}.tar.xz"
KERNEL_VERSION="$(basename ./"${P}"/boot/config-*)"
KERNEL_VERSION=${KERNEL_VERSION#*-}
echo "Creating a version file Kernel: ${KERNEL_VERSION}"
cat <<EOF >"${C}/version"
BUILD_DATE=$(date +"%m-%d-%Y")
ARMBIAN_VERSION=${ARMBIAN_VERSION}
ARMBIAN_HASH=${ARMBIAN_HASH}
KERNEL_VERSION=${KERNEL_VERSION}
EOF

echo "Cleaning up.."
rm -rf "${P}"
