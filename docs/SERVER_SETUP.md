# Server setup

Target server prerequisites assumed by these scripts:

```text
OS: Debian 12
nginx: system-managed, sudo required
certbot: installed with nginx plugin
PM2: installed and boot-resurrect enabled
Docker: installed, sudo required
```

## One-time prerequisites

Create the deploy directories:

```bash
ssh <ssh-alias-or-host> 'mkdir -p ~/.ai-deploy/{bin,incoming,state} ~/apps'
```

For Java apps, install Java 21 if it is not present:

```bash
ssh <ssh-alias-or-host> 'java -version || sudo apt-get update && sudo apt-get install -y openjdk-21-jre-headless'
```

For Node apps, PM2 and Node 20 must already be installed. The existing runbook
says they are present.

## GitHub environments

Create one GitHub Environment per app and require manual approval:

```text
prod-crm-demo
prod-aw-control-room
prod-client-portal
```

Each `apps/<app>.yml` must point at the matching environment:

```yaml
github_environment: prod-crm-demo
```

Store this repository secret only if source repositories are private:

```text
SOURCE_REPO_TOKEN
```

`SOURCE_REPO_TOKEN` is optional for public source repositories. For private
repositories, use a least-privilege fine-grained PAT with read-only access to
the approved source repos.

Store deploy and app runtime secrets in the app-specific GitHub Environment:

```text
AI_DEPLOY_SSH_HOST
AI_DEPLOY_SSH_USER
AI_DEPLOY_SSH_KEY
AI_DEPLOY_SSH_PORT
AI_DEPLOY_CERTBOT_EMAIL
APP_ENV_B64
```

`APP_ENV_B64` is a base64-encoded `.env` file. On macOS:

```bash
base64 -i .env | pbcopy
```

On Linux:

```bash
base64 -w0 .env
```

The deploy workflow decodes the secret on the deploy runner and writes it to:

```text
~/apps/<app>/shared/.env
```

For Java/Spring apps, include values such as:

```text
SPRING_PROFILES_ACTIVE=prod
DATABASE_URL=...
CLERK_SECRET_KEY=...
AUTH_JWKS_URI=...
```

For Node apps, include the app-specific environment variables expected by the
start command.

If an app has no runtime secrets, set this in `apps/<app>.yml`:

```yaml
secrets:
  app_env_b64_required: false
```

## Basic auth

If an app config enables `server.basic_auth: true`, create the htpasswd file
before deploy:

```bash
ssh <ssh-alias-or-host> 'PW=$(openssl rand -base64 12); echo "PASSWORD=$PW"; \
  echo "myuser:$(openssl passwd -apr1 "$PW")" | sudo tee /etc/nginx/.htpasswd-<app> >/dev/null'
```

The deploy will fail fast if basic auth is enabled but the htpasswd file is
missing.

## Runtime notes

`java-systemd` writes `/etc/systemd/system/<app>.service`.

`node-pm2` starts a PM2 process named `<app>`. By default it expects the release
bundle to include production `node_modules`, built on the GitHub runner. This
avoids running install scripts from the source repository on the shared server.
