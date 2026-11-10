## Instala o ingress-nginx via Helm, expondo os 5 microsserviços publicamente
## através de um Network Load Balancer (NLB). Mesma ferramenta usada na Fase 2,
## agora provisionada como código em vez de instalação manual no console.

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name

  # Não espera o Service type=LoadBalancer ficar pronto: a criação do NLB pode
  # ficar pendente por tempo indeterminado (restrição de conta nova na AWS),
  # e isso não deveria travar os hooks do chart (geração do certificado do
  # admission webhook), que rodam independente do LB existir ou não.
  wait = false

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Classic ELB (tipo padrão do Kubernetes), e não NLB: nesta conta AWS a criação de NLB/ALB é
  # recusada pela AWS ("This AWS account currently does not support creating load balancers",
  # OperationNotPermitted em ELBv2), mas o Classic ELB (API ELB v1) funciona. Por isso NÃO usamos a
  # annotation service.beta.kubernetes.io/aws-load-balancer-type=nlb. Validado em 10/11/2026:
  # o ELB foi criado e a API respondeu HTTP 200 por ele. Se a conta for liberada, dá para voltar ao NLB.

  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }
}
