# media inference workers on Runpod

This independent HCP Terraform root prepares **two on-demand Secure Cloud Pods,
each requesting exactly one NVIDIA L40S**, with a 200 GB Pod-local volume
per worker. No network volumes are created. `va1/nodes` owns the manual
`example-organization/runpod-media-ml` workspace.
AWS is unchanged. No GPUs or HCP resources are created by adding these files.
Both worker IDs are **disabled by default**, so the root remains at zero Pods
until workers are explicitly enabled.

Pods are containers, not full VMs. Runpod manages host drivers and allocates
CPU/RAM; the request sets minimums of 8 vCPUs and 32 GB RAM per GPU, not the
original 32-vCPU/128-GB machine specification. Verify the actual allocation
before accepting a deployment. media-worker's speech and voice-preparation services
start automatically and expose authenticated HTTPS endpoints through Runpod's
HTTP proxy. The API and PostgreSQL 16 run separately on VA1; see
[the media-worker API runbook](../va1/media-apps-dev/media-worker.md).

Bootstrap configures the GPU check, shared `ubuntu` account/workspace and
Tailscale SSH, a non-root Emisar runner and a non-root media-worker process group
automatically, including enrollment on new/replacement Pods.
The Tailscale Terraform workspace creates one restricted enrollment client; an
administrator transfers its sensitive output to Runpod Secrets once before
applying. **No per-Pod administrator enrollment login is required**. Runtime readiness is
reported in Pod logs, not guaranteed by Terraform's control-plane success.
The short launcher executes the reviewed non-secret bootstrap from
`media_ML_BOOTSTRAP_B64`. Base64 preserves newlines in the console env editor;
it is not encryption. This keeps `dockerArgs` within the console's 4000-character
edit limit, so an approved same-Pod repair does not require releasing its GPU.

## Deploy manually

1. Check the funded Runpod account for **on-demand Secure Cloud L40S capacity**.
   By default, no data-center filter is sent, so workers can land in different
   locations. Set `data_center_id` only if you need a reviewed specific location;
   placement preferences are not capacity reservations. Network-storage
   availability is not required. Review the storage/data-loss caveats below.
2. Use the digest-pinned private media-worker image in `terraform.tfvars.example`.
   Its authenticated, digest-verified metadata and startup script were inspected
   on 2026-10-14 for v2: `linux/amd64`, root-run Ubuntu 22.04, CUDA 13.0.2, application
   Python at `/opt/media-worker-qwen3-tts/.venv/bin`, and
   `/usr/local/bin/media-worker-entrypoint`. The supervisor replaces the initial
   entrypoint, then launches that vendor script as UID 2000 with a sanitized env.
   This inspection is **not live GPU or inference qualification**.

   In **Runpod → Credentials → Container Registry Auth**, create/select
   `media-worker-quay` using media-worker's supplied Quay robot username and token. Enter
   the token directly in Runpod, never in Terraform, Git or task evidence.
   Record only the returned credential ID for `container_registry_auth_id`.
   The token embedded in the handoff document should be rotated with media-worker
   through an operator-approved handoff; this root does not rotate it.

   Create Runpod Secret `media-worker_internal_token` with the shared bearer token
   also stored as sensitive `media-worker_shared_token` in `media-apps-dev`.
   Bootstrap rejects missing, unresolved, whitespace-containing or short
   tokens before starting any media-worker listener. Terraform stores only the
   literal secret reference, never the bearer value. `/ready` remains public.

   New Pods leave `allowed_cuda_versions` empty: Runpod's exact-match REST enum
   currently rejects the 13.2 hosts advertised by its capacity catalog, while
   filtering for 13.0 excludes those compatible newer drivers. Bootstrap rejects
   drivers older than 580 and requires a successful CUDA calculation on exactly
   one L40S before starting the services. If placement selects an incompatible
   host, bootstrap fails closed and the Pod must be replaced. This cannot upgrade
   the host's driver or guarantee compatible-host capacity. Do not disable CUDA checks or
   install a physical-host driver inside the container.
3. Create only the HCP workspace/settings through the existing nodes workspace:

   ```sh
   terraform -chdir=terraform/environments/va1/nodes init
   terraform -chdir=terraform/environments/va1/nodes plan -refresh=false -lock=false \
     -target=tfe_workspace.runpod_media_ml \
     -target=tfe_workspace_settings.runpod_media_ml
   terraform -chdir=terraform/environments/va1/nodes apply \
     -target=tfe_workspace.runpod_media_ml \
     -target=tfe_workspace_settings.runpod_media_ml
   ```

   These are **operator-run commands with manual approval**, not an agent apply.
   They create HCP configuration, not GPUs. Follow this exceptional targeted
   operation with a normal nodes plan to review omitted changes. The Runpod
   workspace has remote execution, auto-apply disabled and no VCS auto-apply.
4. In that HCP workspace, add `RUNPOD_API_KEY` as an **Environment variable,
   Sensitive enabled**. Enter the appropriately permissioned Runpod API key
   directly in HCP. Never put it in nodes variables/state, `.tfvars`, Pod env,
   startup commands, this repository or chat. Rotate/revoke it through the
   account and update HCP when necessary.
5. Set HCP **Terraform variable** `container_registry_auth_id` to the non-secret
   Runpod credential ID (string, HCL disabled). Set `gpu_image` to the reviewed
   digest-pinned reference, or remove the old HCP override to use the source
   default. Old PyTorch, unauthenticated media-worker v1 and unreviewed digests are
   rejected at plan time; an image update must update the reviewed allowlist.
   Leave `data_center_id` unset for broad
   placement, or set an exact location string with HCL disabled. The source
   default disables `01` and `02`. To start with one GPU, set
   `workers` with **HCL enabled** in HCP:

   ```hcl
   { "01" = true, "02" = false }
   ```

   Enable `02` separately when ready to scale to two billable GPUs.
   To remain paused, keep both values `false`. An HCP override takes precedence
   over the source default: maintain the worker map in one place.
   `storage_size_gb` defaults to 200; any override is an HCL
   integer. The example tfvars file is an alternative input mechanism, not an
   additional owner for the same values.
6. One-time automatic enrollment setup:

   - Follow the [Tailscale workspace's one-time Runpod setup](../tailscale/tenant/README.md#runpod-automatic-enrollment):
     follow its workspace deployment workflow for the dedicated
     `media-runpod-enrollment` client. It grants **Auth Keys → Write
     (`auth_keys`)**, restricted to **only `tag:media-ml`**. Do not grant
     `all`, `devices:core`, ACL editing, or reuse the Nomad/tenant credentials.
     No manual OAuth-client creation in the Tailscale console is needed.
   - In **Runpod → Settings → Secrets**, create a secret named exactly
     `media_ml_tailscale_oauth`. Copy the Tailscale workspace's sensitive
     `media_runpod_oauth_client_secret` output directly into its value,
     without query parameters, using the private clipboard command in that
     runbook. This must be the **client secret**, not its ID or an auth key.
     Never send it through chat, Terraform/HCP variables, source, task files or
     command arguments. Its storage in **Tailscale HCP state/history** is an
     explicitly approved exception; it must not enter **Runpod Terraform state**.
   - No additional HCP variable is needed. Terraform supplies only the literal
     `{{ RUNPOD_SECRET_media_ml_tailscale_oauth }}` in Pod env; Runpod resolves
     it inside the container at startup. Provider 1.0.1 preserves the planned
     env reference in state rather than copying returned Pod env. Its Read
     implementation also does not adopt console-edited startup commands/env;
     a same-Pod recovery edit does not reconcile Terraform state automatically.

   Existing tailnet tag/team policy must already be applied. Enrollment requests
   ephemeral, preauthorized nodes, avoiding manual device approval and eventually
   cleaning up inactive nodes. OAuth provides fresh short-lived auth keys rather
   than requiring a periodically expiring reusable auth key. See
   [Tailscale OAuth enrollment](https://tailscale.com/docs/features/oauth-clients)
   and [Runpod Secrets](https://docs.runpod.io/pods/templates/secrets).
   - In the **media Emisar account**, create a **reusable** runner enrollment
     key with sufficient uses and lifetime for two Pods and future replacements.
     The Connect-a-runner wizard's single-use key is not suitable for this fleet.
     Store it in Runpod Secrets as exactly `media_emisar_enrollment_key`.
     Terraform passes only `{{ RUNPOD_SECRET_media_emisar_enrollment_key }}`;
     never put its value in HCP variables, source, task evidence or chat.
     See [Emisar containers](https://emisar.dev/docs/containers).
7. From this checkout, qualify the published dependencies, then initialize the
   Runpod root and review/approve deployment. **Stop if the preflight fails**:

   ```sh
   bash terraform/environments/runpod/scripts/test-published-packs.sh
   terraform -chdir=terraform/environments/runpod init
   terraform -chdir=terraform/environments/runpod plan -refresh=false -lock=false
   terraform -chdir=terraform/environments/runpod apply
   ```

   With only `01` enabled, an empty workspace plan creates one Pod and one
   built-in revision record (**one billable GPU**). With both enabled it creates
   two Pods and two revision records. An existing Pod is replaced, not an extra
   worker added. Each Pod requests
   a 200 GB local volume at `/workspace`, plus a 50 GB container disk. Check the
   exact GPU model/count, Secure Cloud, non-interruptible placement and costs.
   Apply generates a fresh approval plan; there is no automatic approval.
   If only one Pod is created before a capacity failure, it may already be
   billable. Inspect the failed run and actual resources before retrying;
   do not silently switch GPUs/cloud types or delete managed Pods.
   **Re-plan after this automation change**; the earlier manual-enrollment plan
   is not the updated configuration. Bootstrap changes replace any existing Pod,
   losing its local data; export valuable files before approving replacement.
8. Wait for each Pod's logs to show `media ML ready:` with its exact SSH name.
   This is emitted only after the single-L40S check and Tailscale's online Running
   state, expected tag/DNS name, SSH-enabled preference, Emisar's connected
   local runtime with all five packs, and **both media-worker `/ready` endpoints**.
   media-worker gets up to 30 minutes for first model download/JIT initialization;
   the vendor estimates about 15 minutes. Terraform apply does
   **not** wait for or prove bootstrap, CUDA inference or application readiness.
   Failed bootstrap can leave a billable Pod; use recovery access to inspect it.

## Connect and recover

After bootstrap is ready, use the exact `workers` output for connection commands:

```sh
terraform -chdir=terraform/environments/runpod output workers
```

Pod names/resource keys remain `media-ml-runpod-01`/`02`, but Tailscale DNS
names include each full Runpod Pod ID, for example
`media-ml-runpod-01-<pod-id>`. Bootstrap derives that suffix from Runpod's
documented `RUNPOD_POD_ID`, not a Terraform dependency on the Pod being created.
The worker base is truncated to 30 characters before the suffix to stay within
the 63-character DNS limit. Replacement Pods get new DNS names, avoiding stale
record collisions without device-deletion permissions. Use refreshed outputs
after replacement, not a hardcoded old hostname.
After an unclean same-Pod reset, MagicDNS may add a numeric collision suffix.
Bootstrap accepts only that suffix and prints the actual full DNS name in its
ready line; use that name if it differs from the nominal Terraform output.

If startup fails, an administrator uses **Pods → expand Pod → Connect →
Start/Open Web Terminal**. Inspect Pod logs and run `tailscale status` (do not
print env, reveal the secret, or share daemon-state files). Missing/unresolved
secrets, invalid OAuth, API/auth timeouts and failed readiness terminate bootstrap
with a nonzero status and stop/reap all three services. Failure messages are generic to
keep upstream credential/auth URLs out of Pod logs; the recovery terminal gives
local status. All three services are supervised for the container lifetime; stopping
the container forwards TERM, and an unexpected service exit terminates its peers
and fails the container. To inspect Emisar without revealing credentials:

```sh
sudo -u emisar env PY_VENV=/opt/media-python emisar --config /etc/emisar/config.yaml status
```

Do not dump environment variables, token files or raw private runner state.
Automatic container restart behavior is platform-controlled, not managed here.
If the web terminal is unavailable, use Runpod's account-authenticated **basic SSH gateway**
with a registered public key and the command shown in Connect. Keep the private
key local. Do not enable a public Pod SSH port or password-login workaround.
Recovery access depends on the Runpod account and is separate from team access.

The existing repository tailnet policy permits `group:media` and
`group:tenant_admins` to SSH as `ubuntu`, with 24-hour browser checks. Verify that
policy and current group membership are applied before relying on it. Team users
need Tailscale, not Runpod credentials:

```sh
# Substitute the actual names from Terraform's workers output.
tailscale ssh ubuntu@media-ml-runpod-01-POD_ID_HERE
tailscale ssh ubuntu@media-ml-runpod-02-POD_ID_HERE
```

With the macOS App Store client, use `ssh ubuntu@<output-hostname>` while
connected with MagicDNS instead. Every authorized team member shares the
sudo-capable container account: this is **container-admin access**, not access
to the physical GPU host, separate Unix identities or tenant isolation.

Tailscale runs under the bootstrap supervisor with userspace networking: no systemd, SSM or
TUN-device privilege is required. Its root-only state is on the private container
disk at `/var/lib/tailscale`; do not share/copy it into another running Pod.
**Stop/start, reset, deletion or replacement can lose that state**.
Inactive ephemeral device records may be removed while stopped; enrollment runs
on each boot, recovering fresh identities without an administrator login. It
does not require an administrator enrollment login on restarts.
On graceful supervisor shutdown it logs out the ephemeral node to release its
name. On an unclean reset, the actual ready-line DNS name is authoritative.
Ephemeral cleanup is eventual; Terraform does not own the tailnet device records.
The configuration does
not start public SSH/Jupyter services or request public IP/global networking.
Only `8000/http` and `8002/http` are requested. Runpod's HTTP proxy supplies
public HTTPS; the public-IP flag is not a Secure Cloud firewall. No public
SSH, notebook, design :8001 or metrics ports are requested. Keep later
notebooks on loopback. There is no AWS-style SSM session log.

For an explicitly installed notebook, bind it to `127.0.0.1:8888` and retain its
authentication. The `workers` output includes a local SSH tunnel command:

```sh
ssh -N -L 127.0.0.1:8888:127.0.0.1:8888 ubuntu@HOSTNAME_FROM_OUTPUT
```

Test forwarding against the applied SSH policy before use. Do not publish 8888
to the internet or widen tailnet grants for it.

## Automatic media-worker startup and authenticated HTTPS access

Each enabled Pod runs `media-worker_ROLE=all`: speech on `0.0.0.0:8000`, internal
design on `127.0.0.1:8001`, and preparation/design API on `0.0.0.0:8002`.
The v2 image requires the shared bearer token on application requests. The
worker outputs expose `https://<pod-id>-8000.proxy.runpod.net` and the matching
8002 URL. Verify both missing and incorrect tokens return 401; readiness alone
does not qualify authentication. No new tailnet grants are added. Administrators
can still use the `workers[*].media-worker_tunnel` command:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:8000:127.0.0.1:8000 -L 127.0.0.1:8002:127.0.0.1:8002 ubuntu@HOSTNAME_FROM_OUTPUT
# From a separate local terminal while the tunnel is open:
curl --fail http://127.0.0.1:8000/ready
curl --fail http://127.0.0.1:8002/ready
```

Use distinct local ports for multiple workers. The VA1 API uses the public
HTTPS outputs, not the SSH tunnel. Runpod documents a 100-second proxy response
timeout, so qualify design and audio streaming through these real HTTPS URLs.

The vendor entrypoint downloads approximately 13 GB of public models into
`/workspace/models/v1`, verifies `SHA256SUMS`, and uses `/workspace/cache` for
compilation caches. Model fetching stays enabled; it is not a Hugging Face login.
The service runs as dedicated `media-worker` UID 2000 without sudo/new privileges;
only the shared media-worker bearer token is included; Tailscale OAuth and Emisar
enrollment keys are excluded from its environment.
The shared volume remains unsuitable for secrets. No customer voices, Postgres
or authoritative blob data are deployed here.

The supplied image totals approximately 7.3 GB **compressed** layers; a streamed
unpacked-size audit timed out, so 50 GB container-disk fit has not been proved.
Keep 50 GB container storage and the separate 200 GB model/cache volume; do not
treat the latter as additional image space. Check actual extracted image size
and free container space during the approved rollout before accepting it.

## Emisar diagnostics

New Pods run pinned Emisar **0.31.1**, as dedicated UID **65532** without sudo,
with a unique runner ID matching its Pod-ID-suffixed Tailscale hostname. The group
is `media-ml`, with Runpod/ML/media labels. Installed version/hash-pinned
packs are `fs-search` 0.2.0, `debugging` 0.3.4, `network-tls` 0.3.2,
`python-app` 0.1.14 and `tailscale` 0.1.9. Their declared tools are installed.
All five refs must be checked against the live published registry before rollout:
`bash terraform/environments/runpod/scripts/test-published-packs.sh` rejects
retired versions, missing artifacts and mismatched hashes. The network pack was
updated on 2026-10-09 because versions below 0.3.1 were retired for a security fix.
Runner 0.31.1 advertises all 85 trusted action descriptors, with separate local
admission evidence: 51 low-risk actions admitted and 34 denied by this policy.
Denied siblings stay visible without invalidating the whole trusted pack.

This source pin is not a live-worker upgrade. Applying it replaces existing Pods
and deletes their local volumes. Upgrade the runner in place only through a
separately authorized, data-preserving operation after verifying the Portal
supports the admission evidence; do not apply a replacement to fix discovery.

Local admission is a **positive read-only allowlist** with a low-risk ceiling.
No arbitrary shell, process argv/environment dumps, root/capability-only process
or kernel inspection, raw ICMP, remediation, cloud administration or unrelated
database credentials are enabled. Raw file-content reads are advertised as
trusted descriptors but are denied by local admission.
Cloud policy/approval/trust controls still apply; this allowlist does not bypass
them. Diagnostics see this container, not its physical Runpod GPU host.

The Python pack's venv-shaped path `/opt/media-python` links to the CUDA
image's actual Python and wraps `python -m pip`; no second environment is created.
If that image environment omits pip, bootstrap uses Python's bundled offline
`ensurepip` installer. It does not replace Python, Torch or CUDA packages, and
fails visibly if the interpreter cannot seed pip.
Only `PY_VENV` is inherited by actions. The runner can use Tailscale's readonly
local API, not its state files or operator/configuration privileges.

Each Pod stores its separate token, dispatch state and journal under owner-only
`/var/lib/emisar` on the container disk, configured as the runner's canonical protected `data_dir`.
**Stop/start, reset, deletion or replacement can erase it** and need
fresh automatic enrollment. Never copy this directory to another running Pod.
The reusable enrollment key is unset from the supervisor's injected environment
before installing tools and passed only to the non-root runner at launch, never
in argv or action env. Like the OAuth credential, it remains within Runpod's
secret/container-admin trust boundary; container administrators can access it.

Local `doctor`, pack installation and the bootstrap ready line are not proof
that the control plane sees the runner. Acceptance requires the enabled runners
connected in the media account, matching trusted hashes, and successful
governed readonly canaries for each installed pack. CUDA/GPU verification is
separate: no standard GPU/Runpod diagnostic pack is installed here.

## Scale and manage disposable workers

Resource keys and Pod names are stable; SSH names also include the unique Pod ID.
Add `"03" = true` to provision a third
single-L40S worker with its own local volume, without renumbering existing workers.
Set a worker to `false` to **terminate its Pod and delete its local volume**.
Drain application work and export important files outside the Pod before
approving termination. Saving them under `/workspace` is not sufficient.
To remove all GPU compute and storage managed by this root:

```hcl
workers = { "01" = false, "02" = false }
```

In the HCP `workers` value, enter just the map, without `workers =`. Re-enable a
key to request a **fresh Pod with an empty local disk**; this does not reserve GPU
capacity. Download models again; Tailscale enrolls automatically if the Runpod
secret is valid. Keep reproducible
models/code caches in `/workspace/media-ml`. These survive stop/start of the
same Pod, not its deletion. The private `ubuntu` home is `/home/ubuntu` (UID 1000)
on the 50 GB container disk: home files and private identity state are disposable
on platform reset/stop-start. Re-enrollment is automatic; back up valuable home files separately.
Keep authoritative model artifacts, code and valuable outputs elsewhere;
media-worker installs its vendor model downloader; this root does not configure backups.

Runpod's console **Stop** is different from disabling a Terraform worker: it
releases GPU compute while retaining that Pod's local volume, which continues
to incur storage charges. Restart still depends on GPU capacity. There is no
independent retained disk or `prevent_destroy` storage guard in this design.

Image/bootstrap, registry credential ID, CUDA placement, media-worker environment,
secret-reference name, `storage_size_gb` and `data_center_id` changes explicitly replace
Pods, destroy-before-create, to avoid the provider's undocumented Pod-update
method. **All local files, home directories, Tailscale/Emisar identities and processes
are lost**, and reacquisition can fail for capacity. Even growing a disk through
this root replaces the Pod; export important files and review the plan first.
Hardware/cloud settings are
fixed in source; do not rely on this provider to change GPU fields in place.
Do not manually delete Terraform-managed Pods in the console: this provider
errors on externally missing Pods instead of automatically reconciling state.

## Storage, provider and budget caveats

The pinned provider is third-party
[`decentralized-infrastructure/runpod` 1.0.1](https://github.com/decentralized-infrastructure/terraform-provider-runpod/tree/v1.0.1).
Its create fields were checked against the current REST contract and its schema
loaded locally. An authenticated single-L40S allocation, automatic enrollment,
SSH and CUDA smoke test were verified on 2026-10-08; this is not inference-service
or governed Emisar action readiness. Vendor provider
1.0.9's source uses different Pod-create fields from the documented API, so it
is not used here; that is a source-level finding, not a reproduced live failure.
The lock includes local darwin_arm64 and HCP linux_amd64 packages. Do not infer
CPU count from the community schema's CPU-Pod default; inspect actual allocation.

Runpod offers encryption for Pod volume disks, but this pinned provider does not
expose an encryption input, so this configuration **does not request or establish
volume encryption**. Container disks cannot use that feature. A live US-NC-1
Pod-local volume used FUSE with fixed 0777 directories/0666 files, ignored chmod,
and rejected chown. Bootstrap therefore keeps models on that shared volume but
homes and credential-bearing Tailscale/Emisar state on private container storage,
and verifies actual owner/mode before enrollment. Root-only permissions are not
encrypted EBS parity. Do not put sensitive datasets, SSH keys or application
credentials in `/workspace` without an approved additional protection scheme.

The runtime OAuth credential also inherits Runpod's secret/container trust
boundary: Runpod operators and every sudo-capable team member can potentially
access it and enroll additional nodes with `tag:media-ml`. Narrow scope
limits that authority; it does not isolate it from container administrators.
Bootstrap unsets its injected env before subprocesses, reads auth via a root-only
temporary file in RAM-backed `/dev/shm`, and removes the file on success/failure;
it is never stored under `/workspace`, in CLI argv or emitted to logs. Runtime
env injection is not a guarantee that the platform's original env is erased.
The dedicated client is Terraform-managed in the Tailscale workspace with
`prevent_destroy`; its generated secret and sensitive output remain in that
workspace's HCP state/history by explicit approval. Imports do not recover the
secret. Restrict state access and review recovery/rotation through its runbook;
do not delete a managed client ad hoc. Runpod Secret creation/update is an operator
handoff, not Terraform-managed. Restart Pods to pick up an updated secret (export
non-volume data first); no Runpod Terraform secret-value change is needed.
Revoking a compromised client does **not** remove existing devices; revoke
affected device access separately. No automatic client rotation or
manual-enrollment helper is installed.

Budget reference checked 2026-10-05, not a quote: at the published Secure Cloud
L40S rate of $1.09/hour, two continuously running GPUs are **$52.32/day**. For a
30-day/720-hour month, compute is $1,569.60, two running 200 GB Pod-local volumes
are about $40 ($0.10/GB-month), and two 50 GB container disks about $10:
**roughly $1,620/month** before taxes/other charges. Local disks are not cheaper
per GB than standard network storage; they remove its placement constraint.
With both workers disabled and deletion successfully applied, no Pods or disks
remain in this root. Stopping rather than deleting both Pods retains their local
volumes at $0.20/GB-month, about $80/month for 400 GB. Confirm the live account
quote and bill; do not add a disk charge twice if already included in a Pod quote.

Primary platform references:

- [Pod creation API](https://docs.runpod.io/api-reference/pods/POST/pods)
- [Storage types and encryption](https://docs.runpod.io/pods/storage/types)
- [Connection options and recovery terminal](https://docs.runpod.io/pods/connect-to-a-pod)
- [Account SSH setup](https://docs.runpod.io/pods/configuration/use-ssh)
- [Tailscale SSH in containers](https://tailscale.com/learn/ssh-into-docker-container)
- [OAuth enrollment and restricted scopes](https://tailscale.com/docs/features/oauth-clients)
- [Runpod Secrets](https://docs.runpod.io/pods/templates/secrets)
- [Runpod-provided Pod ID](https://docs.runpod.io/pods/templates/environment-variables)
- [Runpod pricing](https://www.runpod.io/pricing)

## Verification

Offline provider validation and mocked **plans**, with no credentials/cloud writes:

```sh
terraform fmt -check -recursive terraform/
terraform -chdir=terraform/environments/runpod init -backend=false -input=false
terraform -chdir=terraform/environments/runpod validate
terraform -chdir=terraform/environments/runpod test
bash -n terraform/environments/runpod/scripts/*.sh
shellcheck -x -P terraform/environments/runpod/scripts \
  terraform/environments/runpod/scripts/*.sh
bash terraform/environments/runpod/scripts/test-bootstrap.sh
bash terraform/environments/runpod/scripts/test-launch-bootstrap.sh
bash terraform/environments/runpod/scripts/test-python-tools.sh
```

Qualify the released runner and packs in a disposable CPU-only container (no
enrollment or GPU requests):

```sh
docker run --rm --platform linux/amd64 \
  --tmpfs /opt/emisar/packs \
  --mount type=bind,src="$PWD/terraform/environments/runpod/scripts",dst=/tests,readonly \
  ubuntu:24.04 bash /tests/test-emisar-container.sh
```

Qualify media-worker supervision in a small disposable Ubuntu 22.04 container:

```sh
docker run --rm --init \
  --mount type=bind,src="$PWD/terraform/environments/runpod/scripts",dst=/tests,readonly \
  ubuntu:22.04 bash /tests/test-media-worker-container.sh
```

This CPU fixture is native-architecture portable: it tests the real privilege,
environment, authenticated public-listener fixture and process-group helpers, not the private
media-worker image, GPU inference, model download or remote SSH forwarding. On
2026-10-14 the fixture passed in a disposable Linux amd64 container.

Also initialize with `-backend=false -input=false` and validate `va1/nodes` when
its workspace definition changes. Mock tests check the paused default, two enabled workers, scale-up,
middle/all-worker disable without retained storage, optional/default location,
replacement revisions, exact GPU/storage wiring and
invalid inputs. Replacement/long-name plans verify exact Pod-ID-suffixed output
commands. Shell tests cover missing/unresolved OAuth and Emisar inputs, readiness denial,
mock API/auth timeout failures, credential redaction/cleanup, signal forwarding,
unexpected exits of any supervised service and retained-state preservation. They mock the CLI/daemon
and timers: they do not exercise live capacity, OAuth authentication, platform
secret resolution, CUDA or actual Tailscale state restoration. The CPU container
test additionally exercises real POSIX and ownership-denying FUSE storage
fixtures (via `test-workspace.sh`), private home/state
permissions, pinned real binaries/packs, prerequisites, non-root read-only actions,
admission denial and protected runner-state paths. Its portable
`test-emisar-advertisement.sh` checker verifies complete trusted descriptors and
separate admission evidence, rejecting omissions, changed hashes, missing evidence
and an expanded local allowlist. It can also check public `emisar state` output
without enrolling a runner or executing actions.

After an approved apply/automatic enrollment, accept the fleet only after:

- `nvidia-smi -L` shows **one L40S per Pod**; inspect VRAM, driver, RAM and storage.
- A real CUDA inference smoke test passes in the selected image, for example:
  `python -c 'import torch; assert torch.cuda.device_count() == 1; assert "L40S" in torch.cuda.get_device_name(0); print(torch.ones(1, device="cuda").cpu())'`.
- The driver is 580+, both media-worker endpoints return ready through their actual
  public HTTPS URLs, missing/wrong bearer tokens are denied on application
  requests, and models/caches use the volume. Verify container-disk free
  space after image extraction; neither local mocks nor image metadata prove it.
- An media user and tenant administrator connect as `ubuntu`; unrelated
  identities and direct root login fail. Confirm browser check behavior and
  no public SSH/Jupyter or direct 8888 access. Only authenticated speech/prep
  application services (and their public readiness checks) use the HTTPS proxy.
- The secret reference resolves and each enabled Pod enrolls automatically with the
  expected tag and exact output DNS name; no per-Pod enrollment browser login is
  requested. The existing 24-hour SSH user checks remain unchanged.
- Each enabled Emisar runner appears connected in `media-ml`, advertises the five
  pinned trusted packs without degraded prerequisites, and execute governed
  read-only canaries through the media control plane.
- A separately approved stop/start preserves model test files under `/workspace`
  while resetting container-private home/node state and automatically re-enrolling.
  A separate deliberate Pod recreation loses
  local files/identity as documented and requires separate approval; model restoration and fresh automatic
  enrollment work, with updated output commands and no DNS collision. Export
  valuable files before either check and confirm actual costs.

These are operator-run live checks. No live GPU, tailnet enrollment or deployment
readiness is established by local validation.

The approved v2 rollout also includes the VA1 API and isolated PostgreSQL 16.
Follow [the API rollout and qualification checklist](../va1/media-apps-dev/media-worker.md):
speech, voice creation/design, streaming and persistent voices must work
end-to-end through the public HTTPS API before the complete deployment is accepted.
