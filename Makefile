CLUSTER      := opscircuit
KUBECTL      := kubectl --context kind-$(CLUSTER)
KIND         := ./bin/kind
KUBECONFORM  := ./bin/kubeconform
PAYPOINT_DIR ?= ../atomictrail
SECRETS      := k8s/overlays/local/secrets.env
TF           := docker run --rm -v $(CURDIR)/terraform/aws:/work -w /work hashicorp/terraform:1.16.7
ARGOCD_VERSION := v3.5.6
K8S_SCHEMA_VERSION := 1.33.0

.PHONY: drill-outage drill-bad-deploy up tools cluster images secrets deploy observability argocd gitops-secret gitops argocd-password \
        argocd-ui smoke status validate tf-validate down

## Full local platform: cluster + PayPoint + Prometheus/Grafana
up: cluster images deploy observability smoke

tools:
	./scripts/install-tools.sh

cluster: tools
	@$(KIND) get clusters | grep -qx $(CLUSTER) || $(KIND) create cluster --config kind/cluster.yaml

## Build PayPoint images from the sibling repo and load them into the kind nodes
images:
	docker build -t paypoint-backend:local --target production $(PAYPOINT_DIR)/backend
	docker build -t paypoint-frontend:local $(PAYPOINT_DIR)/frontend
	$(KIND) load docker-image paypoint-backend:local paypoint-frontend:local --name $(CLUSTER)

## Random local secrets, created once and never committed
secrets:
	@test -f $(SECRETS) || printf 'POSTGRES_PASSWORD=%s\nJWT_SECRET=%s\nDEMO_PASSWORD=paypoint-demo\nDEMO_PARTNER_SECRET=%s\n' \
		"$$(openssl rand -hex 16)" "$$(openssl rand -hex 32)" "$$(openssl rand -hex 24)" > $(SECRETS)

deploy: secrets
	$(KUBECTL) apply -k k8s/overlays/local
	$(KUBECTL) -n paypoint rollout status statefulset/postgres --timeout=240s
	$(KUBECTL) -n paypoint rollout status deployment/backend --timeout=300s
	$(KUBECTL) -n paypoint rollout status deployment/frontend --timeout=120s

observability:
	$(KUBECTL) apply -f observability/namespace.yaml
	@$(KUBECTL) -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
		$(KUBECTL) -n monitoring create secret generic grafana-admin --from-literal=password="$$(openssl rand -hex 12)"
	$(KUBECTL) apply -k observability
	$(KUBECTL) -n monitoring rollout status deployment/prometheus --timeout=180s
	$(KUBECTL) -n monitoring rollout status deployment/grafana --timeout=300s

argocd:
	$(KUBECTL) create namespace argocd --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -n argocd --server-side --force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	$(KUBECTL) -n argocd rollout status deployment/argocd-server --timeout=420s

## The gitops overlay expects a plain "paypoint-secrets" Secret created outside git
gitops-secret: secrets
	$(KUBECTL) create namespace paypoint --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n paypoint create secret generic paypoint-secrets --from-env-file=$(SECRETS) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

## Hand the cluster over to Argo CD (instead of `make deploy`)
gitops: argocd gitops-secret
	$(KUBECTL) apply -f argocd/

argocd-password:
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

argocd-ui:
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8443:443

smoke:
	./scripts/smoke-test.sh

## Game-day drills (see docs/incidents/2026-10-30-postmortem.md)
drill-outage:
	./scripts/drills.sh outage

drill-bad-deploy:
	./scripts/drills.sh bad-deploy

status:
	$(KUBECTL) get pods -A -o wide | grep -E 'NAMESPACE|paypoint|monitoring|argocd'

## Schema validation of everything kustomize renders (also runs in CI)
validate: tools secrets
	@for dir in k8s/overlays/local k8s/overlays/gitops observability; do \
		echo "== $$dir"; kubectl kustomize $$dir | $(KUBECONFORM) -strict -summary -kubernetes-version $(K8S_SCHEMA_VERSION) - || exit 1; \
	done

tf-validate:
	$(TF) fmt -check -recursive
	$(TF) init -backend=false -input=false
	$(TF) validate

down:
	$(KIND) delete cluster --name $(CLUSTER)
