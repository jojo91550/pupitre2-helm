# pupitre2-helm

Helm chart for [pupitre2](https://github.com/jojo91550/pupitre2). It deploys three things:

- one API, `pupitre-api` (Go);
- the frontend, `pupitre-front`: nginx serving the learner app and the admin app;
- an optional bundled PostgreSQL.

The chart is adapted from [`genesary/pupitre-helm`](https://github.com/genesary/pupitre-helm)
at `48e9ecb`. That chart deploys the three services of `genesary/pupitre`: user-service,
course-service and checker-service. pupitre2 merged them into one API with the same routes,
tables and rules, so this chart deploys one API where the reference deploys three. See pupitre2's
`docs/specs/108-backend-operations-and-testing.md`.

```
.
├── Chart.yaml
├── values.yaml
├── templates/        # api/, frontend/, postgresql/, routing, release Secret
└── tests/            # helm-unittest specs
```

## Install

```bash
helm install pupitre oci://ghcr.io/jojo91550/charts/pupitre --version <version>
```

Or from source:

```bash
helm install pupitre . -f my-values.yaml
```

The images default to the chart's `appVersion`, which is a release of pupitre2. They are
`ghcr.io/jojo91550/pupitre-api` and `ghcr.io/jojo91550/pupitre-front`. Pin a version tag,
never `latest`.

`values.yaml` lists every setting: secrets, images, ingress, resources, uploads and SSO.

### What to set

| Value | Why |
| --- | --- |
| `ingress.host` (and `ingress.tls`) | The public URL. The CORS origin and the OAuth redirect base are built from it |
| `jwtSecret` or `jwtExistingSecret` | Optional. When empty, a 64-character secret is generated and kept across upgrades. An explicit secret must be at least 32 characters: the API refuses shorter ones and the reference chart's placeholder |
| `database.*` / `postgresql.enabled` | An external database (recommended) or the bundled one |
| `sso.oidc.*` | Keycloak sign-in. See the note on `groupAdmins` below |
| `api.uploads.persistence` | The media volume at `/data/uploads`, persistent by default. Use `ReadWriteMany` when the API has several replicas |

**`sso.oidc.groupAdmins`**: leave it empty when the platform has managers. When it is set, every
OIDC user outside those groups becomes a student at each sign-in, managers included. Map the admin
group in `/admin/groups` instead.

## Routing

The platform is one hostname in front of two backends:

```
/api, /uploads, /metrics, /health   → api
/                                   → frontend (the admin app answers /admin and /manager)
```

The routing table is defined once, in `pupitre.routeTable` (`templates/_helpers.tpl`). Both front
doors are rendered from it, so they cannot disagree about which backend owns a path.

Every rule is a prefix match, or one exact match. That is Gateway API *Core* conformance, which
every Ingress controller also supports.

`/metrics` is routed to the API and public, as in the reference chart. Prometheus can also scrape
the pod directly, through its `prometheus.io/*` annotations.

### Choosing a front door

`ingress` and `httpRoute` are independent, and both **may be enabled at once**. That is useful
while migrating, or to serve two entry points.

```yaml
ingress:
  enabled: true
  className: nginx      # or traefik, or any other; the rules are the same
  host: courses.example.com

httpRoute:
  enabled: true
  tls: true             # the Gateway listener terminates TLS
  parentRefs:
    - name: pupitre-gateway
      namespace: gateway-system
      sectionName: websecure
```

`httpRoute.hostnames` defaults to `[ ingress.host ]`. A single-host install therefore sets the
hostname in one place, whichever front door it uses.

## Upgrading from genesary/pupitre-helm

The API uses the three services' database **as it is**: same tables, same migrations. An existing
release can be upgraded in place.

### Values

| genesary/pupitre-helm | This chart |
| --- | --- |
| `userService.*`, `courseService.*`, `checkerService.*` | `api.*`: one block for the image, resources, env, extra volumes… |
| `courseService.gitToken*` | `api.gitToken*` |
| `checkerService.gitLabToken`, `checkerService.env.GITLAB_BASE_URL` | `api.gitLabToken`, `api.env.GITLAB_BASE_URL` |
| `internalServiceSecret*` | Removed: no internal route is left |
| `jwtSecret: change-me-in-production-…` | Refused: set a real secret, or leave `jwtSecret` empty. Left empty, the placeholder kept in the release Secret is replaced by a generated secret |
| `frontend.image` (`pupitre-frontend`, Astro) | `frontend.image` (`pupitre-front`, nginx) |
| `admin.*`, `sso.*`, `ingress.*`, `httpRoute.*`, `database.*`, `postgresql.*`, `networkPolicy.enabled` | Unchanged |

`DB_MAX_OPEN_CONNS` and `DB_MAX_IDLE_CONNS` default to 30, the sum of the two services' pools.
Changing the JWT secret signs every user out once.

### Switch-over

1. **Back up the database.**
2. This step applies only with the **bundled PostgreSQL and persistence enabled**. The reference
   chart puts its own version in the StatefulSet's `volumeClaimTemplates`, and Kubernetes does
   not let an upgrade change those. Delete the StatefulSet but keep its pod and its volume; the
   upgrade recreates it on the same volume:

   ```bash
   kubectl delete statefulset <release>-postgresql --cascade=orphan
   ```

3. Upgrade with the converted values:

   ```bash
   helm upgrade <release> oci://ghcr.io/jojo91550/charts/pupitre --version <version> -f my-values.yaml --wait
   ```

   Helm then does three things:
   - creates the API;
   - routes `/api` and `/uploads` to it;
   - removes the three services.

   Requests to `/api` fail for the few seconds the API takes to become ready.

4. Check the API, then check that sign-in works:

   ```bash
   kubectl rollout status deploy/<release>-api
   kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://<release>-api:8080/health
   ```

5. Upload the media again. Media uploaded before the switch-over were written inside the old
   course-service container, because the reference chart mounted no volume there, and they are
   gone with it.

### Rollback

`helm rollback <release> <revision>` brings the three services back on the same database. With the
bundled PostgreSQL and persistence, run the `kubectl delete statefulset … --cascade=orphan` of
step 2 first, for the same reason.

The API adds one migration, which lets an IdP group be mapped to `manager`. At start-up, the
reference user-service puts back its rule that only allows `admin` and `student`. That fails while
a group is mapped to `manager`, so first delete those mappings in `/admin/groups`.

## Development

```bash
helm lint . --strict
helm unittest .
```

On tagged pushes, chart releases are packaged and pushed to GHCR (`oci://ghcr.io/<owner>/charts`);
see `.github/workflows/ci-helm.yaml`. As in the reference, the tag is the chart version, without
a `v` (`2.0.0`).
