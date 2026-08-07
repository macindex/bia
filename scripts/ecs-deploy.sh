#!/bin/bash
# =============================================================================
# Script de Deploy e Rollback - Projeto BIA
# Ambientes: cluster-bia (sem ALB) | cluster-bia-alb (com ALB)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configurações
# -----------------------------------------------------------------------------
REGION="us-east-1"
ECR_REPO_NAME="bia"
DEPLOY_TIMEOUT=600  # 10 minutos

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Funções utilitárias
# -----------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}>> $1${NC}"; }
separator()   { echo -e "${BOLD}──────────────────────────────────────────────────────${NC}"; }

# Confirma que está na raiz do repositório git
check_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    log_error "Este script precisa ser executado dentro do repositório git do projeto BIA."
    log_error "Navegue até a raiz do projeto e tente novamente."
    exit 1
  fi
}

# Retorna o short hash do commit atual
get_commit_hash() {
  git rev-parse --short HEAD
}

# Busca o URI do repositório ECR pelo nome
get_ecr_uri() {
  local uri
  uri=$(aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --query "repositories[0].repositoryUri" \
    --output text 2>/dev/null)

  if [[ -z "$uri" || "$uri" == "None" ]]; then
    log_error "Repositório ECR '${ECR_REPO_NAME}' não encontrado na região ${REGION}."
    exit 1
  fi

  echo "$uri"
}

# Autentica o Docker no ECR
ecr_login() {
  log_info "Autenticando Docker no ECR..."
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "$(get_ecr_uri | cut -d'/' -f1)" \
    2>&1 | grep -v "WARNING" || true
  log_success "Autenticado no ECR."
}

# Aguarda o serviço estabilizar
wait_for_stable() {
  local cluster="$1"
  local service="$2"

  log_step "Aguardando estabilização do serviço (timeout: ${DEPLOY_TIMEOUT}s)..."
  log_info "Cluster: ${cluster} | Service: ${service}"

  if aws ecs wait services-stable \
    --cluster "${cluster}" \
    --services "${service}" \
    --region "${REGION}" \
    2>/dev/null; then
    log_success "Serviço estabilizado com sucesso!"
    return 0
  else
    log_error "Timeout ou falha ao aguardar estabilização do serviço."
    log_warn "Verifique os eventos do serviço no console AWS ECS."
    return 1
  fi
}

# Mostra o status atual do service após o deploy
show_service_status() {
  local cluster="$1"
  local service="$2"

  local status
  status=$(aws ecs describe-services \
    --cluster "${cluster}" \
    --services "${service}" \
    --region "${REGION}" \
    --query "services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount,TaskDef:taskDefinition}" \
    --output json)

  local running desired pending task_def
  running=$(echo "$status" | jq -r '.Running')
  desired=$(echo "$status" | jq -r '.Desired')
  pending=$(echo "$status" | jq -r '.Pending')
  task_def=$(echo "$status" | jq -r '.TaskDef' | rev | cut -d'/' -f1 | rev)

  echo ""
  separator
  echo -e "  ${BOLD}Status do Serviço${NC}"
  separator
  echo -e "  Task Definition : ${CYAN}${task_def}${NC}"
  echo -e "  Desejadas       : ${desired}"
  echo -e "  Em execução     : ${GREEN}${running}${NC}"
  echo -e "  Pendentes       : ${YELLOW}${pending}${NC}"
  separator
}

# -----------------------------------------------------------------------------
# Menu: Escolha do ambiente
# -----------------------------------------------------------------------------
choose_environment() {
  echo ""
  separator
  echo -e "  ${BOLD}Escolha o Ambiente${NC}"
  separator
  echo -e "  ${CYAN}1)${NC} Sem ALB  →  cluster-bia         /  service-bia         /  task-def-bia"
  echo -e "  ${CYAN}2)${NC} Com ALB  →  cluster-bia-alb     /  service-bia-alb     /  task-def-bia-alb"
  separator
  echo ""

  local choice
  while true; do
    read -rp "  Digite sua escolha [1 ou 2]: " choice
    case "$choice" in
      1)
        CLUSTER="cluster-bia"
        SERVICE="service-bia"
        TASK_DEF_FAMILY="task-def-bia"
        log_success "Ambiente selecionado: SEM ALB"
        break
        ;;
      2)
        CLUSTER="cluster-bia-alb"
        SERVICE="service-bia-alb"
        TASK_DEF_FAMILY="task-def-bia-alb"
        log_success "Ambiente selecionado: COM ALB"
        break
        ;;
      *)
        log_warn "Opção inválida. Digite 1 ou 2."
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Fluxo de DEPLOY
# -----------------------------------------------------------------------------
do_deploy() {
  choose_environment

  local commit_hash
  commit_hash=$(get_commit_hash)

  local ecr_uri
  ecr_uri=$(get_ecr_uri)

  local image_tag="${ecr_uri}:${commit_hash}"

  echo ""
  separator
  echo -e "  ${BOLD}Resumo do Deploy${NC}"
  separator
  echo -e "  Commit Hash     : ${CYAN}${commit_hash}${NC}"
  echo -e "  Imagem          : ${image_tag}"
  echo -e "  Cluster         : ${CLUSTER}"
  echo -e "  Service         : ${SERVICE}"
  echo -e "  Task Definition : ${TASK_DEF_FAMILY}"
  separator
  echo ""

  read -rp "  Confirma o deploy? [s/N]: " confirm
  [[ "$confirm" =~ ^[sS]$ ]] || { log_warn "Deploy cancelado."; exit 0; }

  # --- Build da imagem ---
  log_step "1/5 - Build da imagem Docker"
  log_info "Tag: ${image_tag}"
  docker build -t "${image_tag}" .
  log_success "Build concluído."

  # --- Login no ECR ---
  log_step "2/5 - Autenticação no ECR"
  ecr_login

  # --- Push da imagem ---
  log_step "3/5 - Push da imagem para o ECR"
  docker push "${image_tag}"
  log_success "Push concluído: ${image_tag}"

  # --- Registrar nova revisão da Task Definition ---
  log_step "4/5 - Registrando nova revisão da Task Definition"

  # Busca a task definition atual completa
  local current_task_def
  current_task_def=$(aws ecs describe-task-definition \
    --task-definition "${TASK_DEF_FAMILY}" \
    --region "${REGION}" \
    --query "taskDefinition" \
    --output json)

  # Gera o novo JSON substituindo apenas a imagem do container
  local new_task_def_json
  new_task_def_json=$(echo "$current_task_def" | jq \
    --arg IMAGE "$image_tag" \
    'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
     .containerDefinitions[0].image = $IMAGE')

  # Registra a nova revisão
  local new_revision
  new_revision=$(aws ecs register-task-definition \
    --region "${REGION}" \
    --cli-input-json "$new_task_def_json" \
    --query "taskDefinition.revision" \
    --output text)

  log_success "Nova revisão registrada: ${TASK_DEF_FAMILY}:${new_revision}"

  # --- Atualizar o Service ---
  log_step "5/5 - Atualizando o ECS Service"
  aws ecs update-service \
    --cluster "${CLUSTER}" \
    --service "${SERVICE}" \
    --task-definition "${TASK_DEF_FAMILY}:${new_revision}" \
    --region "${REGION}" \
    --output json > /dev/null

  log_success "Service atualizado para ${TASK_DEF_FAMILY}:${new_revision}"

  # --- Aguardar estabilização ---
  wait_for_stable "${CLUSTER}" "${SERVICE}"

  # --- Status final ---
  show_service_status "${CLUSTER}" "${SERVICE}"

  echo ""
  log_success "Deploy finalizado! Commit ${commit_hash} está rodando no ambiente."
}

# -----------------------------------------------------------------------------
# Fluxo de ROLLBACK
# -----------------------------------------------------------------------------
do_rollback() {
  choose_environment

  log_step "Buscando revisões da Task Definition: ${TASK_DEF_FAMILY}"

  # Lista todas as revisões ativas (ACTIVE)
  local revisions
  revisions=$(aws ecs list-task-definitions \
    --family-prefix "${TASK_DEF_FAMILY}" \
    --status ACTIVE \
    --sort DESC \
    --region "${REGION}" \
    --query "taskDefinitionArns" \
    --output json)

  local count
  count=$(echo "$revisions" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    log_error "Nenhuma revisão ativa encontrada para ${TASK_DEF_FAMILY}."
    exit 1
  fi

  # Descobre a revisão atualmente em uso pelo service
  local current_task_def_arn
  current_task_def_arn=$(aws ecs describe-services \
    --cluster "${CLUSTER}" \
    --services "${SERVICE}" \
    --region "${REGION}" \
    --query "services[0].taskDefinition" \
    --output text)
  local current_revision
  current_revision=$(echo "$current_task_def_arn" | rev | cut -d':' -f1 | rev)

  echo ""
  separator
  echo -e "  ${BOLD}Revisões disponíveis — ${TASK_DEF_FAMILY}${NC}"
  separator
  printf "  %-10s %-12s %-30s %s\n" "REVISÃO" "STATUS" "IMAGEM (TAG/COMMIT)" "REGISTRADA EM"
  separator

  # Exibe cada revisão com detalhes
  local arns_array
  mapfile -t arns_array < <(echo "$revisions" | jq -r '.[]')

  for arn in "${arns_array[@]}"; do
    local rev_number image_tag registered_at marker

    rev_number=$(echo "$arn" | rev | cut -d':' -f1 | rev)

    local details
    details=$(aws ecs describe-task-definition \
      --task-definition "$arn" \
      --region "${REGION}" \
      --query "taskDefinition.{image: containerDefinitions[0].image, registeredAt: registeredAt}" \
      --output json)

    image_tag=$(echo "$details" | jq -r '.image' | rev | cut -d':' -f1 | rev)
    registered_at=$(echo "$details" | jq -r '.registeredAt' | cut -d'T' -f1,2 | tr 'T' ' ' | cut -d'.' -f1)

    if [[ "$rev_number" == "$current_revision" ]]; then
      marker="${GREEN}[EM USO]${NC}"
    else
      marker=""
    fi

    printf "  %-10s %-12s %-30s %s %b\n" \
      "${rev_number}" \
      "ACTIVE" \
      "${image_tag}" \
      "${registered_at}" \
      "${marker}"
  done

  separator
  echo -e "  ${YELLOW}Revisão atual em uso: ${current_revision}${NC}"
  separator
  echo ""

  # Solicita a revisão desejada
  local target_revision
  while true; do
    read -rp "  Digite o número da revisão para rollback: " target_revision

    if [[ "$target_revision" == "$current_revision" ]]; then
      log_warn "A revisão ${target_revision} já está em uso. Escolha uma revisão diferente."
      continue
    fi

    # Verifica se a revisão existe na lista
    local valid=false
    for arn in "${arns_array[@]}"; do
      local rev
      rev=$(echo "$arn" | rev | cut -d':' -f1 | rev)
      if [[ "$rev" == "$target_revision" ]]; then
        valid=true
        break
      fi
    done

    if [[ "$valid" == true ]]; then
      break
    else
      log_warn "Revisão '${target_revision}' não encontrada. Escolha um número da lista acima."
    fi
  done

  # Busca a imagem da revisão alvo para exibir no resumo
  local target_image
  target_image=$(aws ecs describe-task-definition \
    --task-definition "${TASK_DEF_FAMILY}:${target_revision}" \
    --region "${REGION}" \
    --query "taskDefinition.containerDefinitions[0].image" \
    --output text | rev | cut -d':' -f1 | rev)

  echo ""
  separator
  echo -e "  ${BOLD}Resumo do Rollback${NC}"
  separator
  echo -e "  Revisão atual   : ${YELLOW}${TASK_DEF_FAMILY}:${current_revision}${NC}"
  echo -e "  Rollback para   : ${CYAN}${TASK_DEF_FAMILY}:${target_revision}${NC} (imagem: ${target_image})"
  echo -e "  Cluster         : ${CLUSTER}"
  echo -e "  Service         : ${SERVICE}"
  separator
  echo ""

  read -rp "  Confirma o rollback? [s/N]: " confirm
  [[ "$confirm" =~ ^[sS]$ ]] || { log_warn "Rollback cancelado."; exit 0; }

  # --- Atualizar o Service para a revisão escolhida ---
  log_step "Aplicando rollback para ${TASK_DEF_FAMILY}:${target_revision}"

  aws ecs update-service \
    --cluster "${CLUSTER}" \
    --service "${SERVICE}" \
    --task-definition "${TASK_DEF_FAMILY}:${target_revision}" \
    --region "${REGION}" \
    --output json > /dev/null

  log_success "Service atualizado para ${TASK_DEF_FAMILY}:${target_revision}"

  # --- Aguardar estabilização ---
  wait_for_stable "${CLUSTER}" "${SERVICE}"

  # --- Status final ---
  show_service_status "${CLUSTER}" "${SERVICE}"

  echo ""
  log_success "Rollback concluído! Serviço rodando com ${TASK_DEF_FAMILY}:${target_revision} (commit: ${target_image})."
}

# -----------------------------------------------------------------------------
# Menu Principal
# -----------------------------------------------------------------------------
main() {
  clear
  echo ""
  separator
  echo -e "  ${BOLD}${CYAN}BIA — Deploy & Rollback ECS${NC}"
  echo -e "  Região: ${REGION} | Repositório ECR: ${ECR_REPO_NAME}"
  separator
  echo ""
  echo -e "  ${CYAN}1)${NC} Deploy   — build, push e atualização do serviço ECS"
  echo -e "  ${CYAN}2)${NC} Rollback — reverter para uma revisão anterior da Task Definition"
  echo -e "  ${CYAN}0)${NC} Sair"
  echo ""
  separator
  echo ""

  local action
  while true; do
    read -rp "  O que deseja fazer? [0, 1 ou 2]: " action
    case "$action" in
      1)
        check_git_repo
        do_deploy
        break
        ;;
      2)
        do_rollback
        break
        ;;
      0)
        log_info "Até logo!"
        exit 0
        ;;
      *)
        log_warn "Opção inválida. Digite 0, 1 ou 2."
        ;;
    esac
  done
}

main
