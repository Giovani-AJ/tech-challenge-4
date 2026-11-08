## 5 repositórios ECR, um por microsserviço, com scan automático no push
## (camada extra de SCA/imagem, além do Trivy que roda no pipeline) e lifecycle
## policy pra não acumular imagem intermediária sem tag.

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  # Laboratório: permite `terraform destroy` mesmo com imagens dentro (sem isso a exclusão falha
  # com RepositoryNotEmptyException). As imagens são recriadas pelo CI (docs/RELIGAR.md).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expira imagens sem tag após 7 dias"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
