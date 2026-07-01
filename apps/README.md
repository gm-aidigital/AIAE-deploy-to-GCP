# App configs

Each deployable application gets one central config:

```text
apps/<app>.yml
```

The workflow input `app=<app>` loads that file. Application repositories do not
need deployment files.

Keep configs explicit. Prefer `build_profile` only after there is a stable
profile implemented in this repo.

Every app config must set `github_environment`. Create a matching GitHub
Environment in the `ai-deploy` repository and store the app's base64-encoded
runtime `.env` as `APP_ENV_B64`.
