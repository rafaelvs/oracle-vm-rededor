#!/bin/bash
# Roda SOZINHO no 1º boot da VM (cloud-init user-data), sem ninguém logado.
# Deixa um Android (Redroid) rodando em container, com ADB preso ao localhost
# (acesso só por túnel SSH). Log em /var/log/preparar_vm.log; marca de pronto em /opt/rededor/PRONTO.
exec > /var/log/preparar_vm.log 2>&1
set -eux
export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/rededor/data

apt-get update
apt-get install -y docker.io adb "linux-modules-extra-$(uname -r)" || apt-get install -y docker.io adb
systemctl enable --now docker

# binder do kernel (exigido pelo Android); persiste no boot
cat > /etc/modules-load.d/redroid.conf <<'EOF'
binder_linux
EOF
echo 'options binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modprobe.d/redroid.conf
modprobe binder_linux devices="binder,hwbinder,vndbinder"
lsmod | grep -q binder_linux

# swap de 4 GB: a forma de 1 OCPU/6 GB fica apertada sem ela
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Android 13, ADB só em 127.0.0.1:5555; reinicia sozinho com a VM
docker run -d --name redroid --restart unless-stopped --privileged \
  -v /opt/rededor/data:/data -p 127.0.0.1:5555:5555 \
  redroid/redroid:13.0.0-latest \
  androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320

for i in $(seq 1 60); do
  adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
  [ "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 10
done
adb -s 127.0.0.1:5555 shell getprop ro.build.version.release
date -Is > /opt/rededor/PRONTO
