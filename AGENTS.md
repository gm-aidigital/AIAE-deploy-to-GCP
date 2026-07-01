# ai-deploy agent notes

This repository is the central deployment control plane for approved GitHub
repositories. Application repositories do not need deployment files.

Security model:

- Never run build/install commands on the shared production server unless an
  app config explicitly opts into that risk.
- The build job may clone source repositories and execute their build commands,
  but it must not receive SSH deploy secrets.
- The deploy job receives SSH secrets, but it only uploads the already-built
  release bundle and runs the checked-in server deploy scripts.
- Runtime app secrets come from app-specific GitHub Environments as
  `APP_ENV_B64`; never store them in application repositories.
- App definitions live in `apps/*.yml`; do not accept arbitrary repo URLs from
  workflow inputs.
- Keep server changes additive and app-scoped. Always run `nginx -t` before
  reloading nginx.
