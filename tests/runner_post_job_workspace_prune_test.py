"""Hermetic post-job cleanup contracts: never touches a real runner or Docker."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "docker/runner-post-job-workspace-prune.py"


class RunnerPostJobWorkspacePruneTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "the post-job cleanup implementation is missing")
        spec = importlib.util.spec_from_file_location("workspace_prune", SCRIPT)
        self.prune = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.prune)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name) / "runner"
        self.work = self.home / "_work"
        self.workspace = self.work / "widgets/widgets"
        self.workspace.mkdir(parents=True)
        self.env = {
            "RUNNER_NAME": "ez-runner-test-1",
            "GITHUB_REPOSITORY": "example/widgets",
            "GITHUB_WORKSPACE": str(self.workspace),
            "RUNNER_TEMP": str(self.work / "_temp"),
            "RUNNER_TOOL_CACHE": str(self.work / "_tool"),
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_JOB": "build",
        }
        # Production shape: actions/runner RunnerSettings DataMember names are
        # PascalCase and the live .runner stores Ephemeral as the string "True".
        self.settings = {
            "AgentName": self.env["RUNNER_NAME"],
            "WorkFolder": "_work",
            "Ephemeral": "True",
        }
        self.config = self.home / ".runner"
        self.write_settings()
        self.mounts = Path(self.directory.name) / "mountinfo"
        self.mounts.write_text("1 0 0:1 / / rw - overlay overlay rw\n")
        self.fixture_mounts = {}
        self.kept = {}
        for relative in (
            ".runner", ".credentials", ".credentials_rsaparams", ".env",
            ".path", "config.sh", "run.sh", "bin/Runner.Worker", "_diag/log.txt",
            ".cache/pip/wheel", "wheelhouse/package.whl", "_work/other/other/active",
            "_work/_PipelineMapping/state.json",
            "_work/_temp/_runner_file_commands/set_env", "_work/_temp/_github_workflow/event.json",
        ):
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if path != self.config:
                path.write_text("must remain: " + relative)
            self.kept[path] = path.read_bytes()
        for relative in ("widgets/sibling/active", "widgets/widgets/.git/config", "widgets/widgets/build/object", "_actions/action/index.js", "_temp/build.tmp", "_tool/python/bin/python"):
            path = self.work / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("transient")

    def write_settings(self):
        self.config.write_text(json.dumps(self.settings))

    def run_cleanup(self):
        output = io.StringIO()
        with mock.patch.object(self.prune, "WORK_ROOT", self.work), mock.patch.object(self.prune, "MOUNTINFO", self.mounts), mock.patch.object(self.prune, "mount_id", side_effect=self.fixture_mount_id), mock.patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(output):
            result = self.prune.main()
        self.assertEqual(result, 0, output.getvalue())
        return output.getvalue()

    def assert_preserved(self):
        for path, content in self.kept.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def assert_checkout_untouched(self):
        self.assertEqual((self.workspace / "build/object").read_text(), "transient")

    def fixture_mount_id(self, fd):
        # Model mount identity by inode, not only pathname. A renamed mount
        # retains its identity, and descendants inherit their nearest mount.
        path = Path(os.readlink(f"/proc/self/fd/{fd}"))
        for ancestor in (path, *path.parents):
            metadata = ancestor.stat()
            identity = (metadata.st_dev, metadata.st_ino)
            if identity in self.fixture_mounts:
                return self.fixture_mounts[identity]
        return 1

    def add_mount(self, path, kind="ext4", root="/"):
        # Linux mountinfo escapes spaces, tabs, newlines, and backslashes.
        escaped = str(path).replace("\\", "\\134").replace(" ", "\\040")
        metadata = path.stat()
        identity = len(self.fixture_mounts) + 2
        self.fixture_mounts[(metadata.st_dev, metadata.st_ino)] = identity
        with self.mounts.open("a") as stream:
            stream.write(f"{identity} 1 0:2 {root} {escaped} rw - {kind} fixture rw\n")

    def test_completed_job_only_removes_allowlisted_contents_and_is_idempotent(self):
        self.assertIn("completed", self.run_cleanup())
        for path in (self.workspace.parent, self.work / "_actions", self.work / "_tool"):
            self.assertTrue(path.is_dir())
            self.assertEqual(list(path.iterdir()), [])
        self.assertFalse((self.work / "_temp/build.tmp").exists())
        self.assert_preserved()
        self.run_cleanup()
        self.assert_preserved()

    def test_missing_or_malformed_context_fails_closed(self):
        for variable, value in (
            ("GITHUB_WORKSPACE", ""), ("GITHUB_WORKSPACE", "/"),
            ("GITHUB_WORKSPACE", str(self.work)),
            ("GITHUB_WORKSPACE", str(self.home)),
            ("GITHUB_WORKSPACE", str(self.work / "widgets/../other/other")),
            ("GITHUB_WORKSPACE", str(self.workspace) + "/"),
            ("GITHUB_REPOSITORY", "example/../widgets"),
            ("RUNNER_TEMP", str(self.home)), ("RUNNER_NAME", "other-runner"),
            ("GITHUB_RUN_ID", ""), ("GITHUB_RUN_ATTEMPT", "0"), ("GITHUB_JOB", ""),
        ):
            with self.subTest(variable=variable, value=value), mock.patch.dict(self.env, {variable: value}):
                self.assertIn("skipped", self.run_cleanup())
                self.assert_checkout_untouched()

    def test_missing_bad_or_non_ephemeral_runner_configuration_fails_closed(self):
        for content in ("", "not json", "[]", "{}", json.dumps(dict(self.settings, Ephemeral="False")), json.dumps(dict(self.settings, Ephemeral=False)), json.dumps(dict(self.settings, Ephemeral="yes")), json.dumps(dict(self.settings, WorkFolder="../_work")), json.dumps(dict(self.settings, AgentName="other"))):
            with self.subTest(content=content):
                self.config.write_text(content)
                self.assertIn("skipped", self.run_cleanup())
                self.assert_checkout_untouched()
        self.config.unlink()
        self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()

    def test_production_runner_configuration_shape_is_accepted(self):
        self.assertEqual(self.settings["Ephemeral"], "True")
        self.assertIn("completed", self.run_cleanup())
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_lowercase_boolean_runner_configuration_is_also_accepted(self):
        self.settings = {"agentName": self.env["RUNNER_NAME"], "workFolder": "_work", "ephemeral": True}
        self.write_settings()
        self.kept[self.config] = self.config.read_bytes()
        self.assertIn("completed", self.run_cleanup())
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_symlinked_config_is_not_read(self):
        outside = Path(self.directory.name) / "config"
        self.config.rename(outside)
        self.config.symlink_to(outside)
        self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()

    def test_symlinked_workspace_or_parent_fails_closed(self):
        for path in (self.workspace, self.workspace.parent, self.work, self.home):
            with self.subTest(path=path):
                original = path.with_name(path.name + "-real")
                path.rename(original)
                path.symlink_to(original, target_is_directory=True)
                self.assertIn("skipped", self.run_cleanup())
                self.assert_checkout_untouched()
                path.unlink()
                original.rename(path)

    def test_symlink_inside_checkout_is_unlinked_without_following(self):
        (self.workspace / "outside").symlink_to(self.home, target_is_directory=True)
        (self.workspace / "dangling").symlink_to(self.home / "absent")
        self.run_cleanup()
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_symlink_cache_is_preserved_and_never_followed(self):
        import shutil
        cache = self.work / "_actions"
        shutil.rmtree(cache)
        cache.symlink_to(self.home / ".cache", target_is_directory=True)
        self.assertIn("partial", self.run_cleanup())
        self.assertTrue(cache.is_symlink())
        self.assert_preserved()

    def test_persistent_cache_mount_is_preserved(self):
        self.add_mount(self.work / "_tool")
        self.assertIn("partial", self.run_cleanup())
        self.assertTrue((self.work / "_tool/python/bin/python").is_file())
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_tmpfs_cache_mounts_are_emptied_but_kept_mounted(self):
        for name in ("_actions", "_temp", "_tool"):
            self.add_mount(self.work / name, "tmpfs")
        self.assertIn("completed", self.run_cleanup())
        self.assertEqual(list((self.work / "_tool").iterdir()), [])
        self.assert_preserved()

    def test_tmpfs_bind_of_shared_subtree_is_preserved(self):
        for name in ("_actions", "_temp"):
            self.add_mount(self.work / name, "tmpfs")
        self.add_mount(self.work / "_tool", "tmpfs", root="/shared/subtree")
        self.assertIn("partial", self.run_cleanup())
        self.assertTrue((self.work / "_tool/python/bin/python").is_file())
        self.assertFalse((self.work / "_actions/action/index.js").exists())
        self.assert_preserved()

    def test_directory_replaced_between_stat_and_open_is_preserved(self):
        original_open = self.prune.os.open
        raced = False

        def replace_on_open(path, flags, *args, **kwargs):
            nonlocal raced
            if path == "build" and kwargs.get("dir_fd") is not None and not raced:
                raced = True
                (self.workspace / "build").rename(self.workspace / "build-old")
                (self.workspace / "build").mkdir()
                (self.workspace / "build/newcomer").write_text("replacement")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(self.prune.os, "open", side_effect=replace_on_open):
            self.assertIn("partial", self.run_cleanup())
        self.assertTrue(raced)
        self.assertEqual((self.workspace / "build/newcomer").read_text(), "replacement")
        self.assert_preserved()

    def test_nested_mount_is_preserved_including_same_device_bind_mount(self):
        mounted = self.workspace / "build/persistent data"
        mounted.mkdir()
        (mounted / "precious").write_text("persistent")
        self.add_mount(mounted)
        self.assertIn("partial", self.run_cleanup())
        self.assertEqual((mounted / "precious").read_text(), "persistent")
        self.assertFalse((self.workspace / "build/object").exists())
        self.assert_preserved()

    def test_renamed_nested_mount_retains_its_identity_and_contents(self):
        mounted = self.workspace / "build/persistent"
        mounted.mkdir()
        (mounted / "precious").write_text("persistent")
        self.add_mount(mounted)
        original = self.prune.mount_points

        def snapshot_then_rename():
            mounts = original()
            (self.workspace / "build").rename(self.workspace / "moved")
            return mounts

        with mock.patch.object(self.prune, "mount_points", side_effect=snapshot_then_rename):
            self.assertIn("partial", self.run_cleanup())
        self.assertEqual((self.workspace / "moved/persistent/precious").read_text(), "persistent")
        self.assert_preserved()

    def test_new_mount_after_snapshot_is_preserved(self):
        original = self.prune.mount_points

        def snapshot_then_mount():
            mounts = original()
            self.add_mount(self.workspace / "build")
            self.add_mount(self.work / "_actions", "tmpfs")
            return mounts

        with mock.patch.object(self.prune, "mount_points", side_effect=snapshot_then_mount):
            self.assertIn("partial", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assertTrue((self.work / "_actions/action/index.js").exists())
        self.assert_preserved()

    def test_missing_descriptor_mount_identity_fails_closed(self):
        with mock.patch.object(self, "fixture_mount_id", side_effect=ValueError):
            self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_kernel_descriptor_mount_identity_parser(self):
        with self.prune.open_directory(self.work) as fd:
            self.assertGreater(self.prune.mount_id(fd), 0)
            for content in ("", "mnt_id: nonsense", "mnt_id: 0"):
                with self.subTest(content=content), mock.patch.object(Path, "read_text", return_value=content):
                    with self.assertRaises(ValueError):
                        self.prune.mount_id(fd)

    def test_mount_at_checkout_or_its_parent_is_preserved(self):
        for path in (self.workspace, self.workspace.parent):
            with self.subTest(path=path):
                self.add_mount(path)
                self.assertIn("partial", self.run_cleanup())
                self.assert_checkout_untouched()

    def test_workspace_root_mount_is_allowed(self):
        self.add_mount(self.work)
        self.assertIn("completed", self.run_cleanup())
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_unknown_mount_table_fails_closed(self):
        self.mounts.write_text("bad mount table")
        self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()
        self.mounts.unlink()
        self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()

    def test_nonstandard_tool_cache_is_left_alone(self):
        self.env["RUNNER_TOOL_CACHE"] = str(self.home / "wheelhouse")
        self.assertIn("partial", self.run_cleanup())
        self.assertTrue((self.work / "_tool/python/bin/python").is_file())
        self.assert_preserved()

    def test_unreadable_file_does_not_prevent_deleting_directory_entry(self):
        secret = self.workspace / "mode000"
        secret.write_text("transient")
        secret.chmod(0)
        self.run_cleanup()
        self.assertFalse(secret.exists())
        self.assert_preserved()

    def test_permission_error_is_warned_without_chmod_or_job_failure(self):
        with mock.patch.object(self.prune.os, "unlink", side_effect=PermissionError):
            self.assertIn("partial", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_directory_swapped_to_symlink_during_walk_is_not_followed(self):
        original_open = self.prune.os.open
        raced = False

        def swap_on_open(path, flags, *args, **kwargs):
            nonlocal raced
            if path == "build" and kwargs.get("dir_fd") is not None and not raced:
                raced = True
                (self.workspace / "build").rename(self.workspace / "build-old")
                (self.workspace / "build").symlink_to(self.home, target_is_directory=True)
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(self.prune.os, "open", side_effect=swap_on_open):
            self.assertIn("partial", self.run_cleanup())
        self.assertTrue(raced)
        self.assert_preserved()

    def run_fixture_shell(self):
        # Materialize only the installation location in the shell wrapper. The
        # driver imports the unmodified production implementation and assigns
        # test constants, so no production environment override is introduced.
        install = Path(self.directory.name) / "libexec"
        install.mkdir()
        driver = install / "runner-post-job-workspace-prune.py"
        driver.write_text(textwrap.dedent(f"""
            import importlib.util
            from pathlib import Path
            spec = importlib.util.spec_from_file_location("prune", {str(SCRIPT)!r})
            prune = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(prune)
            prune.WORK_ROOT = Path({str(self.work)!r})
            raise SystemExit(prune.main())
        """))
        shell = install / "hook.sh"
        shell.write_text((ROOT / "docker/runner-post-job-workspace-prune.sh").read_text().replace("/usr/local/libexec/ezgha", str(install)))
        return subprocess.run(["/bin/bash", "-e", str(shell)], env=self.env, cwd=self.workspace, capture_output=True, text=True, timeout=10)

    def test_shell_hook_runs_real_cleanup_with_fixture_installation(self):
        result = self.run_fixture_shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("completed", result.stdout)
        self.assertEqual(list(self.workspace.parent.iterdir()), [])
        self.assert_preserved()

    def test_fifo_runner_configuration_is_rejected_without_blocking(self):
        self.config.unlink()
        os.mkfifo(self.config)
        # The subprocess timeout also bounds the regression if O_NONBLOCK is
        # accidentally removed; never leave the test suite hanging on a FIFO.
        result = self.run_fixture_shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipped", result.stdout)
        self.assert_checkout_untouched()

    def test_unverified_configuration_owner_fails_closed(self):
        with mock.patch.object(self.prune.os, "getuid", return_value=os.getuid() + 1):
            self.assertIn("skipped", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_new_mount_at_pipeline_root_after_snapshot_is_preserved(self):
        original = self.prune.mount_points

        def snapshot_then_mount():
            mounts = original()
            self.add_mount(self.workspace.parent)
            return mounts

        with mock.patch.object(self.prune, "mount_points", side_effect=snapshot_then_mount):
            self.assertIn("partial", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_missing_child_mount_identity_preserves_child(self):
        original = self.fixture_mount_id

        def missing_child_identity(fd):
            if Path(os.readlink(f"/proc/self/fd/{fd}")) == self.workspace / "build":
                raise ValueError("missing child mount identity")
            return original(fd)

        with mock.patch.object(self, "fixture_mount_id", side_effect=missing_child_identity):
            self.assertIn("partial", self.run_cleanup())
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_shell_timeout_reports_partial_and_does_not_fail_job(self):
        fake_timeout = Path(self.directory.name) / "timeout"
        fake_timeout.write_text("#!/bin/bash\nexit 124\n")
        fake_timeout.chmod(0o755)
        shell = Path(self.directory.name) / "hook.sh"
        shell.write_text((ROOT / "docker/runner-post-job-workspace-prune.sh").read_text().replace("/usr/bin/timeout", str(fake_timeout)))
        result = subprocess.run(["/bin/bash", "-e", str(shell)], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exceeded its time budget", result.stdout)
        self.assert_checkout_untouched()
        self.assert_preserved()

    def test_image_wires_supported_shell_hook_outside_runner_directory(self):
        dockerfile = (ROOT / "Dockerfile.runner").read_text()
        prefix = "/usr/local/libexec/ezgha"
        self.assertIn(f"COPY docker/runner-post-job-workspace-prune.py {prefix}/", dockerfile)
        self.assertIn(f"COPY docker/runner-post-job-workspace-prune.sh {prefix}/", dockerfile)
        self.assertIn(f"ENV ACTIONS_RUNNER_HOOK_JOB_COMPLETED={prefix}/runner-post-job-workspace-prune.sh", dockerfile)
        shell = ROOT / "docker/runner-post-job-workspace-prune.sh"
        subprocess.run(["bash", "-n", str(shell)], check=True)
        self.assertIn("/usr/bin/timeout", shell.read_text())
        self.assertIn("/usr/bin/python3 -I", shell.read_text())
        self.assertIn("runner_post_job_workspace_prune_test.py", (ROOT / ".github/workflows/ci.yml").read_text())


if __name__ == "__main__":
    unittest.main()
