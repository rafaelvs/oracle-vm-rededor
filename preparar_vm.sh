#!/bin/bash
# Roda SOZINHO no 1º boot da VM (cloud-init user-data), sem ninguém logado.
# Deixa um Android (Redroid) rodando em container, com ADB preso ao localhost
# (acesso só por túnel SSH). Log em /var/log/preparar_vm.log; marca de pronto em /opt/rededor/PRONTO.
#
# 🔴 KERNEL: o 6.8-oracle (padrão da imagem 22.04 em 11/2026) dá KERNEL PANIC no binder_linux
# assim que o Android 13 sobe (NULL deref em binder_alloc_do_buffer_copy) — a VM some da rede
# e, com --restart, trava de novo a cada boot. Visto em 10/11/2026. Por isso:
#   fase 1 (kernel ≠ 5.15): instala o 5.15-oracle, fixa no GRUB, segura o meta 6.8, agenda a fase 2, reinicia;
#   fase 2 (kernel 5.15): binder + swap + Redroid.
exec >> /var/log/preparar_vm.log 2>&1
set -eux
export DEBIAN_FRONTEND=noninteractive
K=5.15.0-1117-oracle
mkdir -p /opt/rededor/data

if [[ "$(uname -r)" != 5.15.* ]]; then
  apt-get update
  apt-get install -y docker.io adb "linux-image-$K" "linux-modules-extra-$K"
  U=$(findmnt -no UUID /)
  echo "GRUB_DEFAULT=\"gnulinux-advanced-$U>gnulinux-$K-advanced-$U\"" > /etc/default/grub.d/99-redroid.cfg
  update-grub
  apt-mark hold linux-oracle linux-image-oracle linux-headers-oracle || true
  cp "$0" /opt/rededor/preparar_vm.sh && chmod +x /opt/rededor/preparar_vm.sh
  cat > /etc/systemd/system/preparar-fase2.service <<'EOF'
[Unit]
Description=Preparar VM rededor - fase 2 (Redroid)
After=network-online.target docker.service
Wants=network-online.target
ConditionPathExists=!/opt/rededor/PRONTO
[Service]
Type=oneshot
ExecStart=/opt/rededor/preparar_vm.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable preparar-fase2.service
  systemctl reboot
  exit 0
fi

systemctl enable --now docker

# binder do kernel (exigido pelo Android); persiste no boot
echo binder_linux > /etc/modules-load.d/redroid.conf
echo 'options binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modprobe.d/redroid.conf
modprobe binder_linux devices="binder,hwbinder,vndbinder"
lsmod | grep -q binder_linux

# swap de 4 GB: a forma de 1 OCPU/6 GB fica apertada sem ela
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Android 13, ADB só em 127.0.0.1:5555; reinicia sozinho com a VM
docker rm -f redroid 2>/dev/null || true
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
