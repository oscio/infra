# Forgejo Actions Workflows — Example Templates

These example workflows demonstrate the **manual-push → build → deploy**
loop that runs end-to-end inside the dev cluster without any agent
involvement. Once you can `git push` and see a new image in Harbor +
Argo CD deploying it, the platform is ready for Hermes/DevPod to drive
the loop on its behalf.

## Assumptions

- `forgejo_enabled = true`, `forgejo_runner_enabled = true`
- `harbor_enabled = true` with a robot account in the `library` project
- Robot-account credentials plumbed into `forgejo_runner_registry_*` tfvars
- Argo CD dev instance watches `https://git.dev.openschema.io/*`
- Your repo is at `git.dev.openschema.io/<user>/<project>`

## Build & push image on commit

File: `.forgejo/workflows/build-push.yml`

```yaml
name: Build & Push

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        with:
          # Point buildx at the BuildKit sidecar (injected by our runner module).
          driver: remote
          endpoint: tcp://127.0.0.1:1234

      - name: Extract image tag
        id: tag
        run: |
          # Use short SHA for branch builds, PR number for PR builds.
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            echo "tag=pr-${{ github.event.pull_request.number }}" >> $GITHUB_OUTPUT
          else
            echo "tag=$(echo ${{ github.sha }} | cut -c1-7)" >> $GITHUB_OUTPUT
          fi

      - name: Build & push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            registry.dev.openschema.io/library/${{ github.event.repository.name }}:${{ steps.tag.outputs.tag }}
            registry.dev.openschema.io/library/${{ github.event.repository.name }}:latest
          # BuildKit cache in the runner's PVC survives across runs.
          cache-from: type=registry,ref=registry.dev.openschema.io/library/${{ github.event.repository.name }}:buildcache
          cache-to:   type=registry,ref=registry.dev.openschema.io/library/${{ github.event.repository.name }}:buildcache,mode=max
```

## Update the deployment manifest

File: `.forgejo/workflows/update-manifest.yml`

When the build succeeds on `main`, bump the image tag in the repo's
`deploy/dev/` manifests and push back. Argo CD will see the change and
sync.

```yaml
name: Update Manifest

on:
  workflow_run:
    workflows: ["Build & Push"]
    types: [completed]
    branches: [main]

jobs:
  update:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
          # Use a token with push rights (runner's default token does not push).
          token: ${{ secrets.MANIFEST_BOT_TOKEN }}

      - name: Bump image tag
        run: |
          TAG=$(echo ${{ github.event.workflow_run.head_sha }} | cut -c1-7)
          IMAGE="registry.dev.openschema.io/library/${{ github.event.repository.name }}:${TAG}"
          # Assumes kustomize overlay at deploy/dev/kustomization.yaml
          cd deploy/dev
          kustomize edit set image app=${IMAGE}

      - name: Commit & push
        run: |
          git config user.name  "forgejo-runner"
          git config user.email "runner@dev.openschema.io"
          git add deploy/dev/kustomization.yaml
          git commit -m "chore(dev): bump image to $(echo ${{ github.event.workflow_run.head_sha }} | cut -c1-7)"
          git push
```

## The `MANIFEST_BOT_TOKEN` secret

Go to your repo → Settings → Actions → Secrets → Add:

- Name: `MANIFEST_BOT_TOKEN`
- Value: a Forgejo PAT with `write:repository` for this repo

(Later: replace with a short-lived token minted per-run via Keycloak
token exchange — future work.)

## Argo CD Application manifest

In the cluster, register the Argo CD Application once:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-dev
  namespace: platform-argocd
spec:
  project: default
  source:
    repoURL: https://git.dev.openschema.io/shane/myapp
    targetRevision: main
    path: deploy/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: apps-myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Verifying end-to-end

1. Push a commit to `main` in Forgejo.
2. Check Forgejo → Actions tab: `Build & Push` should run.
3. In Harbor (`registry.dev.openschema.io`), browse the `library` project
   → your repo name → verify the new tag exists.
4. Watch `Update Manifest` workflow fire and commit a manifest bump.
5. Argo CD UI (`cd.dev.openschema.io`) should show the Application
   transitioning to OutOfSync, then Syncing, then Healthy.
6. `kubectl get pods -n apps-myapp` shows the new pod running the new
   image.

Once all six steps tick without manual intervention, the CI/CD layer is
ready. At that point Hermes+DevPod just needs to do step 1 (push a
commit) for an agent-driven flow.
