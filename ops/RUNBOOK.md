# Karakeep fork — build & deploy runbook

We run a patched Karakeep. The patch lets collaborators with **edit** rights on a
shared list edit content other people created (upstream issue
[#2780](https://github.com/karakeep-app/karakeep/issues/2780)). Everything else
is stock upstream.

The model is a **distro-style patch set**: one small commit that we replay onto
each upstream release, not a long-lived fork that drifts.

## Layout

| Branch | What it is | Rule |
|---|---|---|
| `feat/editor-can-edit-shared-content` | The patch. 5 files, no DB migration. | Keep pristine — this is what the upstream PR gets. Never add ops files here. |
| `strata/deploy` | The patch **plus** `ops/`. What we build. | Rebased onto the patch branch after every upstream sync. |
| `main` | Mirror of upstream. | Never commit here. |

Remotes: `origin` = our fork, `upstream` = `karakeep-app/karakeep`.

## Routine rebuild

```bash
ops/rebuild.sh            # rebase + deps + test + build + smoke, no push
ops/rebuild.sh --push     # ...and push :latest and :<sha> to the registry
```

Then on the VM:

```bash
docker compose pull && docker compose up -d
```

Individual steps: `--only {preflight|rebase|deps|test|build|smoke|push}`.
Build the current checkout without touching git: `--skip-rebase`.
Pin to a release instead of `main`: `--ref v0.34.0`.

### What the script guarantees

- Node 24 enforced (`.nvmrc`); Node 20 fails deep inside corepack otherwise.
- Tests capped at 4 threads and scoped to the two files covering the patch.
  It deliberately never runs bare `pnpm test` — that pulls in
  `packages/e2e_tests`, which starts a full `docker compose` stack.
- Image build runs in a cgroup-capped buildx builder (8 GB, CPUs 0–7).
  Unconstrained runs have taken this host to load 62.
- Registry auth is checked **before** uploading ~2 GB.
- Smoke test asserts the container goes `healthy` *and* that DB migrations ran.

### What it does not do

- Resolve rebase conflicts. It stops and tells you where.
- Deploy to the VM. That stays a human action.
- Force-push anything.

## Image tags

| Tag | Use |
|---|---|
| `reg.strataops.com/karakeep/karakeep:latest` | What compose pins. Moves every build. |
| `reg.strataops.com/karakeep/karakeep:<sha>` | Immutable. **This is your rollback target.** |

`latest` is only safe *because* the SHA tag exists. Never delete SHA tags.

Version string is stamped into the image as `SERVER_VERSION`, e.g.
`Karakeep Shaunly (2351f157)`, visible in the workers' startup log:

```bash
docker logs <container> | grep "Workers version"
```

---

# When things break

## Rebase conflicts

Expected whenever upstream refactors `updateBookmark`. The patch touches:

- `packages/trpc/models/bookmarks.ts` — the `isAllowedToEditBookmark` /
  `ensureEditable` / `ensureOwnerOnlyFields` helpers
- `packages/trpc/routers/bookmarks.ts` — `ensureBookmarkEditAccess` middleware
  and its use on `updateBookmark` / `updateBookmarkText`
- `packages/trpc/routers/sharedLists.test.ts` — the permission tests
- two `apps/web` components

```bash
git status
# edit the conflicts, then:
git add -A && git rebase --continue
ops/rebuild.sh --skip-rebase        # re-verify
```

Give up and go back: `git rebase --abort`.

**Real example:** replaying onto `v0.33.2` conflicted twice because upstream had
converted `ctx.db.transaction(async (tx) => ...)` to a sync callback. Both were
one-line fixes. Keep upstream's form, re-apply our added lines on top.

### The two things to re-check by hand after any conflict resolution

1. `ensureBookmarkEditAccess` is still the middleware on `updateBookmark` — not
   silently reverted to `ensureBookmarkOwnership`.
2. Both `UPDATE bookmarks ... WHERE userId = ...` clauses still scope to the
   **bookmark's owner** (`bookmarkOwnerId`), not `ctx.user.id`. If this reverts,
   authorization passes but the write silently updates zero rows — an editor's
   change appears to succeed and does nothing. The tests catch this.

## Tests fail

Do not deploy. Log: `ops/logs/test.log`.

If failures are in `Bookmark Editing Permissions`, upstream likely changed the
authorization model. Read their diff before "fixing" our tests — the tests may
be correctly reporting that the patch no longer does what it claims.

## Build fails

Log: `ops/logs/build.log`.

- **Out of disk** — `docker builder prune`. The build wants ~15 GB headroom.
- **Builder wedged** — `docker buildx rm karakeep-ltd` and re-run; the script
  recreates it with the caps.
- **Host overloaded** — lower the caps:
  `KARAKEEP_BUILDER_CPUS=0-3 KARAKEEP_BUILDER_MEM=4g ops/rebuild.sh`

## Push fails with 401

The registry credential has expired. It is *not* a namespace permission problem
— confirm by checking read access:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://reg.strataops.com/v2/
```

401 there means auth, full stop.

```bash
docker login reg.strataops.com
ops/rebuild.sh --only push --push
```

## Segfaults / orphaned vitest workers

`better-sqlite3` can segfault at worker teardown on a version/Node mismatch,
leaving workers pinning a core each. Symptom: `Assertion failed: (env) != nullptr`
then `ERR_IPC_CHANNEL_CLOSED`.

```bash
pgrep -f 'node \(vitest'      # check
pkill -f 'node \(vitest'      # clean up
```

The script does this automatically after its test step. If it happens right
after switching branches, the native binding is stale for the current lockfile:

```bash
rm -rf node_modules && pnpm install --frozen-lockfile
```

**Known:** upstream `v0.33.2` pins `better-sqlite3 ^11`, which segfaults under
Node 24. `main` bumped it to `^13`. Building from a tag at or before `v0.33.2`
means the test step cannot run — that is a property of that release, not of our
patch. Prefer `main`-based builds, or skip verification knowingly.

---

# Deploying to the VM

**Back up first. Migrations are one-way.**

```bash
docker compose down
docker run --rm -v <stack>_data:/data -v "$PWD:/backup" alpine \
  tar czf /backup/karakeep-data-$(date +%F).tar.gz -C /data .
docker compose pull && docker compose up -d
```

Check the deployed version:

```bash
docker exec <container> cat /app/apps/web/package.json | grep '"version"'
```

## Rollback

If the new image misbehaves **and no new migration ran**, roll back by pinning
the previous SHA tag:

```yaml
image: reg.strataops.com/karakeep/karakeep:<previous-sha>
```

```bash
docker compose up -d
```

If a **new migration did run**, the image alone will not save you — restore the
data backup as well. The script warns at rebase time when upstream has added
migrations; that warning is the moment to take a backup seriously.

## Verifying the patch actually works

As a user with **editor** (not viewer) rights on a shared list, open a bookmark
created by someone else and edit its title. Before the patch, the Edit action
was not in the menu at all.

Expected to remain blocked, by design:

- viewers editing anything
- editors changing another user's **favourite, archive, personal note, or
  created-at** — these are per-owner state
- editors **deleting** another user's bookmark
- editors editing **tags** on another user's bookmark — `bookmarkTags` is scoped
  by `userId`, so this needs its own upstream change
  ([#2247](https://github.com/karakeep-app/karakeep/issues/2247))

---

# Upstream PR status

The patch is **not yet submitted**. Plan: run it here first, then open the PR
against `karakeep-app/karakeep` and comment on #2780.

Note #2780 is `status/untriaged`. Per upstream `CONTRIBUTING.md`, untriaged
feature requests can be iceboxed — worth asking for triage before investing more.

Related, deliberately **not** in this patch:

- [#2877](https://github.com/karakeep-app/karakeep/issues/2877) — inherit
  collaborators into sublists. Approved upstream and informally claimed by
  another contributor. Much larger: needs ancestor walks in three resolvers, a
  privacy decision about exposing `parentId` to non-owners, and a migration for
  `bookmarksInLists.listMembershipId`, whose FK cascade assumes a membership row
  that inherited access would not have.
- [#2247](https://github.com/karakeep-app/karakeep/issues/2247) — collaborator
  tags.
