# privatespace-app

Build runner and website for **Private Space** (`com.privatespace.app`), an Android app that hides apps and runs dual apps inside Android's own work profile.

This repository holds workflows and the public website only. A build run checks out the private app repository with a read-only deploy key, analyses and tests it, builds the signed release APKs and the Play bundle, creates a real work profile on an Android emulator and drives the app through it, and uploads everything it made as **one sealed file** (AES-256, key held by the owner). No source, build or log leaves the runner readable.

```sh
gh workflow run build.yml -R Mulhimfy/privatespace-app -f ref=main -f smoke=true
```

Website (GitHub Pages, `docs/`): https://mulhimfy.github.io/privatespace-app/ (privacy policy: `privacy.html`).
