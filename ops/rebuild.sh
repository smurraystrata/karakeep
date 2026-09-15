#!/usr/bin/env bash
#
# Rebase the Strata patch onto upstream Karakeep, verify it, build an image,
# smoke-test it, and push it to the registry.
#
# Usage:
#   ops/rebuild.sh                 # rebase + test + build + smoke (no push)
#   ops/rebuild.sh --push          # ...and push to the registry
#   ops/rebuild.sh --skip-rebase   # build the current checkout as-is
#   ops/rebuild.sh --only build    # run a single step
#   ops/rebuild.sh --ref v0.34.0   # rebase onto a tag instead of upstream/main
#
# Every step is fail-loud. Nothing here resolves a merge conflict for you and
# nothing force-pushes.

set -euo pipefail

# ---------------------------------------------------------------- configuration

# Site-specific settings (registry host, brand label) live in ops/rebuild.env,
# which is gitignored. This fork is public -- keep deployment details out of it.
# Copy ops/rebuild.env.example to ops/rebuild.env to get started.
_ENV_FILE="${KARAKEEP_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rebuild.env}"
# shellcheck source=/dev/null
[[ -f "$_ENV_FILE" ]] && source "$_ENV_FILE"

# No default: an unset registry must fail loudly at push, not silently publish
# somewhere unintended.
REGISTRY="${KARAKEEP_REGISTRY:-}"
IMAGE_REPO="${KARAKEEP_IMAGE_REPO:-karakeep/karakeep}"
LOCAL_TAG="${KARAKEEP_LOCAL_TAG:-karakeep-fork:editor-edit}"
BRAND="${KARAKEEP_BRAND:-Karakeep}"

PATCH_BRANCH="${KARAKEEP_PATCH_BRANCH:-feat/editor-can-edit-shared-content}"
OPS_BRANCH="${KARAKEEP_OPS_BRANCH:-strata/deploy}"
UPSTREAM_REF="${KARAKEEP_UPSTREAM_REF:-upstream/main}"

# Resource caps. The unconstrained test suite once took the dev host to load 62;
# the build is heavier still. These are cgroup limits, not suggestions.
BUILDER_NAME="${KARAKEEP_BUILDER:-karakeep-ltd}"
BUILDER_MEM="${KARAKEEP_BUILDER_MEM:-8g}"
BUILDER_CPUS="${KARAKEEP_BUILDER_CPUS:-0-7}"
TEST_THREADS="${KARAKEEP_TEST_THREADS:-4}"

# Test files that actually cover the patch. Deliberately NOT `pnpm test`, which
# pulls in packages/e2e_tests and starts a full docker compose stack.
TEST_FILES=(
  "routers/sharedLists.test.ts"
  "routers/bookmarks.test.ts"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${KARAKEEP_LOG_DIR:-$REPO_ROOT/ops/logs}"

DO_PUSH=0
SKIP_REBASE=0
ONLY_STEP=""

# ---------------------------------------------------------------------- helpers

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$c_bld" "$*" "$c_off"; }
ok()   { printf '%s  ok%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s  !!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '\n%sFAILED:%s %s\n\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

run_step() { [[ -z "$ONLY_STEP" || "$ONLY_STEP" == "$1" ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)        DO_PUSH=1; shift ;;
    --skip-rebase) SKIP_REBASE=1; shift ;;
    --only)        ONLY_STEP="${2:?--only needs a step name}"; shift 2 ;;
    --ref)         UPSTREAM_REF="${2:?--ref needs a git ref}"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

mkdir -p "$LOG_DIR"
cd "$REPO_ROOT"

# Resolve the toolchain for EVERY step, not just preflight -- otherwise
# `--only test` silently runs against the system Node and dies inside pnpm
# with ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING.
want_node="$(tr -d '[:space:]' < .nvmrc 2>/dev/null || echo 24)"
if [[ -n "${KARAKEEP_NODE_BIN:-}" ]]; then
  export PATH="$KARAKEEP_NODE_BIN:$PATH"
elif [[ -d "$HOME/.local/node${want_node}/bin" ]]; then
  export PATH="$HOME/.local/node${want_node}/bin:$PATH"
fi

# Assert the Node version globally. Node 20 fails deep inside corepack with a
# confusing ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING, so fail here with a message
# that says what to do.
have_node="$(node --version 2>/dev/null | sed 's/^v//;s/\..*//' || echo none)"
[[ "$have_node" == "$want_node" ]] || die \
"Node $want_node required (.nvmrc), found: ${have_node}.
  Install it side-by-side and re-run, e.g.:
    curl -fsSL https://nodejs.org/dist/latest-v${want_node}.x/node-v${want_node}.x.y-linux-x64.tar.xz \\
      | tar -xJ -C \$HOME/.local/node${want_node} --strip-components=1
  or point at an existing install: KARAKEEP_NODE_BIN=/path/to/node/bin ops/rebuild.sh"

command -v pnpm >/dev/null || die \
  "pnpm not found (try: corepack enable --install-directory \$HOME/.local/node${want_node}/bin)"

# ------------------------------------------------------------------- preflight

if run_step preflight; then
  step "Preflight"

  command -v docker >/dev/null || die "docker not found"
  command -v git    >/dev/null || die "git not found"
  ok "node $(node --version)"
  ok "pnpm $(pnpm --version)"

  # A failed build that fills the disk is worse than one that refuses to start.
  avail_gb="$(df -BG --output=avail "$REPO_ROOT" | tail -1 | tr -dc '0-9')"
  (( avail_gb >= 15 )) || die "only ${avail_gb}G free; the image build needs ~15G headroom.
  Recover space with: docker builder prune"
  ok "${avail_gb}G disk free"
fi

# ---------------------------------------------------------------------- rebase

if run_step rebase && [[ $SKIP_REBASE -eq 0 ]]; then
  step "Rebase patch onto $UPSTREAM_REF"

  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || die "working tree is dirty. Commit or stash before rebasing."

  git remote get-url upstream >/dev/null 2>&1 \
    || die "no 'upstream' remote. Add it:
  git remote add upstream https://github.com/karakeep-app/karakeep.git"

  git fetch --tags upstream
  ok "fetched upstream"

  base_before="$(git rev-parse "$UPSTREAM_REF")"
  echo "    upstream is at ${base_before:0:8}"

  # Warn loudly about the one thing that genuinely breaks a deploy: new
  # migrations. They are one-way; you cannot roll the image back afterwards.
  merge_base="$(git merge-base HEAD "$UPSTREAM_REF")"
  new_migrations="$(git diff --name-status "$merge_base" "$UPSTREAM_REF" -- packages/db/drizzle/ \
                    | grep -cE '^A' || true)"
  if (( new_migrations > 0 )); then
    warn "$new_migrations NEW DB MIGRATION(S) since your current base."
    warn "Migrations are one-way: once applied you cannot roll back to the old image."
    warn "Back up the data volume before deploying, and read ops/RUNBOOK.md first."
    git diff --name-status "$merge_base" "$UPSTREAM_REF" -- packages/db/drizzle/ | grep -E '^A' || true
  else
    ok "no new DB migrations since current base"
  fi

  git checkout "$PATCH_BRANCH"
  if ! git rebase "$UPSTREAM_REF"; then
    die "rebase hit a conflict. This is expected when upstream refactors the
  files the patch touches. Resolve it by hand:

    git status                 # see the conflicts
    # ...edit, then:
    git add -A && git rebase --continue

  Or bail out entirely with:  git rebase --abort

  The patch touches: packages/trpc/models/bookmarks.ts,
  packages/trpc/routers/bookmarks.ts, and two apps/web components.
  Re-run this script when the rebase is done."
  fi
  ok "patch rebased onto $UPSTREAM_REF"

  # Carry the ops tooling forward on top of the rebased patch.
  git checkout "$OPS_BRANCH"
  git rebase "$PATCH_BRANCH" \
    || die "rebasing $OPS_BRANCH onto $PATCH_BRANCH conflicted; resolve and re-run."
  ok "$OPS_BRANCH rebased onto patch"
fi

PATCH_SHA="$(git rev-parse --short "$PATCH_BRANCH")"

# The image tag must name the commit that was actually BUILT, not the patch
# branch. Those differ whenever strata/deploy carries anything the patch branch
# does not -- which is always, since ops/ lives here. Tagging by PATCH_SHA
# republishes an existing immutable tag with different content and destroys the
# rollback point it names.
BUILD_SHA="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  warn "working tree is dirty; the image will contain uncommitted changes that
      commit $BUILD_SHA does not, so the tag will not reproduce from git"
fi

# ------------------------------------------------------------------------ deps

if run_step deps; then
  step "Install dependencies"
  # A lockfile change across refs leaves stale native bindings (better-sqlite3),
  # which surfaces as a segfault mid-test rather than an install error.
  pnpm install --frozen-lockfile 2>&1 | tee "$LOG_DIR/install.log" | tail -3
  ok "dependencies installed"
fi

# ----------------------------------------------------------------------- tests

if run_step test; then
  step "Verify (capped at ${TEST_THREADS} threads)"
  pushd packages/trpc >/dev/null
  if ! pnpm vitest run "${TEST_FILES[@]}" \
        --pool=threads \
        --poolOptions.threads.maxThreads="$TEST_THREADS" \
        2>&1 | tee "$LOG_DIR/test.log" | tail -12; then
    popd >/dev/null
    die "tests failed. Full log: $LOG_DIR/test.log
  Do NOT deploy this build. If the failure is in permission tests, upstream
  probably changed the authorization model -- see ops/RUNBOOK.md."
  fi
  popd >/dev/null

  # vitest workers can survive a segfault and pin a core each; clean up.
  if pgrep -f 'node \(vitest' >/dev/null 2>&1; then
    warn "orphaned vitest workers found; killing them"
    pkill -f 'node \(vitest' || true
  fi
  ok "tests passed"
fi

# ----------------------------------------------------------------------- build

if run_step build; then
  step "Build image (capped: ${BUILDER_MEM} RAM, CPUs ${BUILDER_CPUS})"

  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER_NAME" --driver docker-container \
      --driver-opt "memory=$BUILDER_MEM" \
      --driver-opt "cpuset-cpus=$BUILDER_CPUS" \
      --bootstrap >/dev/null
    ok "created capped builder $BUILDER_NAME"
  else
    ok "reusing builder $BUILDER_NAME"
  fi

  registry_tags=()
  if [[ -n "$REGISTRY" ]]; then
    registry_tags=(-t "$REGISTRY/$IMAGE_REPO:latest"
                   -t "$REGISTRY/$IMAGE_REPO:$BUILD_SHA")
  fi

  version_label="${BRAND} (${BUILD_SHA})"
  docker buildx build --builder "$BUILDER_NAME" \
    -f docker/Dockerfile --target aio \
    --build-arg SERVER_VERSION="$version_label" \
    -t "$LOCAL_TAG" \
    "${registry_tags[@]}" \
    --load . 2>&1 | tee "$LOG_DIR/build.log" | tail -5

  docker image inspect "$LOCAL_TAG" >/dev/null 2>&1 \
    || die "build reported success but image is missing. Log: $LOG_DIR/build.log"
  ok "built $LOCAL_TAG as '$version_label'"
fi

# ------------------------------------------------------------------ smoke test

if run_step smoke; then
  step "Smoke test"
  name="kk-smoke-$$"
  vol="${name}-data"
  cleanup_smoke() { docker rm -f "$name" >/dev/null 2>&1 || true
                    docker volume rm "$vol" >/dev/null 2>&1 || true; }
  trap cleanup_smoke EXIT

  docker run -d --name "$name" --memory=2g --cpus=2 \
    -e DATA_DIR=/data \
    -e NEXTAUTH_SECRET=smoketest \
    -e NEXTAUTH_URL=http://localhost:3000 \
    -v "$vol":/data -P "$LOCAL_TAG" >/dev/null

  health=""
  for _ in $(seq 1 30); do
    health="$(docker inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || echo gone)"
    [[ "$health" == healthy || "$health" == unhealthy || "$health" == gone ]] && break
    sleep 5
  done
  [[ "$health" == healthy ]] || {
    docker logs "$name" 2>&1 | tail -30 > "$LOG_DIR/smoke.log"
    die "container did not become healthy (status: $health). Log: $LOG_DIR/smoke.log"
  }

  # Save the log BEFORE dying: the EXIT trap removes the container, so a die
  # message telling you to run `docker logs` is a message about a container that
  # no longer exists. Every failure path here leaves evidence on disk.
  docker logs "$name" > "$LOG_DIR/smoke.log" 2>&1

  grep -q "init-db-migration successfully started" "$LOG_DIR/smoke.log" \
    || die "DB migrations did not complete. Do NOT deploy. Log: $LOG_DIR/smoke.log"

  grep -F "$BUILD_SHA" "$LOG_DIR/smoke.log" >/dev/null \
    || warn "version string '$BUILD_SHA' not seen in logs; check SERVER_VERSION"

  cleanup_smoke; trap - EXIT
  ok "healthy, migrations ran, version stamped"
fi

# ------------------------------------------------------------------------ push

if run_step push && [[ $DO_PUSH -eq 1 ]]; then
  [[ -n "$REGISTRY" ]] || die "no registry configured, so there is nothing to
  push to. Set KARAKEEP_REGISTRY in ops/rebuild.env (see ops/rebuild.env.example).
  This fork is public -- the host deliberately has no default in the repo."

  step "Push to $REGISTRY"

  # Check auth before uploading 2GB and failing at the end.
  # NB: /v2/ answers an *anonymous* probe with 401 by design -- that is the auth
  # challenge, not a failure. Send the credentials docker stored at login.
  auth="$(python3 -c "
import json,os,sys
try:
    d=json.load(open(os.path.expanduser('~/.docker/config.json')))
    sys.stdout.write(d['auths']['$REGISTRY'].get('auth',''))
except Exception:
    pass
" 2>/dev/null)"
  if [[ -z "$auth" ]]; then
    die "no stored credentials for $REGISTRY. Log in first:

    docker login $REGISTRY

  Then re-run:  ops/rebuild.sh --only push --push"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Basic $auth" "https://$REGISTRY/v2/" || echo 000)"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    die "registry auth is stale (HTTP $code from /v2/). Log in first:

    docker login $REGISTRY

  Then re-run:  ops/rebuild.sh --only push --push"
  elif [[ "$code" == "000" ]]; then
    die "cannot reach https://$REGISTRY/v2/ -- check DNS/VPN."
  fi
  ok "registry reachable (HTTP $code)"

  for tag in latest "$BUILD_SHA"; do
    docker push "$REGISTRY/$IMAGE_REPO:$tag" 2>&1 | tail -2 \
      || die "push of :$tag failed. See ops/RUNBOOK.md."
    ok "pushed $REGISTRY/$IMAGE_REPO:$tag"
  done

  printf '\n%sDeploy on the VM:%s\n' "$c_bld" "$c_off"
  printf '  docker compose pull && docker compose up -d\n'
  printf '  Roll back with: %s/%s:%s\n' "$REGISTRY" "$IMAGE_REPO" "$BUILD_SHA"
elif run_step push; then
  step "Push skipped"
  echo "    re-run with --push to publish ${REGISTRY:-<registry>}/$IMAGE_REPO:{latest,$BUILD_SHA}"
fi

printf '\n%sDone.%s  patch=%s  build=%s  image=%s\n' \
  "$c_grn" "$c_off" "$PATCH_SHA" "$BUILD_SHA" "$LOCAL_TAG"
