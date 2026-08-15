#!/bin/bash
set -e

# =============================================================================
# deploy-bia.sh — Deploy e Rollback para os ambientes ECS do projeto BIA
# =============================================================================
# Uso:
#   ./scripts/deploy-bia.sh deploy   → build, push ECR e deploy no ECS
#   ./scripts/deploy-bia.sh rollback → lista revisões e faz rollback
# =============================================================================

# ── Configurações fixas ───────────────────────────────────────────────────────
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="072875453389"
ECR_REPO="bia"
CONTAINER_NAME="bia"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

# ── Cores para output ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Funções utilitárias ───────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }

# ── Seleção de ambiente ───────────────────────────────────────────────────────
select_environment() {
  echo ""
  echo -e "${BOLD}Selecione o ambiente:${NC}"
  echo "  1) Sem ALB  (cluster-bia / service-bia / task-def-bia)"
  echo "  2) Com ALB  (cluster-bia-alb / service-bia-alb / task-def-bia-alb)"
  echo ""
  read -rp "Digite 1 ou 2: " ENV_CHOICE

  case "$ENV_CHOICE" in
    1)
      CLUSTER="cluster-bia"
      SERVICE="service-bia"
      TASK_DEF_FAMILY="task-def-bia"
      ;;
    2)
      CLUSTER="cluster-bia-alb"
      SERVICE="service-bia-alb"
      TASK_DEF_FAMILY="task-def-bia-alb"
      ;;
    *)
      error "Opção inválida. Use 1 ou 2."
      ;;
  esac

  info "Ambiente selecionado: ${BOLD}${CLUSTER}${NC}"
}

# ── Login no ECR ──────────────────────────────────────────────────────────────
ecr_login() {
  info "Autenticando no ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" \
    > /dev/null 2>&1
  success "Login no ECR realizado."
}

# ── Aguardar serviço estabilizar ──────────────────────────────────────────────
wait_for_service() {
  info "Aguardando serviço estabilizar (pode levar alguns minutos)..."
  aws ecs wait services-stable \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE"
  success "Serviço estabilizado com sucesso!"
}

# ── Mostrar status final do serviço ──────────────────────────────────────────
show_service_status() {
  info "Status atual do serviço:"
  aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query "services[0].{Status:status, Running:runningCount, Desired:desiredCount, Pending:pendingCount, TaskDef:taskDefinition}" \
    --output table
}

# ── Buscar IP público da EC2 do cluster ──────────────────────────────────────
get_cluster_ec2_ip() {
  info "Buscando instâncias EC2 registradas no cluster ${CLUSTER}..."

  # Lista os ARNs das container instances do cluster
  CONTAINER_INSTANCE_ARNS=$(aws ecs list-container-instances \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --status ACTIVE \
    --query "containerInstanceArns" \
    --output json)

  if [[ "$CONTAINER_INSTANCE_ARNS" == "[]" || -z "$CONTAINER_INSTANCE_ARNS" ]]; then
    error "Nenhuma instância EC2 ativa encontrada no cluster '${CLUSTER}'. Verifique se o cluster está rodando."
  fi

  # Pega o ARN da primeira instância
  FIRST_ARN=$(echo "$CONTAINER_INSTANCE_ARNS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")

  # Busca o EC2 Instance ID a partir da container instance
  EC2_INSTANCE_ID=$(aws ecs describe-container-instances \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --container-instances "$FIRST_ARN" \
    --query "containerInstances[0].ec2InstanceId" \
    --output text)

  if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "None" ]]; then
    error "Não foi possível obter o EC2 Instance ID da container instance do cluster '${CLUSTER}'."
  fi

  info "EC2 Instance ID encontrado: ${BOLD}${EC2_INSTANCE_ID}${NC}"

  # Busca o IP público da instância EC2
  EC2_PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$EC2_INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

  if [[ -z "$EC2_PUBLIC_IP" || "$EC2_PUBLIC_IP" == "None" ]]; then
    error "A instância ${EC2_INSTANCE_ID} não possui IP público. Verifique se a instância está com IP público habilitado."
  fi

  success "IP público da EC2 do cluster: ${BOLD}${EC2_PUBLIC_IP}${NC}"
}

# =============================================================================
# DEPLOY
# =============================================================================
do_deploy() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}            DEPLOY — Projeto BIA        ${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"

  select_environment

  # ── Validar que estamos em um repositório git ─────────────────────────────
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    error "Este diretório não é um repositório git."
  fi

  # ── Obter short hash do commit ────────────────────────────────────────────
  COMMIT_HASH=$(git rev-parse --short HEAD)
  info "Commit hash: ${BOLD}${COMMIT_HASH}${NC}"

  IMAGE_TAG="${ECR_URI}:${COMMIT_HASH}"
  info "Imagem que será gerada: ${IMAGE_TAG}"

  echo ""
  read -rp "Confirma o deploy com hash ${COMMIT_HASH} no ambiente ${CLUSTER}? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { warn "Deploy cancelado."; exit 0; }

  # ── Resolver endpoint de API (ALB DNS ou IP da EC2) ──────────────────────
  DOCKERFILE_PATH="$(git rev-parse --show-toplevel)/Dockerfile"
  BUILD_CONTEXT="$(git rev-parse --show-toplevel)"

  if [[ "$ENV_CHOICE" == "2" ]]; then
    # Com ALB: usar o DNS do ALB como endpoint — estável e não muda
    info "Buscando DNS do ALB associado ao cluster ${CLUSTER}..."
    ALB_DNS=$(aws elbv2 describe-load-balancers \
      --region "$AWS_REGION" \
      --query "LoadBalancers[?LoadBalancerName=='bia-alb'].DNSName" \
      --output text)

    if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
      error "Não foi possível obter o DNS do ALB 'bia-alb'. Verifique se o ALB está ativo."
    fi

    API_ENDPOINT="$ALB_DNS"
    success "DNS do ALB encontrado: ${BOLD}${API_ENDPOINT}${NC}"
  else
    # Sem ALB: usar o IP público da EC2 do cluster
    get_cluster_ec2_ip
    API_ENDPOINT="$EC2_PUBLIC_IP"
  fi

  # Linha atual de VITE_API_URL no Dockerfile (para restaurar depois)
  ORIGINAL_VITE_LINE=$(grep "VITE_API_URL=" "$DOCKERFILE_PATH")

  if [[ -z "$ORIGINAL_VITE_LINE" ]]; then
    error "Não foi encontrada a variável VITE_API_URL no Dockerfile. Verifique se o Dockerfile está correto."
  fi

  # Extrai o valor original completo (pode ser IP ou DNS) para restaurar depois
  ORIGINAL_VITE_VALUE=$(echo "$ORIGINAL_VITE_LINE" | grep -oP 'VITE_API_URL=\K.*' | tr -d '"')

  info "VITE_API_URL atual no Dockerfile: ${BOLD}${ORIGINAL_VITE_VALUE}${NC}"
  info "Atualizando VITE_API_URL para http://${API_ENDPOINT}..."

  # Garante restauração do Dockerfile mesmo se o script falhar durante o build
  trap 'info "Restaurando Dockerfile original..."; sed -i "s|VITE_API_URL=http://[^ ]*|VITE_API_URL=${ORIGINAL_VITE_VALUE}|" "$DOCKERFILE_PATH"; success "Dockerfile restaurado."' EXIT

  # Substitui o valor no Dockerfile (IP ou DNS anterior → novo endpoint)
  sed -i "s|VITE_API_URL=http://[^ ]*|VITE_API_URL=http://${API_ENDPOINT}|" "$DOCKERFILE_PATH"
  success "Dockerfile atualizado: VITE_API_URL=http://${API_ENDPOINT}"

  # ── Build da imagem ───────────────────────────────────────────────────────
  info "Iniciando build da imagem Docker..."

  docker build -t "${ECR_REPO}:${COMMIT_HASH}" -f "$DOCKERFILE_PATH" "$BUILD_CONTEXT"
  success "Build concluído."

  # ── Restaurar Dockerfile após o build ─────────────────────────────────────
  trap - EXIT
  info "Restaurando Dockerfile original..."
  sed -i "s|VITE_API_URL=http://[^ ]*|VITE_API_URL=${ORIGINAL_VITE_VALUE}|" "$DOCKERFILE_PATH"
  success "Dockerfile restaurado para o valor original (${ORIGINAL_VITE_VALUE})."

  # ── Tag e push para ECR ───────────────────────────────────────────────────
  ecr_login

  info "Tagueando imagem para o ECR..."
  docker tag "${ECR_REPO}:${COMMIT_HASH}" "$IMAGE_TAG"

  info "Fazendo push da imagem para o ECR..."
  docker push "$IMAGE_TAG"
  success "Push concluído: ${IMAGE_TAG}"

  # ── Buscar task definition atual ─────────────────────────────────────────
  info "Buscando configuração atual da task definition ${TASK_DEF_FAMILY}..."
  CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$TASK_DEF_FAMILY" \
    --query "taskDefinition" \
    --output json)

  if [[ -z "$CURRENT_TASK_DEF" || "$CURRENT_TASK_DEF" == "null" ]]; then
    error "Task definition '${TASK_DEF_FAMILY}' não encontrada. Crie-a antes do primeiro deploy."
  fi

  CURRENT_REVISION=$(echo "$CURRENT_TASK_DEF" | python3 -c "import sys,json; print(json.load(sys.stdin)['revision'])")
  info "Revisão atual da task definition: ${BOLD}${CURRENT_REVISION}${NC}"

  # ── Montar nova task definition com a imagem nova ─────────────────────────
  info "Criando nova revisão da task definition com a imagem ${COMMIT_HASH}..."

  NEW_TASK_DEF=$(echo "$CURRENT_TASK_DEF" | python3 -c "
import sys, json

td = json.load(sys.stdin)

# Atualizar imagem do container
for container in td['containerDefinitions']:
    if container['name'] == '${CONTAINER_NAME}':
        container['image'] = '${IMAGE_TAG}'

# Remover campos que a API não aceita no registro
for field in ['taskDefinitionArn', 'revision', 'status', 'requiresAttributes',
              'compatibilities', 'registeredAt', 'registeredBy', 'deregisteredAt']:
    td.pop(field, None)

print(json.dumps(td))
")

  # ── Registrar nova revisão ────────────────────────────────────────────────
  NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --region "$AWS_REGION" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)

  NEW_REVISION=$(echo "$NEW_TASK_DEF_ARN" | awk -F: '{print $NF}')
  success "Nova revisão registrada: ${BOLD}${TASK_DEF_FAMILY}:${NEW_REVISION}${NC}"

  # ── Atualizar o service ───────────────────────────────────────────────────
  info "Atualizando service ${SERVICE} com a nova revisão..."
  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$NEW_TASK_DEF_ARN" \
    --force-new-deployment \
    --query "service.{Service:serviceName, TaskDef:taskDefinition, Status:status}" \
    --output table > /dev/null

  success "Deploy iniciado!"

  # ── Aguardar estabilização ────────────────────────────────────────────────
  wait_for_service
  show_service_status

  echo ""
  success "Deploy do commit ${BOLD}${COMMIT_HASH}${NC} concluído com sucesso!"
  echo ""
}

# =============================================================================
# ROLLBACK
# =============================================================================
do_rollback() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}           ROLLBACK — Projeto BIA       ${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"

  select_environment

  # ── Listar revisões disponíveis ───────────────────────────────────────────
  info "Buscando revisões disponíveis de ${TASK_DEF_FAMILY}..."

  REVISIONS=$(aws ecs list-task-definitions \
    --region "$AWS_REGION" \
    --family-prefix "$TASK_DEF_FAMILY" \
    --status ACTIVE \
    --sort DESC \
    --query "taskDefinitionArns" \
    --output json)

  if [[ "$REVISIONS" == "[]" || -z "$REVISIONS" ]]; then
    error "Nenhuma revisão encontrada para ${TASK_DEF_FAMILY}."
  fi

  # ── Buscar revisão atual do service ──────────────────────────────────────
  CURRENT_TASK_DEF_ARN=$(aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query "services[0].taskDefinition" \
    --output text)

  echo ""
  echo -e "${BOLD}Revisões disponíveis para ${TASK_DEF_FAMILY}:${NC}"
  echo "────────────────────────────────────────────────────────────────────"
  printf "  %-5s %-10s %-55s %s\n" "Rev" "Status" "Imagem" ""
  echo "────────────────────────────────────────────────────────────────────"

  # Montar lista de ARNs
  REVISION_LIST=()
  while IFS= read -r ARN; do
    REVISION_LIST+=("$ARN")
  done < <(echo "$REVISIONS" | python3 -c "import sys,json; [print(a) for a in json.load(sys.stdin)]")

  INDEX=1
  for ARN in "${REVISION_LIST[@]}"; do
    REV_NUM=$(echo "$ARN" | awk -F: '{print $NF}')
    IMAGE=$(aws ecs describe-task-definition \
      --region "$AWS_REGION" \
      --task-definition "$ARN" \
      --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].image" \
      --output text)

    # Marcar revisão atual
    CURRENT_MARKER=""
    if [[ "$ARN" == "$CURRENT_TASK_DEF_ARN" ]]; then
      CURRENT_MARKER="${GREEN}← atual${NC}"
    fi

    printf "  ${BOLD}%-5s${NC} rev:%-6s %-55s %b\n" "$INDEX" "$REV_NUM" "$IMAGE" "$CURRENT_MARKER"
    INDEX=$((INDEX + 1))
  done

  echo "────────────────────────────────────────────────────────────────────"
  echo ""
  echo -e "${YELLOW}[AVISO]${NC} O rollback não altera o IP da API no frontend."
  echo -e "        O ${BOLD}VITE_API_URL${NC} (IP público da EC2) foi fixado dentro de cada imagem"
  echo -e "        no momento em que ela foi buildada. Para corrigir o IP, execute um"
  echo -e "        novo ${BOLD}deploy${NC} com a instância EC2 do cluster em execução."
  echo ""

  # ── Escolha da revisão ────────────────────────────────────────────────────
  read -rp "Digite o número da revisão desejada para rollback (ou 'q' para sair): " CHOICE

  [[ "$CHOICE" == "q" || "$CHOICE" == "Q" ]] && { warn "Rollback cancelado."; exit 0; }

  # Validar entrada
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#REVISION_LIST[@]} )); then
    error "Opção inválida. Digite um número entre 1 e ${#REVISION_LIST[@]}."
  fi

  TARGET_ARN="${REVISION_LIST[$((CHOICE - 1))]}"
  TARGET_REV=$(echo "$TARGET_ARN" | awk -F: '{print $NF}')

  # Verificar se é a revisão atual
  if [[ "$TARGET_ARN" == "$CURRENT_TASK_DEF_ARN" ]]; then
    warn "Essa já é a revisão atualmente em uso no service."
    read -rp "Deseja forçar o redeploy mesmo assim? (s/N): " FORCE
    [[ "$FORCE" =~ ^[sS]$ ]] || { warn "Rollback cancelado."; exit 0; }
  fi

  TARGET_IMAGE=$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$TARGET_ARN" \
    --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].image" \
    --output text)

  echo ""
  info "Revisão selecionada: ${BOLD}${TASK_DEF_FAMILY}:${TARGET_REV}${NC}"
  info "Imagem: ${TARGET_IMAGE}"
  echo ""
  read -rp "Confirma rollback para a revisão ${TARGET_REV} no ambiente ${CLUSTER}? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { warn "Rollback cancelado."; exit 0; }

  # ── Atualizar service ─────────────────────────────────────────────────────
  info "Executando rollback para ${TASK_DEF_FAMILY}:${TARGET_REV}..."
  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TARGET_ARN" \
    --force-new-deployment \
    --query "service.{Service:serviceName, TaskDef:taskDefinition, Status:status}" \
    --output table > /dev/null

  success "Rollback iniciado!"

  # ── Aguardar estabilização ────────────────────────────────────────────────
  wait_for_service
  show_service_status

  echo ""
  success "Rollback para revisão ${BOLD}${TARGET_REV}${NC} concluído com sucesso!"
  echo ""
}

# =============================================================================
# ENTRY POINT
# =============================================================================
case "${1:-}" in
  deploy)
    do_deploy
    ;;
  rollback)
    do_rollback
    ;;
  *)
    echo ""
    echo -e "${BOLD}Uso:${NC}"
    echo "  $0 deploy    → Build, push para ECR e deploy no ECS"
    echo "  $0 rollback  → Lista revisões e faz rollback"
    echo ""
    exit 1
    ;;
esac
