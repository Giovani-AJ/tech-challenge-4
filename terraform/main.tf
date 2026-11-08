locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  secret_prefix = "${var.project_name}/${var.environment}"
  cluster_name  = "${local.name_prefix}-eks"
  # Um namespace por microsserviço (requisito da Fase 2).
  evaluation_namespace = "evaluation-service"
  analytics_namespace  = "analytics-service"
}

module "network" {
  source = "./modules/network"

  name_prefix  = local.name_prefix
  cluster_name = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
}

module "eks" {
  source = "./modules/eks"

  name_prefix         = local.name_prefix
  cluster_name        = local.cluster_name
  cluster_version     = var.eks_cluster_version
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# --- Bancos de dados: 3 instâncias RDS PostgreSQL (Requisito 1.3) ---

module "auth_db" {
  source = "./modules/rds"

  identifier                 = "${local.name_prefix}-auth-db"
  service_name               = "auth-service"
  db_name                    = "auth"
  instance_class             = var.db_instance_class
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
  secret_prefix              = local.secret_prefix
}

module "flag_db" {
  source = "./modules/rds"

  identifier                 = "${local.name_prefix}-flag-db"
  service_name               = "flag-service"
  db_name                    = "flagdb"
  instance_class             = var.db_instance_class
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
  secret_prefix              = local.secret_prefix
}

## MASTER_KEY do auth-service não é credencial de banco (é um segredo de aplicação),
## então gera e guarda separado, mas do mesmo jeito: nunca em texto no repositório.
resource "random_password" "auth_master_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "auth_master_key" {
  name = "${local.secret_prefix}/${local.name_prefix}-auth-service-app"
}

resource "aws_secretsmanager_secret_version" "auth_master_key" {
  secret_id     = aws_secretsmanager_secret.auth_master_key.id
  secret_string = jsonencode({ MASTER_KEY = random_password.auth_master_key.result })
}

## evaluation-service chama flag-service/targeting-service como cliente autenticado
## (SERVICE_API_KEY) — essa chave só pode ser gerada DEPOIS que o auth-service está
## no ar (é ele quem emite chaves via POST /admin/keys). O Terraform só reserva o
## "slot" no Secrets Manager com um placeholder; o valor real é atualizado à mão
## uma vez, no bootstrap (ver docs/RUNBOOK.md). `ignore_changes` evita que um
## próximo `terraform apply` sobrescreva a chave real de volta pro placeholder.
resource "aws_secretsmanager_secret" "evaluation_service_api_key" {
  name = "${local.secret_prefix}/${local.name_prefix}-evaluation-service-api-key"
}

resource "aws_secretsmanager_secret_version" "evaluation_service_api_key" {
  secret_id     = aws_secretsmanager_secret.evaluation_service_api_key.id
  secret_string = jsonencode({ SERVICE_API_KEY = "REPLACE_ME_AFTER_BOOTSTRAP" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

## Segredos da observabilidade (Fase 4): chaves do New Relic/PagerDuty e webhook do Discord.
## O Terraform só reserva o "slot" (valores REPLACE_ME); os valores reais são colocados à mão
## uma vez (`aws secretsmanager put-secret-value`, ver docs/OBSERVABILIDADE.md) — nunca no Git.
## SELFHEAL_TOKEN é gerado aqui: autentica o webhook Grafana -> self-healer.
resource "random_password" "selfheal_token" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "observability" {
  name = "${local.secret_prefix}/${local.name_prefix}-observability"
}

resource "aws_secretsmanager_secret_version" "observability" {
  secret_id = aws_secretsmanager_secret.observability.id
  secret_string = jsonencode({
    NEW_RELIC_LICENSE_KEY     = "REPLACE_ME"
    PAGERDUTY_INTEGRATION_KEY = "REPLACE_ME"
    DISCORD_WEBHOOK_URL       = "REPLACE_ME"
    SELFHEAL_TOKEN            = random_password.selfheal_token.result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

module "targeting_db" {
  source = "./modules/rds"

  identifier                 = "${local.name_prefix}-targeting-db"
  service_name               = "targeting-service"
  db_name                    = "targeting"
  instance_class             = var.db_instance_class
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
  secret_prefix              = local.secret_prefix
}

# --- Redis (Requisito 1.3) ---

module "redis" {
  source = "./modules/elasticache"

  name_prefix                = local.name_prefix
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
  node_type                  = var.redis_node_type
}

# --- DynamoDB (Requisito 1.3) ---

module "analytics_table" {
  source = "./modules/dynamodb"

  table_name = "ToggleMasterAnalytics"
}

# --- SQS (Requisito 1.4) ---

module "evaluation_queue" {
  source = "./modules/sqs"

  queue_name = "${local.name_prefix}-evaluation-events"
}

# --- ECR (Requisito 1.5) ---

module "ecr" {
  source = "./modules/ecr"

  repository_names = var.ecr_repository_names
}

# --- OIDC do GitHub Actions: quem faz o CI do monorepo pode empurrar imagem pro ECR ---

module "github_oidc" {
  source = "./modules/github-oidc"

  name_prefix         = local.name_prefix
  github_org          = var.github_org
  github_repo         = var.github_source_repo
  ecr_repository_arns = values(module.ecr.repository_arns)
}

# --- External Secrets Operator: IRSA + instalação via Helm ---

module "eso_irsa" {
  source = "./modules/irsa"

  role_name            = "${local.name_prefix}-external-secrets"
  namespace            = "external-secrets"
  service_account_name = "external-secrets"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${local.secret_prefix}/*"
    }]
  })
}

module "external_secrets" {
  source = "./modules/external-secrets"

  irsa_role_arn = module.eso_irsa.role_arn

  depends_on = [module.eks]
}

# --- ArgoCD ---

module "argocd" {
  source = "./modules/argocd"

  depends_on = [module.eks]
}

# --- Metrics Server (requisito da Fase 2: necessário pro HPA funcionar) ---

module "metrics_server" {
  source = "./modules/metrics-server"

  depends_on = [module.eks]
}

# --- Ingress-nginx + NLB (requisito da Fase 2: acesso externo por path) ---

module "ingress_nginx" {
  source = "./modules/ingress-nginx"

  depends_on = [module.eks]
}

# --- KEDA: autoscaling do analytics-service pela profundidade da fila SQS ---

module "keda_irsa" {
  source = "./modules/irsa"

  role_name            = "${local.name_prefix}-keda-operator"
  namespace            = "keda"
  service_account_name = "keda-operator"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes"]
      Resource = module.evaluation_queue.queue_arn
    }]
  })
}

module "keda" {
  source = "./modules/keda"

  irsa_role_arn = module.keda_irsa.role_arn

  depends_on = [module.eks]
}

# --- Observabilidade (Fase 4): Prometheus, Grafana, Alertmanager, Loki e OTel Collector ---
# Deixaram de ser provisionados aqui: agora são Applications do ArgoCD
# (gitops/argocd-applications/ + gitops/observability/), como pede o enunciado.

# --- IRSA dos microsserviços que falam direto com SQS/DynamoDB ---
# (auth/flag/targeting só usam Postgres, cuja credencial já vem via ESO; não precisam de IRSA)

module "evaluation_service_irsa" {
  source = "./modules/irsa"

  role_name            = "${local.name_prefix}-evaluation-service"
  namespace            = local.evaluation_namespace
  service_account_name = "evaluation-service"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = module.evaluation_queue.queue_arn
    }]
  })
}

module "analytics_service_irsa" {
  source = "./modules/irsa"

  role_name            = "${local.name_prefix}-analytics-service"
  namespace            = local.analytics_namespace
  service_account_name = "analytics-service"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = module.evaluation_queue.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.analytics_table.table_arn
      },
    ]
  })
}
