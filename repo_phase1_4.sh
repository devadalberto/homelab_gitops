#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(pwd)"

ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
DOMAIN_BASE=home.arpa
LAN_CIDR=192.168.88.0/24
METALLB_RANGE=192.168.88.200-192.168.88.220
TRAEFIK_LB_IP=192.168.88.201
NEXTCLOUD_LB_IP=192.168.88.202
DJANGO_LB_IP=192.168.88.203
MINECRAFT_LB_IP=192.168.88.204
MINIKUBE_CPUS=2
MINIKUBE_MEMORY_MB=8192
MINIKUBE_DISK_SIZE=40g
POSTGRES_DATA_DIR=/srv/apps/postgres
DJANGO_MEDIA_DIR=/srv/apps/django-media
NEXTCLOUD_DATA_DIR=/srv/nextcloud
MINECRAFT_DATA_DIR=/srv/minecraft
EOF
fi

mkdir -p k8s/storage
cat > k8s/storage/postgres-hostpath.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-postgres
spec:
  capacity:
    storage: 20Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-hostpath
  hostPath:
    path: /srv/apps/postgres
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-postgres
  namespace: data
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: local-hostpath
  volumeName: pv-postgres
EOF

cat > k8s/storage/django-media-hostpath.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-django-media
spec:
  capacity:
    storage: 10Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-hostpath
  hostPath:
    path: /srv/apps/django-media
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-django-media
  namespace: django
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-hostpath
  volumeName: pv-django-media
EOF

cat > k8s/storage/minecraft-hostpath.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-minecraft
spec:
  capacity:
    storage: 60Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-hostpath
  hostPath:
    path: /srv/minecraft
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-minecraft
  namespace: minecraft
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 60Gi
  storageClassName: local-hostpath
  volumeName: pv-minecraft
EOF

mkdir -p k8s/base
cat > k8s/base/storageclass.yaml <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-hostpath
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF

mkdir -p k8s/addons/metallb
cat > k8s/addons/metallb/ip-pool.yaml <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.88.200-192.168.88.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2adv
  namespace: metallb-system
spec: {}
EOF

mkdir -p k8s/traefik
cat > k8s/traefik/values.yaml <<'EOF'
logs:
  general:
    level: INFO
service:
  type: LoadBalancer
  loadBalancerIP: 192.168.88.201
ingressRoute:
  dashboard:
    enabled: true
ports:
  web:
    redirected: true
  websecure:
    tls:
      enabled: true
EOF

mkdir -p k8s/cert-manager
cat > k8s/cert-manager/cm-internal-ca.yaml <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-cluster-issuer
spec:
  selfSigned: {}
EOF

mkdir -p k8s/apps/django-hello
cat > k8s/apps/django-hello/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: django
EOF

cat > k8s/apps/django-hello/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: django-hello
  namespace: django
spec:
  replicas: 1
  selector:
    matchLabels:
      app: django-hello
  template:
    metadata:
      labels:
        app: django-hello
    spec:
      containers:
      - name: app
        image: hashicorp/http-echo:0.2.3
        args:
        - -text=django-hello
        ports:
        - containerPort: 5678
        volumeMounts:
        - name: media
          mountPath: /var/www/media
      volumes:
      - name: media
        persistentVolumeClaim:
          claimName: pvc-django-media
EOF

cat > k8s/apps/django-hello/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: django-hello
  namespace: django
spec:
  type: ClusterIP
  selector:
    app: django-hello
  ports:
  - port: 80
    targetPort: 5678
EOF

cat > k8s/apps/django-hello/certificate.yaml <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: django-cert
  namespace: django
spec:
  secretName: django-tls
  issuerRef:
    name: selfsigned-cluster-issuer
    kind: ClusterIssuer
  dnsNames:
  - django.home.arpa
EOF

cat > k8s/apps/django-hello/ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: django-hello
  namespace: django
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  tls:
  - hosts:
    - django.home.arpa
    secretName: django-tls
  rules:
  - host: django.home.arpa
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: django-hello
            port:
              number: 80
EOF

mkdir -p k8s/apps/minecraft
cat > k8s/apps/minecraft/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: minecraft
EOF

cat > k8s/apps/minecraft/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mc
  namespace: minecraft
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mc
  template:
    metadata:
      labels:
        app: mc
    spec:
      containers:
      - name: mc
        image: itzg/minecraft-server:latest
        env:
        - name: EULA
          value: "TRUE"
        - name: MEMORY
          value: 2G
        - name: TYPE
          value: VANILLA
        ports:
        - containerPort: 25565
          name: mc
        volumeMounts:
        - name: world
          mountPath: /data
      volumes:
      - name: world
        persistentVolumeClaim:
          claimName: pvc-minecraft
EOF

cat > k8s/apps/minecraft/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mc
  namespace: minecraft
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.88.204
  selector:
    app: mc
  ports:
  - name: mc
    port: 25565
    targetPort: 25565
EOF

mkdir -p k8s/apps/nextcloud
cat > k8s/apps/nextcloud/ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nextcloud
  namespace: nextcloud
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  tls:
  - hosts:
    - nextcloud.home.arpa
    secretName: nextcloud-tls
  rules:
  - host: nextcloud.home.arpa
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nextcloud
            port:
              number: 8080
EOF

mkdir -p k8s/addons/traefik
cat > k8s/addons/traefik/release.yaml <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 5m
  chart:
    spec:
      chart: traefik
      version: ">=22.0.0-0"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: traefik
  values:
    service:
      type: LoadBalancer
      loadBalancerIP: 192.168.88.201
    ingressRoute:
      dashboard:
        enabled: true
    ports:
      web:
        redirected: true
      websecure:
        tls:
          enabled: true
EOF

mkdir -p scripts
cat > scripts/minikube-up.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${MINIKUBE_CPUS:=2}"
: "${MINIKUBE_MEMORY_MB:=8192}"
: "${MINIKUBE_DISK_SIZE:=40g}"
minikube start --driver=docker --cpus="${MINIKUBE_CPUS}" --memory="${MINIKUBE_MEMORY_MB}" --disk-size="${MINIKUBE_DISK_SIZE}"
minikube addons enable metrics-server
EOF
chmod +x scripts/minikube-up.sh

if ! grep -q "local-hostpath" k8s/base/kustomization.yaml 2>/dev/null; then
  cat > k8s/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- storageclass.yaml
EOF
fi

if [ -f k8s/storage/nextcloud-hostpath.yaml ]; then
  sed -i 's|path: .*nextcloud|path: /srv/nextcloud|g' k8s/storage/nextcloud-hostpath.yaml || true
fi

if [ -f k8s/storage/postgresql-hostpath.yaml ]; then
  sed -i 's|path: .*postgres|path: /srv/apps/postgres|g' k8s/storage/postgresql-hostpath.yaml || true
fi

if [ -f Makefile ]; then
  if ! grep -q "k8s.storage.apply" Makefile; then
    cat >> Makefile <<'EOF'

k8s.storage.apply:
	kubectl apply -f k8s/base/storageclass.yaml
	kubectl create ns data --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl create ns django --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl create ns minecraft --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl apply -f k8s/storage/postgres-hostpath.yaml
	kubectl apply -f k8s/storage/django-media-hostpath.yaml
	kubectl apply -f k8s/storage/minecraft-hostpath.yaml

k8s.metallb.apply:
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
	kubectl -n metallb-system rollout status deploy/controller --timeout=120s
	kubectl apply -f k8s/addons/metallb/ip-pool.yaml

k8s.traefik.apply:
	kubectl create ns traefik --dry-run=none -o yaml | kubectl apply -f - || true
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	helm upgrade --install traefik traefik/traefik -n traefik -f k8s/traefik/values.yaml

k8s.cert.apply:
	kubectl apply -f k8s/cert-manager/cm-internal-ca.yaml

apps.django.apply:
	kubectl apply -f k8s/apps/django-hello/namespace.yaml
	kubectl apply -f k8s/apps/django-hello/deployment.yaml
	kubectl apply -f k8s/apps/django-hello/service.yaml
	kubectl apply -f k8s/apps/django-hello/certificate.yaml
	kubectl apply -f k8s/apps/django-hello/ingress.yaml

apps.minecraft.apply:
	kubectl apply -f k8s/apps/minecraft/namespace.yaml
	kubectl apply -f k8s/apps/minecraft/deployment.yaml
	kubectl apply -f k8s/apps/minecraft/service.yaml

apps.nextcloud.ingress.apply:
	kubectl apply -f k8s/apps/nextcloud/ingress.yaml

up.phase1_4:
	./scripts/minikube-up.sh
	$(MAKE) k8s.storage.apply
	$(MAKE) k8s.metallb.apply
	$(MAKE) k8s.traefik.apply
	$(MAKE) k8s.cert.apply
	$(MAKE) apps.django.apply
	$(MAKE) apps.minecraft.apply
	$(MAKE) apps.nextcloud.ingress.apply
EOF
  fi
fi

echo "Repo patch applied. Next steps:"
echo "1) source ./.env or export env vars as needed"
echo "2) make up.phase1_4"
echo "3) Create pfSense DNS overrides for traefik.home.arpa, django.home.arpa, nextcloud.home.arpa, minecraft.home.arpa"
echo "4) Test: curl -k https://django.home.arpa, connect Minecraft to 192.168.88.204:25565"

