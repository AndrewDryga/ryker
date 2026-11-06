"""Cold model downloads coincided with two controller-host failures in November 2026."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("model_services", Path(__file__).with_name("model_services.py"))
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)


class ModelLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Dockerfile").write_text("FROM example@sha256:abc AS build\nCOPY --from=build /model /model\n")
        self.service = {"image": "ryker-whisper:local", "build": {"context": str(self.root), "dockerfile": "Dockerfile", "args": {"MODEL_SHA256": "one"}}}
        self.identity = models.fingerprint(self.service)
        self.commands = []
        self.low_space = False
        self.build_fails = False
        self.wrong_image = False

    def run_command(self, argv):
        self.commands.append(argv)
        if argv[-2:] == ["config", "--services"]:
            return "database\nryker\nwhisper\n"
        if "config" in argv:
            return json.dumps({"services": {"whisper": self.service}})
        if argv[:3] == ["docker", "image", "inspect"]:
            return self.identity or ""
        if "--prepare-build" in argv and self.low_space:
            raise RuntimeError("insufficient headroom")
        if "build" in argv:
            if self.build_fails:
                raise RuntimeError("model build failed")
            overlay = json.loads(Path(argv[argv.index("--file", argv.index("--file") + 1) + 1]).read_text())
            self.identity = "wrong" if self.wrong_image else overlay["services"]["whisper"]["build"]["labels"][models.LABEL]
        return ""

    def start(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return models.start_models(self.root / "compose.env", self.root / "compose.yml", self.run_command)

    def test_unchanged_image_runs_without_build_or_storage_cleanup(self):
        self.assertTrue(self.start())
        self.assertFalse(any("build" in c or "--prepare-build" in c for c in self.commands))
        up = next(c for c in self.commands if "up" in c)
        self.assertIn("--no-build", up)
        self.assertIn("--no-deps", up)

    def test_cold_build_waits_for_fresh_headroom_then_verifies_its_image(self):
        self.identity = None
        self.assertTrue(self.start())
        guard = next(i for i, c in enumerate(self.commands) if "--prepare-build" in c)
        build = next(i for i, c in enumerate(self.commands) if "build" in c)
        up = next(i for i, c in enumerate(self.commands) if "up" in c)
        self.assertLess(guard, build)
        self.assertLess(build, up)

    def test_no_model_download_starts_with_insufficient_storage(self):
        self.identity = None
        self.low_space = True
        self.assertFalse(self.start())
        self.assertFalse(any("build" in c or "up" in c for c in self.commands))

    def test_changed_model_arguments_need_a_qualified_build(self):
        self.service["build"]["args"]["MODEL_SHA256"] = "two"
        self.assertTrue(self.start())
        self.assertTrue(any("build" in c for c in self.commands))

    def test_changed_runtime_settings_do_not_rebuild_the_model(self):
        self.service["command"] = ["--threads", "4"]
        self.assertTrue(self.start())
        self.assertFalse(any("build" in c for c in self.commands))

    def test_failed_build_or_wrong_image_never_starts_a_replacement(self):
        for failure in ["build_fails", "wrong_image"]:
            with self.subTest(failure=failure):
                self.identity = None
                self.commands = []
                setattr(self, failure, True)
                self.assertFalse(self.start())
                self.assertFalse(any("up" in c for c in self.commands))
                setattr(self, failure, False)

    def test_build_identity_does_not_depend_on_the_temporary_release_path(self):
        with tempfile.TemporaryDirectory() as other:
            Path(other, "Dockerfile").write_bytes((self.root / "Dockerfile").read_bytes())
            service = {**self.service, "build": {**self.service["build"], "context": other}}
            self.assertEqual(models.fingerprint(self.service), models.fingerprint(service))

    def test_both_shipped_model_recipes_have_qualified_build_identities(self):
        root = Path(__file__).resolve().parent.parent
        for recipe in ["whisper", "llama"]:
            with self.subTest(recipe=recipe):
                service = {"build": {"context": str(root),
                                     "dockerfile": f"deploy/compose/models/{recipe}.Dockerfile",
                                     "args": {"MODEL_URL": "https://example.invalid/model.bin",
                                              "MODEL_SHA256": "a" * 64, "MODEL_FILE": "model.bin"}}}
                self.assertRegex(models.fingerprint(service), r"^[0-9a-f]{64}$")

    def test_unknown_local_build_inputs_are_refused_instead_of_reused(self):
        for instruction in ["COPY weights /model", "ADD weights /model",
                            "ADD https://example.invalid/model.bin /model"]:
            with self.subTest(instruction=instruction):
                self.commands = []
                (self.root / "Dockerfile").write_text("FROM example\n" + instruction + "\n")
                self.assertFalse(self.start())
                self.assertFalse(any("build" in c or "up" in c for c in self.commands))


if __name__ == "__main__":
    unittest.main()
