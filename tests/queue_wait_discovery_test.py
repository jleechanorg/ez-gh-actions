import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('discovery', ROOT / 'scripts/queue_wait_discovery.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
NOW = 1800000000

def job(ident=7, labels=None, status='queued', age=1800):
    import datetime
    return dict(id=ident, status=status, labels=labels if labels is not None else ['self-hosted', 'ezgha'], created_at=datetime.datetime.fromtimestamp(NOW-age, datetime.timezone.utc).isoformat().replace('+00:00','Z'), started_at=None, html_url=f'https://github.com/o/r/actions/runs/1/job/{ident}')

class Discovery(unittest.TestCase):
    def scan(self, jobs=None, **env):
        paths=[]
        def call(path):
            paths.append(path)
            if '/jobs?' in path:
                return dict(total_count=len(jobs or []), jobs=jobs or [])
            runs=[dict(id=1,created_at='2020-01-01T00:00:00Z')] if 'status=in_progress&' in path else []
            return dict(total_count=len(runs), workflow_runs=runs)
        result=m.discover(dict(ALERT_REPOS='o/r', QUEUE_NOW_EPOCH=str(NOW), **env),call=call)
        return result,paths
    def test_old_container_fresh_queued_job(self):
        r,p=self.scan([job()]); self.assertEqual(r['jobs'][0]['wait_min'],30); self.assertTrue(any('filter=latest' in x for x in p))
    def test_running_never_waiting(self):
        r,_=self.scan([job(status='in_progress')]); self.assertEqual(r['jobs'],[])
    def test_hosted_exclusion(self):
        r,_=self.scan([job(labels=['ubuntu-latest'])]); self.assertEqual(r['excluded'],1)
    def test_custom_selfhosted_label(self):
        r,_=self.scan([job(labels=['ezgha'])]); self.assertEqual(len(r['jobs']),1)
    def test_unknown_labels_fail_closed(self):
        with self.assertRaises(ValueError): self.scan([job(labels=['mystery'])])
    def test_missing_labels_fail_closed(self):
        with self.assertRaises(ValueError): self.scan([job(labels=[])])
    def test_parked_mac(self):
        r,_=self.scan([job(labels=['self-hosted','self-hosted-macos'])],MAC_RUNNER_DISABLED='1'); self.assertEqual(r['excluded'],1)
    def test_cap_is_incomplete(self):
        with self.assertRaises(OverflowError): self.scan([job()],MAX_RUN_CHECKS='0')
    def test_deadline_is_incomplete(self):
        with self.assertRaises(OverflowError): self.scan([job()],MAX_RUN_SEC='0')
    def test_future_time_rejected(self):
        with self.assertRaises(ValueError): self.scan([job(age=-60)])
    def test_job_evidence(self):
        r,_=self.scan([job()]); self.assertEqual(r['jobs'][0]['key'],'o/r:7'); self.assertIsNone(r['jobs'][0]['started_at'])
    def test_queued_with_started_timestamp_retained(self):
        j=job(); j['started_at']=j['created_at']; r,_=self.scan([j]); self.assertEqual(len(r['jobs']),1)
    def test_paginate_runs_and_jobs(self):
        paths=[]
        def call(path):
            paths.append(path)
            if '/jobs?' in path:
                page=int(path.rsplit('=',1)[1]); js=[job(i) for i in (range(100) if page==1 else [100])]
                return dict(total_count=101,jobs=js)
            if 'status=queued&' in path:
                page=int(path.rsplit('=',1)[1]); ids=range(100) if page==1 else [100]
                return dict(total_count=101,workflow_runs=[dict(id=i) for i in ids])
            return dict(total_count=0,workflow_runs=[])
        # Skip repeated job identities across runs by returning jobs only for first run.
        def once(path):
            if '/jobs?' in path and '/runs/0/' not in path: return dict(total_count=0,jobs=[])
            return call(path)
        r=m.discover(dict(ALERT_REPOS='o/r',QUEUE_NOW_EPOCH=str(NOW),MAX_RUN_CHECKS='200',MAX_API_CALLS='300'),call=once)
        self.assertEqual(len(r['jobs']),101); self.assertEqual(r['runs_checked'],101)
    def test_count_change_rejected(self):
        def call(path):
            page=int(path.rsplit('=',1)[1])
            return dict(total_count=101 if page==1 else 102, workflow_runs=[dict(id=i) for i in (range(100) if page==1 else [100])])
        with self.assertRaises(ValueError): m.discover(dict(ALERT_REPOS='o/r',MAX_RUN_CHECKS='200'), call=call)
    def test_missing_count_rejected(self):
        with self.assertRaises(ValueError): m.discover(dict(ALERT_REPOS='o/r'), call=lambda _: dict(workflow_runs=[]))
    def test_api_budget_rejected(self):
        with self.assertRaises(OverflowError): self.scan([job()],MAX_API_CALLS='0')
    def test_short_page_with_more_count_rejected(self):
        with self.assertRaises(ValueError):
            m.discover(dict(ALERT_REPOS='o/r'),call=lambda _:dict(total_count=101,workflow_runs=[dict(id=1)]))

class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup); self.t=Path(self.tmp.name)
        self.g=self.t/'gcloud'; self.g.write_text('#!/usr/bin/env python3\nimport os,sys\nwith open(os.environ["GLOG"],"a") as f:f.write(sys.argv[4]+"\\n")\nsys.exit(int(os.environ.get("FAIL_GCLOUD","0")))\n'); self.g.chmod(0o755)
        self.env=dict(os.environ, STATE_FILE=str(self.t/'state'),GLOG=str(self.t/'glog'),GCLOUD_BIN=str(self.g),QUEUE_WAIT_SIMULATE_MIN='30',SUSTAIN_CYCLES='2')
    def run_script(self,**env):
        return subprocess.run([str(ROOT/'scripts/queue-wait-alert.sh')],env=dict(self.env,**env),capture_output=True,text=True)
    def logs(self):
        return [json.loads(x) for x in (self.t/'glog').read_text().splitlines()] if (self.t/'glog').exists() else []
    def state(self):return json.loads((self.t/'state').read_text())
    def test_sustain_dedupe_heartbeat_and_recovery(self):
        self.assertEqual(self.run_script().returncode,0); self.assertEqual(self.run_script().returncode,0); self.run_script()
        self.assertEqual(sum(x['status']=='QUEUE_BACKED_UP' for x in self.logs()),1)
        self.assertEqual(self.logs()[-1]['status'],'HEARTBEAT')
        self.run_script(QUEUE_WAIT_SIMULATE_MIN='1'); self.assertEqual(self.state()['breaches'],0)
    def test_partial_never_healthy_or_reset(self):
        self.run_script(); before=self.state()['jobs']
        r=self.run_script(QUEUE_WAIT_SIMULATE_MIN='',GH_BIN='false',MAX_API_FAILURES='1')
        self.assertNotIn('queue ok',r.stdout); self.assertEqual(self.state()['jobs'],before)
        self.assertEqual(self.logs()[-1]['status'],'BLIND')
        self.assertFalse(json.loads((self.t/'state.heartbeat.json').read_text())['complete'])
    def test_failed_delivery_retries_same_job(self):
        self.run_script(); self.assertNotEqual(self.run_script(FAIL_GCLOUD='1').returncode,0)
        self.assertEqual(self.state()['jobs']['simulated:1']['last_sent'],0)
        self.assertEqual(json.loads((self.t/'state.heartbeat.json').read_text())['delivery'],'failed')
        self.assertEqual(self.run_script().returncode,0)
        self.assertGreater(self.state()['jobs']['simulated:1']['last_sent'],0)
    def test_dry_run_writes_no_state_or_remote_log(self):
        r=subprocess.run([str(ROOT/'scripts/queue-wait-alert.sh'),'--dry-run'],env=self.env,capture_output=True,text=True)
        self.assertEqual(r.returncode,0); self.assertFalse((self.t/'state').exists()); self.assertEqual(self.logs(),[])

if __name__=='__main__': unittest.main()
