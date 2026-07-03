export const meta = {
  name: 'review-gha-isolated-design',
  description: 'Multi-agent review of the gha-isolated Rust CLI design gist',
  phases: [
    { title: 'Review', detail: '4 parallel reviewers: facts, architecture, rust, existing-infra fit' },
    { title: 'Verify', detail: 'adversarial verification of high-impact claims' },
  ],
}

const GIST = '/tmp/claude-1000/-home-jleechan-projects-worktree-runner/8ca589dd-8422-44b1-a543-52bd7b71f14b/scratchpad/gistfile1.txt'
const REPO = '/home/jleechan/projects/worktree_runner'

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
          detail: { type: 'string', description: 'Full explanation with evidence (URLs, file paths, quotes)' },
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
    refuted: { type: 'boolean', description: 'true if the claim is wrong or unsupported' },
    reasoning: { type: 'string' },
    corrected_claim: { type: 'string', description: 'If partially wrong, the corrected version' },
  },
  required: ['refuted', 'reasoning'],
}

const REVIEWERS = [
  {
    key: 'facts',
    prompt: `You are a technical fact-checker with web access. Read the design document at ${GIST} (a design for "gha-isolated", a Rust CLI wrapping "gha-outrunner" for isolated self-hosted GitHub Actions runners). Use WebSearch/WebFetch extensively to verify EVERY external factual assumption in the design. Specifically investigate:
1. Does a project called "gha-outrunner" actually exist? Search GitHub, crates.io, web. If it does not exist or is obscure/unmaintained, that is a CRITICAL finding — the whole design wraps it. Check if the author may have meant something else (e.g. actions-runner-controller, github-runner projects, "runs-on", ...).
2. Tart (tart.run / cirruslabs/tart) licensing: is it free for this use? (Fair Source / paid tiers — what are the actual limits as of 2026?)
3. GitHub "Scale Sets": runner scale sets are an Actions Runner Controller (ARC / Kubernetes) concept — can a standalone CLI use scale sets without k8s? Or should the design say "ephemeral runners + JIT config" instead?
4. GCE nested virtualization: the design claims GCE has "no strong KVM" — but GCE supports nested virtualization on most x86 machine types. Verify.
5. Sysbox status in 2026: Docker acquired Nestybox; is Sysbox CE maintained? Kernel/distro requirements?
6. serde_yaml crate: deprecated/archived? What's the recommended replacement?
7. Any well-established existing tools that already do what gha-isolated proposes (e.g. cirruslabs gitlab/github runner tart executors, RunsOn, actuated, garm (Cloudbase GitHub Actions Runner Manager), ARC, ubicloud, warpbuild, etc.) — is this reinventing an existing wheel?
Report each as a finding with evidence URLs. Be precise about what you could and could not verify.`,
  },
  {
    key: 'architecture',
    prompt: `You are a senior infrastructure architect reviewing a design doc. Read ${GIST} — a design for "gha-isolated", a Rust CLI that wraps "gha-outrunner" to run isolated self-hosted GitHub Actions runners (Tart VMs on macOS, libvirt on Linux, Docker+Sysbox fallback). Review the ARCHITECTURE for gaps and design flaws. Consider at minimum:
- Runner registration/auth: the design never mentions GitHub PAT/GitHub App tokens, JIT runner config, registration token lifecycle, or repo/org scoping. How do runners actually register?
- VM image management: where do Tart/libvirt guest images come from? Versioning, updates, disk usage, caching of toolchains inside images?
- Ephemeral lifecycle: who destroys VMs after a job? Crash recovery, orphan cleanup, disk-space reclamation?
- Backend selection: is 'has_kvm => libvirt' a sane default? libvirt setup burden vs docker on a typical Linux box. Is silent fallback to plain Docker (weakest isolation) acceptable, or should it require explicit opt-in ("fail closed vs fail open" on isolation)?
- Resource limits: hardcoded 4G/2cpu/count:2 — how should host capacity be reflected? What about disk limits (the most common runner failure mode)?
- Config: written to cwd as outrunner.yml — should be XDG/user config dir; no schema versioning; no secrets handling story.
- Observability: status, logs, health checks, alerting hooks.
- Security: job-to-host escape surface per backend, docker.sock exposure, network egress policy, secrets in env.
- Service management: launchd/systemd story is 'not yet implemented' but is essential for real use.
Rate each gap by severity. Do NOT fact-check external tools (another reviewer does that); focus on the design's internal completeness and soundness.`,
  },
  {
    key: 'rust',
    prompt: `You are a Rust reviewer. Read the design + skeleton code at ${GIST}. Review the Cargo.toml and skeleton Rust code for concrete issues:
- Dependency choices: serde_yaml (archived?), sysinfo pulled in but barely used (System::new_all + refresh_all just to detect OS — wasteful), duct vs std::process, missing deps for the stated scope (e.g. tokio? tracing? directories/xdg? thiserror?), version pinning.
- Code issues: config generation via format! string templating vs typed structs + serde (the design itself lists 'better config model' as future work — should be v1); Platform detection via cfg! at runtime vs compile time; /dev/kvm existence check doesn't verify permissions (user must be in kvm group); backend.rs 'assume Sysbox is installed' comment is a landmine; std::fs::write("outrunner.yml") writes to cwd; error handling; missing service.rs and limits.rs despite being in the module table (module table lists 7 files, main.rs declares only 4 mods).
- Structure: suggest what a credible v1 module layout and trait design would be (e.g. a Backend trait with detect/validate/start/stop implemented per backend).
Report concrete findings with severity.`,
  },
  {
    key: 'infra-fit',
    prompt: `You are reviewing how a proposed new tool fits an existing codebase. The proposal (read it at ${GIST}) is "gha-isolated": a Rust CLI for isolated self-hosted GitHub Actions runners (Tart on macOS, libvirt on Linux, Docker+Sysbox fallback), wrapping a tool called gha-outrunner.
The repo at ${REPO} ALREADY runs self-hosted GitHub Actions runners. Explore:
- ${REPO}/self-hosted-oss/ (read README.md, install.sh header comments, docker-compose.yml, pre-job-hook.sh, heal-runners.sh, mac-runner-health.sh, LINUX_HOST_POLICY.md, linux/ subdir)
- ${REPO}/self-hosted-colima/ (README.md, docker-compose.yml, scripts/)
- Recent git log in that repo mentioning runners (git -C ${REPO} log --oneline -20)
Summarize: (1) what the existing runner setup does today (platforms, isolation level, resource limits, health/healing, disk cleanup, launchd/systemd wiring); (2) which pain points the existing setup has that gha-isolated would genuinely solve; (3) which hard-won operational lessons in the existing scripts (disk cleanup pre-job hooks, health thresholds, colima VM sizing, cache integrity checks, Slack alerting) are MISSING from the gha-isolated design and must be carried over; (4) whether a new Rust binary is justified vs extending the existing bash/compose setup — give an honest assessment. Also note the repo CLAUDE.md rule that self-hosted runner changes must be in git and reproducible via install.sh.`,
  },
]

phase('Review')
const reviews = await parallel(REVIEWERS.map(r => () =>
  agent(r.prompt, { label: `review:${r.key}`, phase: 'Review', schema: FINDINGS_SCHEMA })
    .then(res => res ? { key: r.key, ...res } : null)
))

const valid = reviews.filter(Boolean)
log(`${valid.length}/4 reviewers completed; ${valid.flatMap(r => r.findings).length} raw findings`)

// Verify only critical/major findings adversarially (dedup happens naturally per-reviewer)
const toVerify = valid.flatMap(r => r.findings.filter(f => f.severity !== 'minor').map(f => ({ ...f, from: r.key })))

phase('Verify')
const verified = await parallel(toVerify.map(f => () =>
  agent(`Adversarially verify this finding about a design doc (the doc is at ${GIST}; the repo is ${REPO}; you may use WebSearch/WebFetch and read files). Try to REFUTE it. Finding from the "${f.from}" reviewer, severity ${f.severity}:
TITLE: ${f.title}
DETAIL: ${f.detail}
RECOMMENDATION: ${f.recommendation}
Is the finding factually correct and does the recommendation make sense? If the factual basis is wrong or the severity is inflated, refute it. Default to refuted=true only if you have concrete contrary evidence or the claim is unsupported after checking.`,
    { label: `verify:${f.title.slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA })
    .then(v => ({ ...f, verdict: v }))
))

const confirmed = verified.filter(Boolean).filter(f => f.verdict && !f.verdict.refuted)
const refuted = verified.filter(Boolean).filter(f => f.verdict && f.verdict.refuted)
const minors = valid.flatMap(r => r.findings.filter(f => f.severity === 'minor').map(f => ({ ...f, from: r.key })))

log(`${confirmed.length} confirmed, ${refuted.length} refuted, ${minors.length} minor (unverified)`)

return {
  summaries: valid.map(r => ({ reviewer: r.key, summary: r.summary })),
  confirmed,
  refuted: refuted.map(f => ({ title: f.title, from: f.from, why_refuted: f.verdict.reasoning, corrected: f.verdict.corrected_claim })),
  minors,
}