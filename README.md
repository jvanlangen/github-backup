# GitHub Backup Container

Local GitHub repository backup container using `git clone --mirror`.

The container is a **one-shot job**:

```text
start container -> run backup -> exit
```

It does not run cron internally.

---

## 1. Build the image

From the project root:

```bash
docker compose build
```

Expected project layout:

```text
/
├── docker-compose.yml
├── README.md
├── example.env
└── image/
    ├── dockerfile
    ├── backup-github.sh
    └── .dockerignore
```

---

## 2. Create your `.env`

Copy the example file:

```bash
cp example.env .env
```

On Windows PowerShell:

```powershell
Copy-Item example.env .env
```

Edit `.env` and fill in your own values:

```env
GITHUB_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxx
GITHUB_OWNERS=my-company,my-user
HOST_BACKUP_PATH=C:/Dev/GithubBackups

DAILY_RETENTION_DAYS=14
ENABLE_DAILY=true
ENABLE_WEEKLY=true
ENABLE_MONTHLY=true
TZ=Europe/Amsterdam
```

Do **not** commit `.env`.

Commit `example.env` instead.

---

## 3. Run the backup manually

```bash
docker compose run --rm github-backup
```

This will:

```text
start container -> backup repositories -> create snapshots -> exit
```

Do not run it as a daemon:

```bash
docker compose up -d
```

That is not needed.

---

## 4. Create a Linux cronjob

Open the host crontab:

```bash
crontab -e
```

Example: run every night at 02:00:

```cron
0 2 * * * cd /opt/github-backup && docker compose run --rm github-backup >> ./backup.log 2>&1
```

If cron cannot find Docker, check the Docker path:

```bash
which docker
```

Then use the full path:

```cron
0 2 * * * cd /opt/github-backup && /usr/bin/docker compose run --rm github-backup >> ./backup.log 2>&1
```

`/opt/github-backup` should contain:

```text
docker-compose.yml
.env
example.env
README.md
image/
```

---

## docker-compose.yml

```yaml
services:
  github-backup:
    build:
      context: ./image
      dockerfile: dockerfile
    container_name: github-backup
    environment:
      GITHUB_TOKEN: "${GITHUB_TOKEN}"
      GITHUB_OWNERS: "${GITHUB_OWNERS}"
      DAILY_RETENTION_DAYS: "${DAILY_RETENTION_DAYS}"
      ENABLE_DAILY: "${ENABLE_DAILY}"
      ENABLE_WEEKLY: "${ENABLE_WEEKLY}"
      ENABLE_MONTHLY: "${ENABLE_MONTHLY}"
      TZ: "${TZ:-Europe/Amsterdam}"
    volumes:
      - "${HOST_BACKUP_PATH}:/backups"
    restart: "no"
```

---

## Backup output

The container writes to the path configured by `HOST_BACKUP_PATH`.

Example:

```env
HOST_BACKUP_PATH=C:/Dev/GithubBackups
```

Output:

```text
C:/Dev/GithubBackups/
├── my-company/
│   ├── current/
│   ├── daily/
│   ├── weekly/
│   └── monthly/
└── my-user/
    ├── current/
    ├── daily/
    ├── weekly/
    └── monthly/
```

The layout is:

```text
<host-backup-path>/<github-owner>/current
<host-backup-path>/<github-owner>/daily
<host-backup-path>/<github-owner>/weekly
<host-backup-path>/<github-owner>/monthly
```

---

## GitHub token permissions

For private repositories, use a GitHub token with read access to the repositories.

For a fine-grained token, use at least:

```text
Repository access: selected repositories or all repositories
Contents: Read-only
Metadata: Read-only
```

---

## Restore test

Example:

```bash
git clone C:/Dev/GithubBackups/my-user/current/repo-c.git C:/Temp/repo-c-restore-test
```

On Linux:

```bash
git clone /data/github-backups/my-user/current/repo-c.git /tmp/repo-c-restore-test
```

Then inspect:

```bash
cd /tmp/repo-c-restore-test
git branch -a
git tag
git log --oneline --decorate --graph --all
```
