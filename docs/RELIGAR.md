# Religar o ambiente (≈ 40 min) e desligar de novo

O ambiente foi desligado com `terraform destroy` para não gastar créditos. Tudo é código: recriar é
repetir estes passos. Rode na raiz do repositório, no Git Bash.

## 1. Infraestrutura (≈ 20 min)
```bash
cd terraform
cat > backend.hcl <<'HCL'
bucket       = "togglemaster-tfstate-56bbf220"
key          = "togglemaster/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
HCL
terraform init -backend-config=backend.hcl
terraform apply -auto-approve
cd ..
```
Se falhar com `ResourceNotFoundException` em `aws_eks_access_policy_association` (condição de corrida
do EKS), é só rodar `terraform apply -auto-approve` de novo.

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-dev-eks
kubectl get nodes        # 3 nós Ready
```

## 2. Imagens (o ECR é recriado vazio) (≈ 6 min)
Os pipelines buildam, escaneiam (Trivy) e publicam, e depois atualizam a tag no GitOps.
Use a conta **Giovani-AJ** do `gh`:
```bash
export GH_TOKEN=$(gh auth token -u Giovani-AJ)
for s in auth flag targeting evaluation analytics; do
  gh workflow run "CI - $s-service" --repo Giovani-AJ/tech-challenge-4 --ref main
done
gh run list --repo Giovani-AJ/tech-challenge-4 --limit 5     # esperar todos "completed success"
git pull --rebase origin main                                # traz os commits com as tags novas
```

## 3. ArgoCD (≈ 5 min)
Aplique tudo **menos** o alerting (ele lê as chaves do cofre; ver passo 5):
```bash
for f in gitops/argocd-applications/*.yaml; do
  [ "$(basename $f)" = "observability-alerting.yaml" ] || kubectl apply -f "$f"
done
kubectl get applications -n argocd        # esperar Synced/Healthy
```

## 4. Dados do ambiente (≈ 3 min)
Cria as tabelas, a chave do evaluation-service e a `demo-flag`:
```bash
bash scripts/religar-bootstrap.sh
```

## 5. Chaves e alertas (≈ 5 min)
```bash
bash scripts/set-observability-secrets.sh          # New Relic, PagerDuty e Discord (as 3 chaves)
T=$(date +%s)
kubectl annotate externalsecret observability-secrets -n monitoring force-sync=$T --overwrite
kubectl annotate externalsecret self-healer-secret -n self-healing force-sync=$T --overwrite
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
kubectl get pods -n monitoring --no-headers | grep otel-gateway | awk '{print $1}' | xargs kubectl delete pod -n monitoring
kubectl apply -f gitops/argocd-applications/observability-alerting.yaml
```

## 6. Conferir
```bash
bash scripts/gera-trafego.sh 3
```
Grafana (dashboard com dados), New Relic (5 serviços e Service Map) e Alerting (regra **Normal**).
O roteiro do vídeo tem a ordem de gravação.

## Desligar (parar o custo)
```bash
cd terraform && terraform destroy -auto-approve
```
Depois confirme que não sobrou nada cobrando (EKS, NAT, RDS, ElastiCache, load balancers) e force a
exclusão dos segredos que ficam "agendados para exclusão" por 30 dias:
```bash
for id in $(aws secretsmanager list-secrets --region us-east-1 --include-planned-deletion \
    --query "SecretList[?starts_with(Name,'togglemaster/')].Name" --output text); do
  aws secretsmanager delete-secret --region us-east-1 --secret-id "$id" --force-delete-without-recovery
done
```
