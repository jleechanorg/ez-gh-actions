export const meta = {
  name: 'er-ez-gh-actions',
  description: 'Adversarial /er evidence review + code review of ez-gh-actions v1',
  phases: [
    { title: 'Audit', detail: '4 parallel auditors: evidence provenance, live re-verification, code bugs, security' },
    { title: 'Verify', detail: 'adversarial verification of critical/major findings' },
    { title: 'Verdict', detail: 'final /er verdict synthesis' },
  ],
}

const REPO = '/home/jleechan/projects/ez-gh-actions'
const EV = `${REPO}/evidence/e2e-20260703`
const RUN_URL = 'https://github.com/jleechanorg/ez-gh-actions/actions/runs/28685531107'

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
          detail: { type: 'string' },
          recommendation: { type: 'string' },
        },
        required: ['title', 'severity', 'detail', 'recommendation'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['findings', 'summary'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
  },
  required: ['refuted', 'reasoning'],
}

const ER_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'PARTIAL', 'FAIL'] },
    reasoning: { type: 'string' },
    claim_table: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          status: { type: 'string', enum: ['PROVEN', 'PARTIAL', 'UNPROVEN'] },
          evidence: { type: 'string' },
        },
        required: ['claim', 'status', 'evidence'],
      },
    },
  },
  required: ['verdict', 'reasoning', 'claim_table'],
}

const AUDITORS = [
  {
    key: 'evidence-provenance',
    prompt: `You are a skeptical evidence auditor (/er style — zero tolerance for assertions without raw proof). Audit the evidence bundle at ${EV} (files: EVIDENCE.md, 01_init.txt..08_status_after_job.txt, config.toml, checksums.sha256).
Checks: (1) run \`cd ${EV} && sha256sum -c checksums.sha256\` — any failure is a critical finding. (2) Circular provenance: is any claim supported only by an artifact the claim itself generated, or do independent artifacts corroborate (e.g. container ID in 04_status_before_job.txt vs hostname in 07_job_log.txt — these come from different systems: local docker vs GitHub's job log)? (3) Internal consistency: runner name, container id, limits (5977MB=6267338752 bytes? do the math), timestamps ordering. (4) Do the artifacts actually show what EVIDENCE.md claims, line by line? (5) Anything that smells fabricated or copy-pasted. Report findings with severity; if the bundle is sound say so explicitly in the summary.`,
  },
  {
    key: 'live-reverify',
    prompt: `You are an independent verifier with live access. Re-verify the E2E claims of ${EV}/EVIDENCE.md against LIVE GitHub state — do not trust the bundle:
(1) \`gh run view 28685531107 -R jleechanorg/ez-gh-actions --json status,conclusion,headSha,event,workflowName\` — confirm success, workflow_dispatch, workflow name ezgha-selftest.
(2) \`gh run view 28685531107 -R jleechanorg/ez-gh-actions --log | grep -E 'runner name|hostname|6267338752|pids'\` — confirm the runner name ezgha-Jeff-Ubuntu-6a4833a11c652b and cgroup values appear in GitHub's own logs.
(3) \`gh api repos/jleechanorg/ez-gh-actions/actions/runners\` — confirm 0 lingering runners (ephemeral cleanup claim).
(4) \`gh api repos/jleechanorg/ez-gh-actions/commits/5ef5406779925598565c8d277d13b865db78947a --jq .sha\` and confirm the repo at github.com/jleechanorg/ez-gh-actions has the claimed code (spot-check src/docker_backend.rs on main for --memory/--cpus/--pids-limit flags via gh api or git -C ${REPO} show).
(5) Check the CI workflow runs on main: \`gh run list -R jleechanorg/ez-gh-actions -w CI --json conclusion,headSha -L 3\` — all green?
Any mismatch between bundle claims and live state is a critical finding. Report PROVEN/mismatch per claim in your summary.`,
  },
  {
    key: 'code-bugs',
    prompt: `You are a hostile Rust code reviewer. Review ALL source at ${REPO}/src/ (main.rs, platform.rs, backend.rs, config.rs, github.rs, docker_backend.rs, service.rs) plus Cargo.toml for REAL bugs that would bite in production: incorrect error handling, race conditions (e.g. serve loop vs stop, ensure_count counting exited-but-not-removed containers), wrong docker/gh CLI usage (flag syntax, output parsing fragility — docker ps --format json availability, df parsing), edge cases (count>1, org scope, config with cpus exceeding daemon after VM resize, memory-swap semantics), the unique_suffix collision risk, stop_all deregistering OTHER hosts' ezgha-* runners (org/multi-host hazard), managed_containers missing exited containers still holding registrations. Only report defects with a concrete failure scenario. Severity by impact.`,
  },
  {
    key: 'security',
    prompt: `You are a security reviewer. Review ${REPO}/src/ and the workflows in ${REPO}/.github/workflows/ for security issues: (1) command construction — can config values (target, labels, image) inject arguments into gh/docker invocations? Note std::process::Command passes args as vectors (no shell), but leading-dash argument injection into docker/gh flags is still possible — check each. (2) JIT config exposure via docker inspect / process listing — evaluate the documented tradeoff honestly. (3) Runner container hardening: what's missing (network egress, read-only rootfs, seccomp)? Is no-new-privileges + cgroup limits + no docker.sock accurate per the code? (4) Public-repo self-hosted runner risk: selftest.yml is workflow_dispatch-only — is anything else triggerable by forks? Is CI (ci.yml) on ubuntu-latest (safe)? (5) service.rs: unit/plist content injection via exe path? Report findings with severity and concrete attack scenarios.`,
  },
]

phase('Audit')
const audits = await parallel(AUDITORS.map(a => () =>
  agent(a.prompt, { label: `audit:${a.key}`, phase: 'Audit', schema: FINDINGS_SCHEMA })
    .then(r => (r ? { key: a.key, ...r } : null))
))
const valid = audits.filter(Boolean)
log(`${valid.length}/4 auditors done; ${valid.flatMap(a => a.findings).length} raw findings`)

const toVerify = valid.flatMap(a =>
  a.findings.filter(f => f.severity !== 'minor').map(f => ({ ...f, from: a.key }))
)

phase('Verify')
const verified = await parallel(toVerify.map(f => () =>
  agent(
    `Adversarially verify this finding about the repo at ${REPO} (public: github.com/jleechanorg/ez-gh-actions, evidence at ${EV}, run ${RUN_URL}). Try to REFUTE it by reading the actual code/evidence and, where relevant, live gh queries. Finding from "${f.from}" (${f.severity}): ${f.title}\n${f.detail}\nRefute if the factual basis is wrong, the scenario cannot occur, or severity is inflated (severity inflation alone -> not refuted, but say so).`,
    { label: `verify:${f.title.slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA }
  ).then(v => ({ ...f, verdict: v }))
))
const confirmed = verified.filter(Boolean).filter(f => f.verdict && !f.verdict.refuted)
log(`${confirmed.length}/${toVerify.length} critical/major findings confirmed`)

phase('Verdict')
const er = await agent(
  `You are the final /er evidence-review judge for ez-gh-actions v1 (repo ${REPO}, evidence ${EV}, live run ${RUN_URL}).
Auditor summaries:\n${valid.map(a => `## ${a.key}\n${a.summary}`).join('\n\n')}
Confirmed critical/major findings after adversarial verification:\n${confirmed.length ? confirmed.map(f => `- [${f.severity}|${f.from}] ${f.title}: ${f.detail.slice(0, 300)}`).join('\n') : '(none)'}
The claims under review: (1) ezgha starts a real ephemeral JIT runner with hard cgroup limits; (2) a real GitHub Actions job executed on it; (3) the runner deregistered and container cleaned up after the job; (4) limits were enforced (memory.max/pids.max inside the job); (5) unit tests + CI green.
Rules: checksum failure or live-state mismatch = FAIL. Confirmed critical evidence-integrity finding = FAIL. Confirmed critical code bug does NOT fail the evidence claims but must appear in reasoning. Produce a claim-by-claim table and overall PASS/PARTIAL/FAIL.`,
  { label: 'er-verdict', phase: 'Verdict', schema: ER_SCHEMA, effort: 'high' }
)

return { er, confirmed, auditor_summaries: valid.map(a => ({ key: a.key, summary: a.summary })) }