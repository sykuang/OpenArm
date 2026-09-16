"""Offline YAML wiring checks, not a substitute for Azure's pipeline preview."""
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
