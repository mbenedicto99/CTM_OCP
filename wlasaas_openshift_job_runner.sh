#!/usr/bin/env bash
# Control-M -> OpenShift Job Runner
# Ubuntu 24.x | Requer: oc (CLI), acesso via KUBECONFIG ou token
# Saída: exit 0 = sucesso do Job no cluster; !=0 = falha

set -euo pipefail

#############################
# VARIÁVEIS (ajuste no Control-M)
#############################
: "${KUBECONFIG:=/opt/controlm/secrets/kubeconfig}"     # caminho do kubeconfig (montado via Secret/Agent Vault)
: "${OC_BIN:=/usr/local/bin/oc}"                        # caminho do 'oc'
: "${NAMESPACE:=meu-namespace}"                         # namespace alvo
: "${JOB_NAME:=job-exemplo}"                            # nome único do Job
: "${IMAGE:=registry.access.redhat.com/ubi9/ubi-minimal}"
: "${CMD:=/bin/sh -lc 'echo hello from control-m && sleep 2'}"
: "${CPU_REQUEST:=100m}"
: "${MEM_REQUEST:=128Mi}"
: "${CPU_LIMIT:=500m}"
: "${MEM_LIMIT:=256Mi}"
: "${JOB_TTL_SECONDS:=600}"                             # TTL pós-conclusão (limpeza automática)
: "${JOB_ACTIVE_DEADLINE:=900}"                         # tempo máx de execução do Job
: "${WAIT_TIMEOUT:=1200s}"                              # tempo de espera para completar
: "${CLEANUP:=true}"                                    # true/false apagar Job após logs
: "${ANNOTATIONS:=controlm/source=ec2,workload/type=batch,env=prod}"  # annotations extras (vírgula separadas)

#############################
# FUNÇÕES AUXILIARES
#############################
fail() { echo "[ERRO] $*" >&2; exit 2; }
info() { echo "[INFO] $*"; }

check_prereqs() {
  [[ -x "$OC_BIN" ]] || fail "oc não encontrado em $OC_BIN"
  [[ -r "$KUBECONFIG" ]] || fail "KUBECONFIG inacessível em $KUBECONFIG"
  "$OC_BIN" --kubeconfig="$KUBECONFIG" whoami >/dev/null 2>&1 || fail "falha no auth/cluster (oc whoami)"
  "$OC_BIN" --kubeconfig="$KUBECONFIG" get ns "$NAMESPACE" >/dev/null 2>&1 || fail "namespace $NAMESPACE inexistente/inacessível"
}

to_yaml_annotations() {
  # Converte "k=v,k2=v2" em YAML
  local IFS=','; for pair in $ANNOTATIONS; do
    echo "    $(echo "$pair" | awk -F= '{printf "%s: \"%s\"\n",$1,$2}')"
  done
}

render_job_yaml() {
cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  annotations:
$(to_yaml_annotations)
spec:
  ttlSecondsAfterFinished: ${JOB_TTL_SECONDS}
  activeDeadlineSeconds: ${JOB_ACTIVE_DEADLINE}
  backoffLimit: 0
  template:
    metadata:
      annotations:
$(to_yaml_annotations)
      labels:
        app.kubernetes.io/name: ${JOB_NAME}
        app.kubernetes.io/managed-by: control-m
    spec:
      restartPolicy: Never
      serviceAccountName: controlm-sa
      containers:
      - name: ${JOB_NAME}
        image: ${IMAGE}
        command: ["/bin/sh","-lc","${CMD}"]
        resources:
          requests:
            cpu: "${CPU_REQUEST}"
            memory: "${MEM_REQUEST}"
          limits:
            cpu: "${CPU_LIMIT}"
            memory: "${MEM_LIMIT}"
YAML
}

submit_job() {
  info "Aplicando Job ${JOB_NAME} no namespace ${NAMESPACE}…"
  render_job_yaml | "$OC_BIN" --kubeconfig="$KUBECONFIG" apply -f -
}

wait_job() {
  info "Aguardando conclusão do Job… timeout ${WAIT_TIMEOUT}"
  set +e
  "$OC_BIN" --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="$WAIT_TIMEOUT"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    info "Job não completou com sucesso. Verificando falha…"
    "$OC_BIN" --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pods -l job-name="$JOB_NAME" -o wide || true
    "$OC_BIN" --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" logs -l job-name="$JOB_NAME" --all-containers --tail=-1 || true
    fail "Job falhou ou expirou o tempo de espera"
  fi
}

print_logs() {
  info "Logs do Job:"
  "$OC_BIN" --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" logs -l job-name="$JOB_NAME" --all-containers --tail=-1
}

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Removendo Job ${JOB_NAME}…"
    "$OC_BIN" --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found
  else
    info "CLEANUP=false: mantendo Job para inspeção"
  fi
}

#############################
# EXECUÇÃO
#############################
check_prereqs
submit_job
wait_job
print_logs
cleanup
info "Job finalizado com sucesso."
exit 0
