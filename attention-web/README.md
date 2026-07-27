# Cherry Attention Lab

A small private Astro dashboard for reviewing Cherry attention-study exports.
Cloudflare Workers serves the static interface and authenticated API; D1 stores
the observation payloads and indexed metadata.

Production: <https://cherry-attention-lab.patrick-arminio.workers.dev>

## Local development

```bash
npm install
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply cherry-attention-lab --local
npm run dev
```

Open `http://localhost:8787` and enter the token from `.dev.vars`. Export a
bundle from the Cherry repository, then select that whole directory in the
uploader:

```bash
../Scripts/attention-study-data export --output ~/Desktop/cherry-attention-week-1
```

The dashboard token is kept in tab-scoped `sessionStorage`; it is not embedded
in the built site. API routes require `Authorization: Bearer <token>`. Reviews
also retain whether they came from a manual decision or an assistant audit;
editing any decision in the dashboard marks the replacement as manual.

## Deploy

Create the D1 database, replace the placeholder `database_id` in
`wrangler.jsonc`, apply the migration, and deploy with a strong dashboard
token:

```bash
npx wrangler login
npx wrangler d1 create cherry-attention-lab
npx wrangler d1 migrations apply cherry-attention-lab --remote
npm run build
npx wrangler deploy --secrets-file /path/to/private.env
```

The secrets file contains:

```dotenv
DASHBOARD_TOKEN="replace-with-a-long-random-value"
```

Do not commit that file. The uploader validates observation schemas and UUIDs,
then de-duplicates by observation ID. It does not reproduce the export tool's
SHA-256 manifest verification, so use `attention-study-data import` when
checksum verification is required.

## Checks

```bash
npm run check
npm test
npx wrangler deploy --dry-run
npm audit --audit-level=high
```
