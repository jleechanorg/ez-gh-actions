export const meta = {
  name: 'er-reverdict-ez-gh-actions',
  description: 'Re-run /er verdict after integrity + critical fixes',
  phases: [
    { title: 'Reaudit', detail: 'integrity re-check + fix verification' },
    { title: 'Verdict', detail: 'final /er verdict' },
  ],
}

const REPO = '/home/jleechan/projects/ez-gh-actions'
const EV = `${REPO}/evidence/e2e-20260703`

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: { type: 'array', items: { type: 'object', properties: {
      title: { type: 'string' }, severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, detail: { type: 'string' } },
      required: ['title', 'severity', 'detail'] } },
    summary: { type: 'string' },
  },
  required: ['findings', 'summary'],
}

const ER_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'PARTIAL', 'FAIL'] },
    reasoning: { type: 'string' },
    claim_table: { type: 'array', items: { type: 'object', properties: {
      claim: { type: 'string' }, status: { type: 'string', enum: ['PROVEN', 'PARTIAL', 'UNPROVEN'] }, evidence: { type: 'string' } },
      required: ['claim', 'status', 'evidence'] } },
  },
  required: ['verdict', 'reasoning', 'claim_table'],
}

phase('Reaudit')
const reaudits = await parallel([
  () => agent(`Skeptical evidence integrity re-audit of ${EV} (previous /er FAILED solely because git_sha.txt was in checksums.sha256 but missing; it has since been restored and checksums regenerated to cover new regression artifacts 09/10). Verify: (1) \`cd ${EV} && sha256sum -c checksums.sha256\` passes for ALL files with zero failures; (2) git_sha.txt content matches a real commit in the repo (git -C ${REPO} cat-file -t <sha>) and corresponds to the commit under test claimed in EVIDENCE.md (5ef5406...) OR is the later fix commit — explain which and whether that weakens commit-pinning; (3) new artifacts 09_start_after_fix.txt / 10_stop_after_fix.txt are internally consistent (runner started then fully cleaned: 0 containers, 0 registered) and consistent with live GitHub (gh api repos/jleechanorg/ez-gh-actions/actions/runners shows 0). Report any finding with severity; empty findings if clean.`, { label: 'reaudit:integrity', phase: 'Reaudit', schema: FINDINGS_SCHEMA }),
  () => agent(`Verify two critical-bug fixes are real in the code at ${REPO} (commit on main, also check github.com/jleechanorg/ez-gh-actions main via gh if needed):
(1) Disk floor guard: src/docker_backend.rs free_disk_gb() must now measure INSIDE the daemon (docker run --rm --entrypoint df <image> -Pk /) not host-side df, and ensure_count must warn loudly (not silently skip) when measurement fails. Confirm by reading the code AND by a live check: run \`docker run --rm --entrypoint df ghcr.io/actions/actions-runner:latest -Pk /\` and compare with host \`df -Pk /\` — they should differ on this Colima/Lima-style host, proving the daemon-side measurement is meaningful.
(2) Host-scoped stop: stop_all must only deregister runners matching our_runner_prefix() = "ezgha-<hostname>-", never bare "ezgha-". Confirm the code and that a unit test covers the prefix (cargo test runner_prefix). Also confirm cargo test passes 10/10 and clippy is clean (cargo clippy --all-targets 2>&1 | grep -c '^warning:').
Report findings if any fix is incomplete or cosmetic; empty findings if both fixes are sound.`, { label: 'reaudit:fixes', phase: 'Reaudit', schema: FINDINGS_SCHEMA }),
])

const valid = reaudits.filter(Boolean)
log(`${valid.length}/2 re-audits done; ${valid.flatMap(a => a.findings).length} findings`)

phase('Verdict')
const er = await agent(
  `You are the final /er judge, re-issuing the verdict for ez-gh-actions v1 after fixes (repo ${REPO}, evidence ${EV}).
Previous verdict was FAIL solely on evidence integrity (git_sha.txt missing from bundle though listed in manifest); all 5 substantive claims were PROVEN by live GitHub re-verification: (1) real ephemeral JIT runner with hard cgroup limits; (2) real Actions job run 28685531107 executed on it; (3) full ephemeral cleanup; (4) memory.max=6267338752/pids.max=512 proven inside the job; (5) CI green.
Re-audit summaries:\n${valid.map((a, i) => `## reaudit-${i}\n${a.summary}`).join('\n\n')}
Re-audit findings: ${JSON.stringify(valid.flatMap(a => a.findings))}
Rules: any remaining checksum failure or unfixed critical = FAIL. Integrity clean + fixes verified = PASS (note remaining documented majors as known limitations, they do not block). Produce the final claim table including the two fix-verification claims.`,
  { label: 'er-reverdict', phase: 'Verdict', schema: ER_SCHEMA, effort: 'high' }
)

return { er, reaudit_summaries: valid.map(a => a.summary), reaudit_findings: valid.flatMap(a => a.findings) }