# AIAE-deploy-to-GCP

Central manual deployment control plane for approved GitHub repositories.

The application repositories stay unchanged. This repo stores the deployment
definitions in `apps/*.yml`, builds the selected app on a GitHub-hosted runner,
then deploys the built release bundle to the target GCE VM over SSH.

## Why this shape

- A deploy is started manually from this repository.
- Workflow inputs select an existing app config, not an arbitrary Git URL.
- Build commands from the app repository run without production SSH secrets.
- The deploy job receives SSH secrets only after a release bundle is built.
- The production server runs only the checked-in deploy scripts from this repo.

This is for approved repositories, not truly untrusted code. A malicious app can
still do damage at runtime if it is allowed onto the shared server.

## Repository layout

```text
.github/workflows/deploy.yml   Manual GitHub Actions entry point
apps/                          Central app deployment definitions
scripts/                       Runner-side checkout/build/package/deploy glue
server/                        Scripts copied to the target GCE VM
server/runtimes/               Runtime adapters
docs/SERVER_SETUP.md           One-time server and GitHub setup
```

## Supported runtimes

- `java-systemd` - deploys a built Spring Boot jar and manages it with systemd.
- `node-pm2` - deploys a built Node/Next-style bundle and manages it with PM2.

## Add an app

Create `apps/<app>.yml`.

Java/Spring example:

```yaml
app: crm-demo
repo: gm-aidigital/crm-demo
default_ref: main
github_environment: prod-crm-demo
subdomain: crm-demo.aidigital.tech
runtime: java-systemd

build:
  commands:
    - cd frontend && npm ci && npm run build
    - cd backend && mvn -B verify package

artifact:
  path: backend/application/target/*.jar

secrets:
  app_env_b64_required: true

server:
  port: auto
  healthcheck: /actuator/health
```

Node/PM2 example:

```yaml
app: aw-control-room
repo: gm-aidigital/aw-control-room
default_ref: main
github_environment: prod-aw-control-room
subdomain: aw-control-room.aidigital.tech
runtime: node-pm2

build:
  commands:
    - npm ci
    - npm run build
    - npm prune --omit=dev

start:
  command: npm run start

artifact:
  path: .
  include_node_modules: true

secrets:
  app_env_b64_required: true

server:
  port: auto
  healthcheck: /
```

## Run a deploy

1. Open GitHub Actions in this repository.
2. Run `Deploy approved app`.
3. Enter:
   - `app`: config name without `.yml`, for example `crm-demo`
   - `ref`: optional branch, tag, or SHA. Empty means `default_ref`.
   - `dry_run`: `true` to validate/build/package without SSH deploy.
4. Approve the app-specific GitHub Environment, for example `prod-crm-demo`.

## Required GitHub secrets

Set this repository secret only if source repositories are private:

```text
SOURCE_REPO_TOKEN=<optional PAT for private source repos>
```

`SOURCE_REPO_TOKEN` is only exposed to the checkout step. It is not present
while app build commands run.

Create one GitHub Environment per app using the value from
`github_environment`. Require manual approval and store these environment
secrets there:

```text
AI_DEPLOY_SSH_HOST
AI_DEPLOY_SSH_USER
AI_DEPLOY_SSH_KEY
AI_DEPLOY_SSH_PORT
AI_DEPLOY_CERTBOT_EMAIL
APP_ENV_B64
```

On macOS:

```bash
base64 -i .env | pbcopy
```

On Linux:

```bash
base64 -w0 .env
```

The deploy job receives SSH credentials and `APP_ENV_B64` only after environment
approval. It decodes `APP_ENV_B64` and writes it to
`~/apps/<app>/shared/.env` on the server.

## Server state

The deploy scripts use these locations on the target VM:

```text
~/.ai-deploy/               deploy scripts, inbox, state
~/apps/<app>/releases/      release directories
~/apps/<app>/current        symlink to active release
~/apps/<app>/shared/.env    app secrets, installed from APP_ENV_B64
```

See `docs/SERVER_SETUP.md` before the first deploy.
