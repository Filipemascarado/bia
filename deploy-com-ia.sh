#!/bin/bash

# =============================================================================
# deploy-com-ia.sh — Deploy e Rollback para ECS (Projeto BIA)
# =============================================================================
# Ambientes suportados:
#   sem ALB → cluster-bia        / service-bia        / task-def-bia
#   com ALB → cluster-bia-alb   / service-bia-alb    / task-def-bia-alb
# =============================================================================

set -euo pipefail

# ── Configurações ─────────────────────────────────────────────────────────────
REGION="us-east-1"
ECR_REGISTRY="072875453389.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="bia"

# ── Cores ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Funções utilitárias ────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERRO]${RESET} $*" >&2; exit 1; }

separator() { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

# ── Seleção de ambiente ────────────────────────────────────────────────────────
escolher_ambiente() {
    separator
    echo -e "${BOLD}Qual ambiente deseja usar?${RESET}"
    echo "  1) Sem ALB  (cluster-bia / service-bia / task-def-bia)"
    echo "  2) Com ALB  (cluster-bia-alb / service-bia-alb / task-def-bia-alb)"
    separator
    read -rp "Digite 1 ou 2: " opcao_amb

    case "$opcao_amb" in
        1)
            CLUSTER="cluster-bia"
            SERVICE="service-bia"
            TASK_FAMILY="task-def-bia"
            ;;
        2)
            CLUSTER="cluster-bia-alb"
            SERVICE="service-bia-alb"
            TASK_FAMILY="task-def-bia-alb"
            ;;
        *)
            error "Opção inválida. Execute o script novamente e escolha 1 ou 2."
            ;;
    esac

    success "Ambiente selecionado: ${BOLD}$CLUSTER${RESET}"
}

# ── DEPLOY ─────────────────────────────────────────────────────────────────────
fazer_deploy() {
    escolher_ambiente

    # Captura o short commit hash
    if ! COMMIT_HASH=$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null); then
        error "Não foi possível obter o commit hash. Certifique-se de estar em um repositório Git."
    fi

    IMAGE_TAG="$COMMIT_HASH"
    IMAGE_URI="$ECR_REGISTRY/$ECR_REPO:$IMAGE_TAG"

    separator
    info "Iniciando deploy..."
    info "Commit hash : ${BOLD}$COMMIT_HASH${RESET}"
    info "Imagem      : ${BOLD}$IMAGE_URI${RESET}"
    info "Cluster     : ${BOLD}$CLUSTER${RESET}"
    info "Service     : ${BOLD}$SERVICE${RESET}"
    info "Task Family : ${BOLD}$TASK_FAMILY${RESET}"
    separator

    # 1. Login no ECR
    info "Autenticando no ECR..."
    aws ecr get-login-password --region "$REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    success "Login no ECR realizado."

    # 2. Build da imagem
    info "Fazendo build da imagem Docker..."
    docker build -t "$ECR_REPO" "$(dirname "$0")"
    success "Build concluído."

    # 3. Tag com o commit hash
    info "Aplicando tag ${IMAGE_TAG}..."
    docker tag "$ECR_REPO:latest" "$IMAGE_URI"
    success "Tag aplicada: $IMAGE_URI"

    # 4. Push para o ECR
    info "Enviando imagem para o ECR..."
    docker push "$IMAGE_URI"
    success "Push concluído."

    # 5. Busca a task definition atual para usar como base
    info "Buscando task definition atual ($TASK_FAMILY)..."
    TASK_DEF_JSON=$(aws ecs describe-task-definition \
        --region "$REGION" \
        --task-definition "$TASK_FAMILY" \
        --query "taskDefinition" \
        --output json)

    # 6. Atualiza a imagem do container na task definition
    info "Registrando nova revisão da task definition com a nova imagem..."
    NEW_TASK_DEF_JSON=$(echo "$TASK_DEF_JSON" | python3 -c "
import json, sys

td = json.load(sys.stdin)
new_image = '${IMAGE_URI}'

# Atualiza a imagem no primeiro container (container da aplicação)
for container in td.get('containerDefinitions', []):
    if '${ECR_REPO}' in container.get('image', ''):
        container['image'] = new_image
        break

# Remove campos que não podem ser enviados no register
for field in ['taskDefinitionArn', 'revision', 'status', 'requiresAttributes',
              'compatibilities', 'registeredAt', 'registeredBy', 'deregisteredAt']:
    td.pop(field, None)

print(json.dumps(td))
")

    NEW_REVISION=$(aws ecs register-task-definition \
        --region "$REGION" \
        --cli-input-json "$NEW_TASK_DEF_JSON" \
        --query "taskDefinition.revision" \
        --output text)

    success "Nova revisão registrada: ${BOLD}${TASK_FAMILY}:${NEW_REVISION}${RESET}"

    # 7. Atualiza o service com a nova task definition
    info "Atualizando o ECS service com ${TASK_FAMILY}:${NEW_REVISION}..."
    aws ecs update-service \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "${TASK_FAMILY}:${NEW_REVISION}" \
        --output json > /dev/null

    success "Service atualizado. Aguardando estabilização..."

    # 8. Aguarda o serviço estabilizar
    aws ecs wait services-stable \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --services "$SERVICE"

    separator
    success "Deploy concluído com sucesso!"
    info "Imagem    : ${BOLD}$IMAGE_URI${RESET}"
    info "Revisão   : ${BOLD}${TASK_FAMILY}:${NEW_REVISION}${RESET}"
    separator
}

# ── ROLLBACK ───────────────────────────────────────────────────────────────────
fazer_rollback() {
    escolher_ambiente

    separator
    info "Buscando revisões disponíveis para ${BOLD}$TASK_FAMILY${RESET}..."
    separator

    # Lista todas as revisões ativas (últimas 20 para não poluir)
    REVISIONS=$(aws ecs list-task-definitions \
        --region "$REGION" \
        --family-prefix "$TASK_FAMILY" \
        --status ACTIVE \
        --sort DESC \
        --max-items 20 \
        --query "taskDefinitionArns[]" \
        --output json)

    REVISION_COUNT=$(echo "$REVISIONS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

    if [ "$REVISION_COUNT" -eq 0 ]; then
        error "Nenhuma revisão ativa encontrada para a task definition '$TASK_FAMILY'."
    fi

    # Exibe tabela de revisões com imagem e data de criação
    echo -e "${BOLD}  #   Revisão                    Imagem (tag)          Criada em${RESET}"
    separator

    # Coleta detalhes de cada revisão
    REVISION_LIST=()
    INDEX=1

    while IFS= read -r ARN; do
        DETAIL=$(aws ecs describe-task-definition \
            --region "$REGION" \
            --task-definition "$ARN" \
            --query "taskDefinition.{rev:revision, image:containerDefinitions[0].image, created:registeredAt}" \
            --output json)

        REV=$(echo "$DETAIL"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['rev'])")
        IMAGE=$(echo "$DETAIL"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['image'].split(':')[-1] if ':' in d['image'] else d['image'])")
        CREATED=$(echo "$DETAIL"| python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('created','N/A')[:19].replace('T',' ') if d.get('created') else 'N/A')")

        printf "  ${CYAN}%-3s${RESET} %-26s %-22s %s\n" \
            "$INDEX" "${TASK_FAMILY}:${REV}" "$IMAGE" "$CREATED"

        REVISION_LIST+=("${TASK_FAMILY}:${REV}")
        INDEX=$((INDEX + 1))
    done < <(echo "$REVISIONS" | python3 -c "import json,sys; [print(x) for x in json.load(sys.stdin)]")

    separator

    # Obtém a revisão atual em uso pelo service
    CURRENT_REV=$(aws ecs describe-services \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --query "services[0].taskDefinition" \
        --output text | awk -F: '{print $NF}')

    info "Revisão atualmente em uso pelo service: ${BOLD}${TASK_FAMILY}:${CURRENT_REV}${RESET}"
    separator

    read -rp "Digite o número da revisão para rollback (1-${#REVISION_LIST[@]}): " ESCOLHA

    # Valida a escolha
    if ! [[ "$ESCOLHA" =~ ^[0-9]+$ ]] || [ "$ESCOLHA" -lt 1 ] || [ "$ESCOLHA" -gt "${#REVISION_LIST[@]}" ]; then
        error "Opção inválida. Execute o script novamente."
    fi

    TARGET_REVISION="${REVISION_LIST[$((ESCOLHA - 1))]}"
    TARGET_REV_NUM=$(echo "$TARGET_REVISION" | awk -F: '{print $NF}')

    if [ "$TARGET_REV_NUM" -eq "$CURRENT_REV" ]; then
        warn "A revisão escolhida (${TARGET_REVISION}) já é a que está em uso. Nenhuma ação necessária."
        exit 0
    fi

    separator
    info "Iniciando rollback para ${BOLD}${TARGET_REVISION}${RESET}..."
    info "Cluster : ${BOLD}$CLUSTER${RESET}"
    info "Service : ${BOLD}$SERVICE${RESET}"
    separator

    # Atualiza o service para a revisão escolhida
    aws ecs update-service \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "$TARGET_REVISION" \
        --output json > /dev/null

    success "Service atualizado. Aguardando estabilização..."

    aws ecs wait services-stable \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --services "$SERVICE"

    separator
    success "Rollback concluído com sucesso!"
    info "Revisão ativa agora: ${BOLD}${TARGET_REVISION}${RESET}"
    separator
}

# ── Menu principal ─────────────────────────────────────────────────────────────
main() {
    clear
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║         BIA — Deploy & Rollback no ECS           ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  1) Deploy  — build, push e nova revisão da task def"
    echo "  2) Rollback — escolha uma revisão anterior para restaurar"
    echo "  0) Sair"
    echo ""
    separator
    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in
        1) fazer_deploy ;;
        2) fazer_rollback ;;
        0) info "Saindo."; exit 0 ;;
        *) error "Opção inválida. Execute o script novamente." ;;
    esac
}

main
