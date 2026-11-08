variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "togglemaster"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "eks_cluster_version" {
  type    = string
  default = "1.36"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type = number
  # 3 (não 2): com metrics-server + ingress-nginx + KEDA + Prometheus/Grafana
  # rodando, 2 nós de t3.medium (17 pods alocáveis cada, limite de ENI/IP da
  # instância, não de CPU/memória) já deixavam quase nenhuma folga pro HPA do
  # evaluation-service ou o KEDA do analytics-service realmente escalarem até
  # o teto durante a demonstração.
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "github_org" {
  type        = string
  description = "Org/usuário do GitHub dono do monorepo e dos repositórios ECR"
  default     = "Giovani-AJ"
}

variable "github_source_repo" {
  type        = string
  description = "Nome do monorepo (código + terraform + gitops) autorizado via OIDC a publicar no ECR"
  default     = "tech-challenge-4"
}

variable "ecr_repository_names" {
  description = "Um repositório ECR por microsserviço (independe de como o código-fonte está organizado em repos Git)"
  type        = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}
