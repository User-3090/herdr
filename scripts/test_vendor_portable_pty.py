from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


class VendorPortablePtyTests(unittest.TestCase):
    def test_vendored_tree_contains_required_upstream_files(self) -> None:
        root = Path(__file__).resolve().parent.parent / "vendor" / "portable-pty"
        required = [
            root / "Cargo.toml",
            root / "LICENSE.md",
            root / "src" / "lib.rs",
            root / "src" / "win" / "psuedocon.rs",
        ]

        missing = [str(path.relative_to(root)) for path in required if not path.exists()]
        self.assertEqual(missing, [])

    def test_cargo_patch_points_at_vendored_tree(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        cargo_toml = (project_root / "Cargo.toml").read_text()

        self.assertIn('portable-pty = "=0.9.0"', cargo_toml)
        self.assertIn("[patch.crates-io]", cargo_toml)
        self.assertIn('portable-pty = { path = "vendor/portable-pty" }', cargo_toml)

    def test_cargo_metadata_resolves_portable_pty_to_vendored_tree(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        result = subprocess.run(
            ["cargo", "metadata", "--locked", "--format-version", "1"],
            cwd=project_root,
            text=True,
            capture_output=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"cargo metadata failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

        metadata = json.loads(result.stdout)
        packages = [
            package
            for package in metadata["packages"]
            if package["name"] == "portable-pty" and package["version"] == "0.9.0"
        ]
        self.assertEqual(len(packages), 1)

        manifest_path = Path(packages[0]["manifest_path"]).resolve()
        expected = (project_root / "vendor" / "portable-pty" / "Cargo.toml").resolve()
        self.assertEqual(manifest_path, expected)

    def test_local_vendor_patches_are_listed_in_patch_index(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        index = project_root / "vendor" / "portable-pty.patches.md"
        patch_dir = project_root / "vendor" / "patches" / "portable-pty"
        patches = sorted(patch_dir.glob("*.patch"))

        if not patches:
            return

        self.assertTrue(index.exists())
        text = index.read_text()
        missing = [
            path.relative_to(project_root).as_posix()
            for path in patches
            if path.relative_to(project_root).as_posix() not in text
        ]
        self.assertEqual(missing, [])

    def test_listed_local_vendor_patches_exist(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        index = project_root / "vendor" / "portable-pty.patches.md"
        text = index.read_text()
        listed = [
            line.split("`", 2)[1]
            for line in text.splitlines()
            if line.startswith("patch: `vendor/patches/portable-pty/")
        ]

        missing = [path for path in listed if not (project_root / path).exists()]
        self.assertEqual(missing, [])

    def test_local_vendor_patches_are_applied_to_vendored_tree(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        patch_dir = project_root / "vendor" / "patches" / "portable-pty"

        for patch in sorted(patch_dir.glob("*.patch")):
            result = subprocess.run(
                ["git", "apply", "--check", "--reverse", str(patch.relative_to(project_root))],
                cwd=project_root,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"{patch.relative_to(project_root)} is not applied cleanly:\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}",
            )

    def test_windows_conpty_loader_uses_only_controlled_app_local_dll(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        source = project_root / "vendor" / "portable-pty" / "src" / "win" / "psuedocon.rs"
        text = source.read_text()

        self.assertIn('ConPtyFuncs::open(Path::new("kernel32.dll"))', text)
        self.assertIn("std::env::current_exe()", text)
        self.assertIn('exe_dir.join("conpty.dll")', text)
        self.assertIn('exe_dir.join("OpenConsole.exe")', text)
        self.assertIn("ConPtyFuncs::open(&dll)", text)
        self.assertNotIn('Path::new("conpty.dll")', text)

    def test_windows_conpty_package_defaults_and_nightly_resolver(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        script = (project_root / "scripts" / "prepare_windows_conpty.ps1").read_text()
        resolver_path = project_root / "scripts" / "resolve_latest_windows_conpty.ps1"
        resolver = resolver_path.read_text()

        self.assertIn('[string] $PackageVersion = "1.24.260710001"', script)
        self.assertIn(
            '[string] $PackageSha256 = "175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e"',
            script,
        )
        self.assertIn('Join-Path $destinationPath "conpty.dll"', script)
        self.assertIn('Join-Path $destinationPath "OpenConsole.exe"', script)
        self.assertTrue(resolver_path.is_file())
        self.assertIn("https://api.nuget.org/v3-flatcontainer", resolver)
        self.assertIn("IncludePrerelease", resolver)
        self.assertIn("& dotnet nuget verify", resolver)
        self.assertIn("runtimes\\win-x64\\native\\conpty.dll", resolver)
        self.assertIn("build\\native\\runtimes\\x64\\OpenConsole.exe", resolver)
        self.assertTrue(
            (project_root / "vendor" / "licenses" / "Microsoft.Windows.Console.ConPTY.LICENSE.txt").is_file()
        )


if __name__ == "__main__":
    unittest.main()
