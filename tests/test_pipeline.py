"""Offline Azure Pipeline and GitHub Actions wiring checks, not cloud execution."""
from pathlib import Path
import json
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parent.parent


class UniqueKeysLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueKeysLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping
)


def load(path):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueKeysLoader)


class PipelineChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline = load(ROOT / "azure-pipelines.yml")
        cls.ci = load(ROOT / "azure-pipelines-ci.yml")
        cls.native = load(ROOT / "native-stage.yml")
        cls.stages = {
            item.get("stage", item.get("parameters", {}).get("stageName")): item
            for item in cls.pipeline["stages"]
        }

    def test_queue_only_and_external_actions_opt_in(self):
        self.assertEqual(self.pipeline["trigger"], "none")
        self.assertEqual(self.pipeline["pr"], "none")
        parameters = {item["name"]: item for item in self.pipeline["parameters"]}
        for name in ("enableAgent", "enableHumanHandoff", "enableTeams", "prepareUpstreamDraft"):
            self.assertIs(parameters[name]["default"], False)
        self.assertEqual(parameters["maxAttempts"]["values"], [0, 1, 2, 3])

    def test_dependency_graph_and_artifact_wiring(self):
        seen = set()
        for name, item in self.stages.items():
            dependencies = item.get("dependsOn", item.get("parameters", {}).get("dependsOn", []))
            if isinstance(dependencies, str):
                dependencies = [dependencies]
            self.assertTrue(set(dependencies) <= seen, f"Invalid dependencies: {name}")
            seen.add(name)
        self.assertEqual(self.stages["Native"]["parameters"]["outputArtifact"], "openarm-native")
        self.assertEqual(self.stages["NativeResume"]["parameters"]["inputArtifact"], "openarm-resume-input")
        self.assertEqual(self.stages["NativeResume"]["parameters"]["outputArtifact"], "openarm-resumed")
        self.assertIn("dependencies.Native.outputs['Validate.run.route']", self.stages["Handoff"]["condition"])
        self.assertEqual(self.stages["ResumeInput"]["dependsOn"], "Human")

    def test_native_pool_and_evidence_always_published(self):
        job = self.native["stages"][0]["jobs"][0]
        self.assertEqual(job["job"], "Validate")
        self.assertIn("OpenArm.NativeArm64 -equals true", job["pool"]["demands"])
        self.assertIn("Agent.OS -equals Windows_NT", job["pool"]["demands"])
        self.assertEqual(job["steps"][-1]["condition"], "always()")
        task = next(step for step in job["steps"] if step.get("name") == "run")
        self.assertNotIn("SYSTEM_ACCESSTOKEN", task["env"])
        self.assertNotIn("OPENARM_TEAMS_BRIDGE_URL", task["env"])
        self.assertIn("${{ if parameters.enableAgent }}", task["env"])

    def test_human_gates_are_agentless_bounded_and_reject_timeout(self):
        for name in ("Human", "ResumeApproval", "UpstreamReview"):
            job = self.stages[name]["jobs"][0]
            self.assertEqual(job["pool"], "server")
            task = job["steps"][0]
            self.assertEqual(task["task"], "ManualValidation@1")
            self.assertGreater(job["timeoutInMinutes"], task["timeoutInMinutes"])
            self.assertEqual(task["inputs"]["onTimeout"], "reject")
            self.assertIs(task["inputs"]["allowApproversToApproveTheirOwnRuns"], False)
            self.assertEqual(task["inputs"]["approvers"], "${{ parameters.approvers }}")

    def test_resume_approval_binds_trusted_snapshot_before_execution(self):
        self.assertEqual(self.stages["ResumeApproval"]["dependsOn"], "ResumeInput")
        resumed = self.stages["NativeResume"]["parameters"]
        self.assertEqual(resumed["dependsOn"], ["ResumeInput", "ResumeApproval"])
        self.assertIs(resumed["requireResumeApproval"], True)
        freeze_steps = self.stages["ResumeInput"]["jobs"][0]["steps"]
        snapshot = next(step for step in freeze_steps if step.get("name") == "snapshot")
        self.assertEqual(snapshot["inputs"]["filePath"], r"scripts\Resume-Target.ps1")
        expected = "$[ stageDependencies.ResumeInput.Resume.outputs['snapshot.bundleDigest'] ]"
        self.assertEqual(self.stages["ResumeApproval"]["variables"]["bundleDigest"], expected)
        native_variables = self.native["stages"][0]["variables"]["${{ if parameters.requireResumeApproval }}"]
        self.assertEqual(native_variables["approvedResumeDigest"], expected)
        native_task = next(step for step in self.native["stages"][0]["jobs"][0]["steps"] if step.get("name") == "run")
        self.assertEqual(
            native_task["env"]["${{ if parameters.requireResumeApproval }}"]["OPENARM_APPROVED_RESUME_DIGEST"],
            "$(approvedResumeDigest)",
        )
        instructions = self.stages["ResumeApproval"]["jobs"][0]["steps"][0]["inputs"]["instructions"]
        for binding in ("$(bundleDigest)", "$(sourceCommit)", "$(commentId)", "$(commentVersion)"):
            self.assertIn(binding, instructions)

    def test_coordination_is_serialized_and_draft_requires_review(self):
        for name in ("Handoff", "Report"):
            stage = self.stages[name]
            self.assertEqual(stage["lockBehavior"], "sequential")
            self.assertEqual(stage["jobs"][0]["environment"], "openarm-coordination")
        self.assertIn("UpstreamReview", self.stages["Draft"]["dependsOn"])
        self.assertIn("Finish", self.stages["UpstreamReview"]["dependsOn"])
        final_code = self.stages["Finish"]["jobs"][0]["steps"][-1]["pwsh"]
        self.assertIn("throw 'OpenArm is not natively validated", final_code)
        self.assertIn("$env:REPORT_RESULT -eq 'Succeeded'", final_code)

    def test_every_referenced_script_exists(self):
        def visit(value):
            if isinstance(value, dict):
                if "filePath" in value:
                    self.assertTrue((ROOT / Path(value["filePath"])).is_file(), value["filePath"])
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(self.pipeline)
        visit(self.native)
        visit(self.ci)

    def test_repository_ci_is_separate_hosted_and_secret_free(self):
        self.assertEqual(self.ci["trigger"]["branches"]["include"], ["main"])
        self.assertEqual(self.ci["pr"]["branches"]["include"], ["main"])
        self.assertEqual(len(self.ci["jobs"]), 1)
        job = self.ci["jobs"][0]
        self.assertEqual(job["pool"], {"vmImage": "windows-latest"})
        self.assertLessEqual(job["timeoutInMinutes"], 30)
        steps = job["steps"]
        checkout = next(step for step in steps if step.get("checkout") == "self")
        self.assertIs(checkout["persistCredentials"], False)
        task = next(step for step in steps if step.get("task") == "PowerShell@2")
        self.assertEqual(task["inputs"]["filePath"], r"scripts\Test-Project.ps1")
        self.assertEqual(steps[-1]["condition"], "always()")
        self.assertEqual(steps[-1]["artifact"], "repository-validation")
        text = (ROOT / "azure-pipelines-ci.yml").read_text(encoding="utf-8").lower()
        for forbidden in ("token", "secret", "bridge", "manualvalidation", "native-stage", "invokenativeloop", "environment:", "group:"):
            self.assertNotIn(forbidden, text)

    def test_github_trial_is_manual_opt_in_and_token_is_step_scoped(self):
        self.assertFalse((ROOT / "azure-pipelines-github-trial.yml").exists())
        trial = load(ROOT / ".github" / "workflows" / "github-trial.yml")
        self.assertEqual(set(trial["on"]), {"workflow_dispatch"})
        parameters = trial["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(set(parameters), {"sourceRepositoryUrl", "forkOwner", "createForkPullRequest", "createHumanHelpIssue"})
        self.assertEqual(parameters["sourceRepositoryUrl"]["default"], "")
        self.assertEqual(parameters["forkOwner"]["default"], "")
        self.assertIs(parameters["createForkPullRequest"]["default"], False)
        self.assertEqual(parameters["createForkPullRequest"]["type"], "boolean")
        for name in ("sourceRepositoryUrl", "forkOwner"):
            self.assertEqual(parameters[name]["type"], "string")
            self.assertIs(parameters[name]["required"], False)
        self.assertEqual(trial["permissions"], {"contents": "read"})
        self.assertNotIn("env", trial)
        self.assertEqual(set(trial["jobs"]), {"trial", "human-help"})
        job = trial["jobs"]["trial"]
        self.assertEqual(job["runs-on"], "windows-11-arm")
        self.assertLessEqual(job["timeout-minutes"], 20)
        self.assertEqual(job["defaults"]["run"]["shell"], "pwsh")
        self.assertNotIn("env", job)
        self.assertNotIn("permissions", job)
        steps = job["steps"]
        self.assertEqual(len(steps), 7)
        self.assertRegex(steps[0]["uses"], r"^actions/checkout@[0-9a-f]{40}$")
        self.assertEqual(steps[0]["with"], {"persist-credentials": False})
        discover, manual = steps[4:6]
        self.assertEqual(discover["if"], "${{ inputs.sourceRepositoryUrl == '' }}")
        self.assertEqual(manual["if"], "${{ inputs.sourceRepositoryUrl != '' }}")
        for step, script in ((discover, "Find-Arm64Candidate.ps1"), (manual, "Invoke-GitHubTrial.ps1")):
            self.assertTrue((ROOT / "scripts" / script).is_file())
            self.assertEqual(step["run"].strip(),
                             f'.\\scripts\\{script} -Output "$env:RUNNER_TEMP\\github-trial" -OutputRoot "$env:RUNNER_TEMP"')
            self.assertNotIn("${{", step["run"])
            self.assertNotIn("continue-on-error", step)
        self.assertEqual(discover["env"], {
            "OPENARM_GITHUB_DISCOVERY_TOKEN": "${{ secrets.OPENARM_GITHUB_DISCOVERY_TOKEN }}",
            "OPENARM_GITHUB_TRIAL_CREATE": "${{ inputs.createForkPullRequest }}",
        })
        self.assertEqual(manual["env"], {
            "OPENARM_GITHUB_TOKEN": "${{ secrets.OPENARM_GITHUB_TOKEN }}",
            "OPENARM_GITHUB_SOURCE": "${{ inputs.sourceRepositoryUrl }}",
            "OPENARM_GITHUB_FORK_OWNER": "${{ inputs.forkOwner }}",
            "OPENARM_GITHUB_TRIAL_CREATE": "${{ inputs.createForkPullRequest }}",
            "OPENARM_GITHUB_TRIAL_ID": "${{ github.repository_id }}-${{ github.run_id }}",
        })
        upload = steps[-1]
        self.assertRegex(upload["uses"], r"^actions/upload-artifact@[0-9a-f]{40}$")
        self.assertEqual(upload["if"], "${{ always() }}")
        self.assertEqual(upload["with"], {
            "name": "github-trial-${{ github.run_id }}-${{ github.run_attempt }}",
            "path": r"${{ runner.temp }}\github-trial",
            "if-no-files-found": "error",
            "retention-days": 7,
        })

    def test_trial_installs_native_copilot_without_invoking_ai(self):
        workflow = load(ROOT / ".github" / "workflows" / "github-trial.yml")
        steps = workflow["jobs"]["trial"]["steps"]
        guard, setup, install = steps[1:4]
        self.assertNotIn("if", guard)
        self.assertNotIn("if", setup)
        self.assertNotIn("if", install)
        self.assertRegex(setup["uses"], r"^actions/setup-node@[0-9a-f]{40}$")
        self.assertEqual(setup["with"], {"node-version": "24", "architecture": "arm64"})
        code = install["run"]
        self.assertIn("process.arch !== 'arm64'", code)
        self.assertIn("process.platform !== 'win32'", code)
        self.assertIn("npm install --global @github/copilot@1.0.85 --no-audit --no-fund", code)
        self.assertIn("require.resolve('@github/copilot-win32-arm64'", code)
        self.assertIn(". .\\scripts\\Common.ps1", code)
        self.assertIn("(Get-PeMachine $copilotExe) -ne 0xAA64", code)
        self.assertIn("& $copilotExe --version", code)
        self.assertIn("$env:GITHUB_PATH", code)
        self.assertGreaterEqual(code.count("if ($LASTEXITCODE -ne 0)"), 5)
        for step in (guard, setup, install):
            self.assertNotIn("env", step)
            self.assertNotIn("continue-on-error", step)
            self.assertNotIn("${{", step.get("run", ""))
        self.assertNotIn("copilot-requests", str(workflow["permissions"]))
        self.assertNotIn(" -p ", code)
        self.assertNotIn("--prompt", code)

    def test_trial_host_guard_checks_actual_os_and_process(self):
        workflow = load(ROOT / ".github" / "workflows" / "github-trial.yml")
        code = workflow["jobs"]["trial"]["steps"][1]["run"]
        self.assertIn("[Runtime.InteropServices.RuntimeInformation]::OSArchitecture", code)
        self.assertIn("[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture", code)
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-Command", code],
            capture_output=True, text=True, timeout=30, cwd=ROOT,
        )
        host = json.loads(result.stdout.strip())
        native = host["isWindows"] and host["osArchitecture"] == "Arm64" and host["processArchitecture"] == "Arm64"
        self.assertEqual(result.returncode == 0, native, result.stdout + result.stderr)
        if not native:
            self.assertIn("native Windows Arm64", result.stderr)

    def test_human_help_is_scoped_gated_and_preserves_failure(self):
        workflow = load(ROOT / ".github" / "workflows" / "github-trial.yml")
        toggle = workflow["on"]["workflow_dispatch"]["inputs"]["createHumanHelpIssue"]
        self.assertEqual(toggle["type"], "boolean")
        self.assertIs(toggle["default"], True)
        self.assertIs(toggle["required"], False)
        trial = workflow["jobs"]["trial"]
        self.assertNotIn("continue-on-error", trial)
        job = workflow["jobs"]["human-help"]
        self.assertEqual(job["needs"], "trial")
        self.assertEqual(job["if"], "${{ always() && !cancelled() && inputs.createHumanHelpIssue && (needs.trial.result == 'failure' || (needs.trial.result == 'success' && inputs.sourceRepositoryUrl == '')) }}")
        self.assertEqual(job["permissions"], {"issues": "write"})
        self.assertEqual(job["runs-on"], "windows-latest")
        self.assertLessEqual(job["timeout-minutes"], 5)
        self.assertEqual(job["concurrency"], {
            "group": "openarm-human-help-${{ github.repository_id }}-${{ github.run_id }}",
            "cancel-in-progress": False,
        })
        self.assertNotIn("continue-on-error", job)
        self.assertNotIn("env", job)
        self.assertEqual(len(job["steps"]), 1)
        step = job["steps"][0]
        self.assertRegex(step["uses"], r"^actions/github-script@[0-9a-f]{40}$")
        self.assertEqual(step["with"]["github-token"], "${{ github.token }}")
        self.assertEqual(step["with"]["retries"], 0)
        self.assertEqual(step["env"], {
            "OPENARM_RUN_ID": "${{ github.run_id }}",
            "OPENARM_TRIAL_RESULT": "${{ needs.trial.result }}",
            "OPENARM_DISCOVERY": "${{ inputs.sourceRepositoryUrl == '' }}",
        })
        self.assertNotIn("${{", step["with"]["script"])
        self.assertNotIn("secrets.", str(job))

    def test_human_help_issue_behavior(self):
        workflow = load(ROOT / ".github" / "workflows" / "github-trial.yml")
        script = workflow["jobs"]["human-help"]["steps"][0]["with"]["script"]
        result = subprocess.run(
            ["node", str(ROOT / "tests" / "test_human_help.cjs")],
            input=script, capture_output=True, text=True, timeout=30, cwd=ROOT,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("20 human-help issue checks passed.", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
