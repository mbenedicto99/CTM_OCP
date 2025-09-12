#!/usr/bin/env bash
# allow-controlm-and-namespace-rules.sh
# Objetivo: liberar conexão ENTRANTE do Control-M (EC2/VPN) para o API do OpenShift
#           e criar NetworkPolicy no namespace alvo
# Requisitos: executar no host que controla o firewall do VIP/masters (ou no próprio VIP),
#             e ter 'oc' configurado para acessar o cluster (ou rodar o trecho NetPol de uma máquina com oc).
set -euo pipefail

###########################
# VARIÁVEIS – ajuste aqui
###########################
CONTROL_M_CIDR="10.50.60.0/24"          # IP/CIDR da origem (EC2 ou faixa da VPN)
OPENSHIFT_API_IP="192.168.10.100"       # VIP do API server (ou IP do master que recebe 6443)
OPENSHIFT_API_PORT="6443"               # porta do API Kubernetes/OpenShift
OPENSHIFT_INGRESS_PORTS="80,443"        # se quiser liberar entrada ao Router/Ingress (opcional, vazio para ignorar)
FIREWALL_ZONE="public"                  # zona do firewalld (se aplicável)

# Regras de NetworkPolicy
OC_BIN="${OC_BIN:-oc}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NAMESPACE="meu-namespace"
POD_SELECTOR_LABELS="app=meu-app"       # pods de destino (ingress)
ALLOW_TCP_PORTS_NS="8080,9090"          # portas TCP a liberar no namespace (ingress do Control-M)
ALLOW_EGRESS_TO_CM="true"               # também liberar egress do namespace para o Control-M
EGRESS_TCP_PORTS_TO_CM="7005,7006"      # portas de destino no Control-M (parametrize conforme seu ambiente)

########################################
# FUNÇÕES FIREWALL
########################################
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

apply_firewalld_rule() {
  local ip="$1" port="$2" proto="$3"
  echo "[INFO] firewalld: liberando ${ip} -> porta ${port}/${proto} (zone=${FIREWALL_ZONE})"
  firewall-cmd --permanent --zone="$FIREWALL_ZONE" --add-rich-rule="rule family='ipv4' source address='${ip}' port protocol='${proto}' port='${port}' accept" || true
}

apply_nft_rule() {
  local ip="$1" port="$2" proto="$3"
  echo "[INFO] nftables: liberando ${ip} -> porta ${port}/${proto}"
  # cria tabela/cadeia se não existirem
  sudo nft list tables 2>/devnull | grep -q "inet filter" || sudo nft add table inet filter
  sudo nft list chain inet filter input 2>/dev/null || sudo nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
  # regra idempotente simples
  sudo nft add rule inet filter input ip saddr ${ip} tcp dport ${port} ct state new accept
}

apply_iptables_rule() {
  local ip="$1" port="$2" proto="$3"
  echo "[INFO] iptables: liberando ${ip} -> porta ${port}/${proto}"
  sudo iptables -C INPUT -p "$proto" --dport "$port" -s "$ip" -j ACCEPT 2>/dev/null || \
    sudo iptables -A INPUT -p "$proto" --dport "$port" -s "$ip" -j ACCEPT
  # persistência (ajuste conforme distro)
  if has_cmd netfilter-persistent; then
    sudo netfilter-persistent save || true
  elif has_cmd service && [[ -f /etc/sysconfig/iptables ]]; then
    sudo service iptables save || true
  fi
}

open_port_from_cidr() {
  local cidr="$1" ports_csv="$2" proto="${3:-tcp}"
  IFS=',' read -ra ports <<< "$ports_csv"
  if has_cmd firewall-cmd; then
    for p in "${ports[@]}"; do apply_firewalld_rule "$cidr" "$p" "$proto"; done
    firewall-cmd --reload
  elif has_cmd nft; then
    for p in "${ports[@]}"; do apply_nft_rule "$cidr" "$p" "$proto"; done
  else
    for p in "${ports[@]}"; do apply_iptables_rule "$cidr" "$p" "$proto"; done
  fi
}

########################################
# FUNÇÕES NETPOL (OpenShift/K8s)
########################################
render_netpol_ingress() {
  cat <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-controlm-ingress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
$(printf "      %s: \"%s\"\n" "${POD_SELECTOR_LABELS%=*}" "${POD_SELECTOR_LABELS#*=}")
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - ipBlock:
        cidr: ${CONTROL_M_CIDR}
    ports:
$(for p in $(echo "$ALLOW_TCP_PORTS_NS" | tr ',' ' '); do
  printf "    - protocol: TCP\n      port: %s\n" "$p"
done)
YAML
}

render_netpol_egress() {
  cat <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-controlm
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - ipBlock:
        cidr: ${CONTROL_M_CIDR}
    ports:
$(for p in $(echo "$EGRESS_TCP_PORTS_TO_CM" | tr ',' ' '); do
  printf "    - protocol: TCP\n      port: %s\n" "$p"
done)
YAML
}

apply_netpols() {
  echo "[INFO] Aplicando NetworkPolicy de ingress no namespace ${NAMESPACE}"
  render_netpol_ingress | "${OC_BIN}" --kubeconfig="${KUBECONFIG}" apply -f -
  if [[ "${ALLOW_EGRESS_TO_CM}" == "true" ]]; then
    echo "[INFO] Aplicando NetworkPolicy de egress para o Control-M"
    render_netpol_egress | "${OC_BIN}" --kubeconfig="${KUBECONFIG}" apply -f -
  fi
  echo "[INFO] NetworkPolicies aplicadas."
}

########################################
# EXECUÇÃO
########################################
echo "[INFO] Liberando ENTRADA do Control-M (${CONTROL_M_CIDR}) para o API do OpenShift (${OPENSHIFT_API_IP}:${OPENSHIFT_API_PORT})"
open_port_from_cidr "${CONTROL_M_CIDR}" "${OPENSHIFT_API_PORT}" "tcp"

if [[ -n "${OPENSHIFT_INGRESS_PORTS}" ]]; then
  echo "[INFO] (Opcional) Liberando ENTRADA do Control-M para Router/Ingress nas portas ${OPENSHIFT_INGRESS_PORTS}"
  open_port_from_cidr "${CONTROL_M_CIDR}" "${OPENSHIFT_INGRESS_PORTS}" "tcp"
fi

echo "[INFO] Aplicando regras no namespace via NetworkPolicy…"
apply_netpols

echo "[OK] Conclusão."
