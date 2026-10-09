#!/usr/bin/env bash
# =============================================================================
# ecs-deploy.sh — Deploy, rollback e listagem de versões no ECS
# Projeto: BIA | Formação AWS
#
# Uso:
#   ./ecs-deploy.sh deploy <commit-hash>    Faz deploy da imagem com a tag informada
#   ./ecs-deploy.sh rollback <revisão>      Faz rollback para uma revisão da task def
#   ./ecs-deploy.sh list                    Lista as últimas revisões da task definition
#
# Exemplos:
#   ./ecs-deploy.sh deploy a1b2c3d
#   ./ecs-deploy.sh list
#   ./ecs-deploy.sh rollback 7
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO — altere aqui para trocar de ambiente
# -----------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-cluster-bia}"
SERVICE="${SERVICE:-service-bia}"
TASK_DEF_FAMILY="${TASK_DEF_FAMILY:-task-def-bia}"
CONTAINER_NAME="${CONTAINER_NAME:-bia}"
ECR_REPO="${ECR_REPO:-072875453389.dkr.ecr.us-east-1.amazonaws.com/bia}"
LIST_LIMIT="${LIST_LIMIT:-3}"
# -----------------------------------------------------------------------------

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

usage() {
  echo ""
  echo "Uso: $0 <comando> [argumento]"
  echo ""
  echo "Comandos:"
  echo "  deploy <commit-hash>   Faz deploy da imagem com a tag do commit"
  echo "  rollback <revisão>     Faz rollback para uma revisão da task definition"
  echo "  list                   Lista as últimas ${LIST_LIMIT} revisões da task definition"
  echo ""
  echo "Variáveis de ambiente (opcionais):"
  echo "  CLUSTER          Cluster ECS          (padrão: cluster-bia)"
  echo "  SERVICE          Service ECS          (padrão: service-bia)"
  echo "  TASK_DEF_FAMILY  Família da task def  (padrão: task-def-bia)"
  echo "  CONTAINER_NAME   Nome do container    (padrão: bia)"
  echo "  ECR_REPO         URI do repositório   (padrão: 072875453389.dkr.ecr.us-east-1.amazonaws.com/bia)"
  echo "  AWS_REGION       Região AWS           (padrão: us-east-1)"
  echo "  LIST_LIMIT       Qtd de revisões      (padrão: 3)"
  echo ""
  echo "Exemplo para ambiente com ALB:"
  echo "  CLUSTER=cluster-bia-alb SERVICE=service-bia-alb TASK_DEF_FAMILY=task-def-bia-alb \\"
  echo "    $0 deploy a1b2c3d"
  echo ""
}

# Verifica dependências
check_deps() {
  for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Dependência não encontrada: $cmd"
      exit 1
    fi
  done
}

# Busca a task definition ativa atual do service
get_current_task_def_arn() {
  aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$AWS_REGION" \
    --query "services[0].taskDefinition" \
    --output text
}

# Função: list
cmd_list() {
  log_info "Listando as últimas ${LIST_LIMIT} revisões de '${TASK_DEF_FAMILY}'..."
  echo ""

  # Busca a revisão ativa atual
  CURRENT_ARN=$(get_current_task_def_arn)
  CURRENT_REV=$(echo "$CURRENT_ARN" | awk -F: '{print $NF}')

  # Lista as ARNs das últimas revisões (ordem decrescente)
  REVISIONS=$(aws ecs list-task-definitions \
    --family-prefix "$TASK_DEF_FAMILY" \
    --sort DESC \
    --max-items "$LIST_LIMIT" \
    --region "$AWS_REGION" \
    --query "taskDefinitionArns[]" \
    --output json)

  if [[ "$REVISIONS" == "[]" ]]; then
    log_warn "Nenhuma revisão encontrada para a família '${TASK_DEF_FAMILY}'."
    exit 0
  fi

  printf "%-10s %-12s %-35s %s\n" "REVISÃO" "STATUS" "IMAGEM (TAG)" "CRIADA EM"
  printf "%-10s %-12s %-35s %s\n" "-------" "------" "-----------" "---------"

  echo "$REVISIONS" | jq -r '.[]' | while read -r ARN; do
    REV=$(echo "$ARN" | awk -F: '{print $NF}')

    DETAILS=$(aws ecs describe-task-definition \
      --task-definition "$ARN" \
      --region "$AWS_REGION" \
      --query "{image: taskDefinition.containerDefinitions[0].image, createdAt: taskDefinition.registeredAt}" \
      --output json)

    IMAGE=$(echo "$DETAILS" | jq -r '.image')
    CREATED=$(echo "$DETAILS" | jq -r '.createdAt' | cut -d'.' -f1 | tr 'T' ' ')
    TAG=$(echo "$IMAGE" | awk -F: '{print $NF}')

    if [[ "$REV" == "$CURRENT_REV" ]]; then
      printf "${GREEN}%-10s${NC} %-12s %-35s %s\n" "$REV" "[ATIVA]" "$TAG" "$CREATED"
    else
      printf "%-10s %-12s %-35s %s\n" "$REV" "" "$TAG" "$CREATED"
    fi
  done

  echo ""
  log_info "Revisão atualmente ativa no service '${SERVICE}': ${CURRENT_REV}"
  echo ""
}

# Função: deploy
cmd_deploy() {
  local COMMIT_HASH="$1"

  if [[ -z "$COMMIT_HASH" ]]; then
    log_error "Informe o commit hash. Exemplo: $0 deploy a1b2c3d"
    exit 1
  fi

  local IMAGE="${ECR_REPO}:${COMMIT_HASH}"

  log_info "Iniciando deploy..."
  log_info "  Cluster:    ${CLUSTER}"
  log_info "  Service:    ${SERVICE}"
  log_info "  Task Def:   ${TASK_DEF_FAMILY}"
  log_info "  Container:  ${CONTAINER_NAME}"
  log_info "  Imagem:     ${IMAGE}"
  echo ""

  # Busca a task definition atual
  log_info "Buscando task definition ativa..."
  CURRENT_TASK_DEF_ARN=$(get_current_task_def_arn)
  log_info "Task definition atual: ${CURRENT_TASK_DEF_ARN}"

  # Obtém o JSON completo da task definition atual
  TASK_DEF_JSON=$(aws ecs describe-task-definition \
    --task-definition "$CURRENT_TASK_DEF_ARN" \
    --region "$AWS_REGION" \
    --query "taskDefinition" \
    --output json)

  # Monta o JSON da nova task definition com a nova imagem
  NEW_TASK_DEF=$(echo "$TASK_DEF_JSON" | jq \
    --arg CONTAINER "$CONTAINER_NAME" \
    --arg IMAGE "$IMAGE" \
    '.containerDefinitions |= map(if .name == $CONTAINER then .image = $IMAGE else . end)
    | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

  # Registra a nova revisão
  log_info "Registrando nova revisão da task definition..."
  NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --region "$AWS_REGION" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)

  NEW_REV=$(echo "$NEW_TASK_DEF_ARN" | awk -F: '{print $NF}')
  log_success "Nova task definition registrada: revisão ${NEW_REV}"

  # Atualiza o service com a nova task definition
  log_info "Atualizando service '${SERVICE}' para revisão ${NEW_REV}..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$NEW_TASK_DEF_ARN" \
    --region "$AWS_REGION" \
    --output json > /dev/null

  log_success "Deploy disparado com sucesso!"
  log_info  "  Commit:    ${COMMIT_HASH}"
  log_info  "  Task def:  ${NEW_TASK_DEF_ARN}"
  echo ""
  log_warn  "O deploy está em andamento. Acompanhe pelo console ECS ou execute:"
  echo "  aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE} --region ${AWS_REGION} --query 'services[0].{status:status,running:runningCount,desired:desiredCount,deployments:deployments[*].{status:status,taskDef:taskDefinition}}'"
  echo ""
}

# Função: rollback
cmd_rollback() {
  local REVISION="$1"

  if [[ -z "$REVISION" ]]; then
    log_error "Informe o número da revisão. Exemplo: $0 rollback 5"
    log_warn  "Use '$0 list' para ver as revisões disponíveis."
    exit 1
  fi

  # Valida que é um número
  if ! [[ "$REVISION" =~ ^[0-9]+$ ]]; then
    log_error "Revisão inválida: '${REVISION}'. Deve ser um número inteiro."
    exit 1
  fi

  local TASK_DEF_ARN="${TASK_DEF_FAMILY}:${REVISION}"

  log_info "Iniciando rollback..."
  log_info "  Cluster:   ${CLUSTER}"
  log_info "  Service:   ${SERVICE}"
  log_info "  Task Def:  ${TASK_DEF_FAMILY}:${REVISION}"
  echo ""

  # Verifica se a revisão existe
  log_info "Verificando revisão ${REVISION}..."
  TASK_DEF_CHECK=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --region "$AWS_REGION" \
    --query "taskDefinition.{arn:taskDefinitionArn,image:containerDefinitions[0].image}" \
    --output json 2>/dev/null || echo "{}")

  if [[ "$TASK_DEF_CHECK" == "{}" ]]; then
    log_error "Revisão '${REVISION}' não encontrada para a família '${TASK_DEF_FAMILY}'."
    log_warn  "Use '$0 list' para ver as revisões disponíveis."
    exit 1
  fi

  TARGET_ARN=$(echo "$TASK_DEF_CHECK" | jq -r '.arn')
  TARGET_IMAGE=$(echo "$TASK_DEF_CHECK" | jq -r '.image' | awk -F: '{print $NF}')

  log_info "Revisão encontrada:"
  log_info "  ARN:    ${TARGET_ARN}"
  log_info "  Imagem: ${TARGET_IMAGE}"
  echo ""

  # Atualiza o service para a revisão alvo
  log_info "Atualizando service '${SERVICE}' para revisão ${REVISION}..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" \
    --region "$AWS_REGION" \
    --output json > /dev/null

  log_success "Rollback disparado com sucesso!"
  log_info  "  Revisão:  ${REVISION}"
  log_info  "  Imagem:   ${TARGET_IMAGE}"
  echo ""
  log_warn  "O rollback está em andamento. Acompanhe pelo console ECS ou execute:"
  echo "  aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE} --region ${AWS_REGION} --query 'services[0].{status:status,running:runningCount,desired:desiredCount,deployments:deployments[*].{status:status,taskDef:taskDefinition}}'"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
check_deps

COMMAND="${1:-}"

case "$COMMAND" in
  deploy)
    cmd_deploy "${2:-}"
    ;;
  rollback)
    cmd_rollback "${2:-}"
    ;;
  list)
    cmd_list
    ;;
  ""|help|--help|-h)
    usage
    ;;
  *)
    log_error "Comando desconhecido: '${COMMAND}'"
    usage
    exit 1
    ;;
esac
