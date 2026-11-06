#!/bin/bash
# Tenta criar a VM Always Free ARM "vm-rededor" (Oracle, sa-saopaulo-1) até conseguir ou até o prazo.
# A rede (VCN rede-rededor / sub-rededor) já existe; o script só a procura pelo nome.
# Saída: 0 = VM existe/criada; 3 = acabou o prazo sem vaga; outro = erro (falha ALTO).
set -u
NOME=vm-rededor
PRAZO_MIN=${PRAZO_MIN:-55}
T="$OCI_TENANCY"
FIM=$(( $(date +%s) + PRAZO_MIN * 60 ))

existe() {
  oci compute instance list -c "$T" --display-name $NOME --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>/dev/null
}
ip_de() {
  oci compute instance list-vnics --instance-id "$1" --query 'data[0]."public-ip"' --raw-output
}

VM=$(existe)
if [ -n "$VM" ] && [ "$VM" != "null" ]; then
  echo "RESULTADO: JA_EXISTE IP=$(ip_de "$VM")"; exit 0
fi

AD=$(oci iam availability-domain list -c "$T" --query 'data[0].name' --raw-output) || exit 1
SN=$(oci network subnet list -c "$T" --display-name sub-rededor --query 'data[0].id' --raw-output) || exit 1
[ -z "$SN" ] || [ "$SN" = "null" ] && { echo "ERRO: subnet sub-rededor não encontrada"; exit 1; }
IMG=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output) || exit 1
echo "$SSH_PUB" > /tmp/pub

n=0
while [ "$(date +%s)" -lt "$FIM" ]; do
  for CFG in '{"ocpus":4,"memoryInGBs":24}' '{"ocpus":2,"memoryInGBs":12}'; do
    n=$((n + 1))
    OUT=$(oci compute instance launch -c "$T" --availability-domain "$AD" --display-name $NOME \
      --shape VM.Standard.A1.Flex --shape-config "$CFG" --image-id "$IMG" --subnet-id "$SN" \
      --assign-public-ip true --boot-volume-size-in-gbs 100 --ssh-authorized-keys-file /tmp/pub \
      --wait-for-state RUNNING --max-wait-seconds 600 2>&1)
    VM=$(echo "$OUT" | grep -o '"id": "ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$VM" ]; then
      echo "RESULTADO: CRIADA $CFG IP=$(ip_de "$VM") tentativa=$n"; exit 0
    fi
    if echo "$OUT" | grep -qiE "capacity|TooManyRequests"; then
      echo "$(date -u +%H:%M) tentativa $n $CFG: sem vaga"
    else
      echo "ERRO inesperado na tentativa $n:"; echo "$OUT" | grep -iE '"code"|"message"' | head -4; exit 2
    fi
    sleep 45
  done
done
echo "RESULTADO: SEM_VAGA_NO_PRAZO tentativas=$n"; exit 3
