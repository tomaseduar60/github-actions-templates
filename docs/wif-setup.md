# Workload Identity Federation: GitHub Actions → GCP

Con WIF, GitHub Actions obtiene credenciales de GCP de corta duración a partir del token OIDC del job. No hay llaves JSON que rotar ni que se puedan filtrar.

## 1. Pool y provider

```bash
PROJECT_ID=my-project
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
GITHUB_ORG=my-org

gcloud iam workload-identity-pools create github \
  --project="$PROJECT_ID" --location=global \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'"
```

La `attribute-condition` es obligatoria en la práctica: sin ella, cualquier repo de GitHub podría intentar autenticarse contra el pool.

## 2. Service account por repo

```bash
REPO="${GITHUB_ORG}/orders-api"

gcloud iam service-accounts create gha-orders-api --project="$PROJECT_ID"

# Solo este repo puede impersonarla
gcloud iam service-accounts add-iam-policy-binding \
  "gha-orders-api@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

# Permisos mínimos: publicar imágenes y desplegar en GKE
gcloud artifacts repositories add-iam-policy-binding apps \
  --location=us --project="$PROJECT_ID" \
  --role=roles/artifactregistry.writer \
  --member="serviceAccount:gha-orders-api@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --role=roles/container.developer \
  --member="serviceAccount:gha-orders-api@${PROJECT_ID}.iam.gserviceaccount.com"
```

## 3. Secrets del repo

| Secret | Valor |
|---|---|
| `WIF_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/github` |
| `WIF_SERVICE_ACCOUNT` | `gha-orders-api@<PROJECT_ID>.iam.gserviceaccount.com` |

No son credenciales: por sí solos no dan acceso a nada. Se guardan como secrets para no exponer la estructura del proyecto en los logs.

## Restringir por rama

Para que solo `main` pueda desplegar a producción, se puede usar una service account distinta por ambiente y filtrar por `attribute.ref`:

```bash
--member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.ref/refs/heads/main"
```

Combinado con un Environment de GitHub con revisores obligatorios, el deploy a producción requiere aprobación y solo puede salir de `main`.
