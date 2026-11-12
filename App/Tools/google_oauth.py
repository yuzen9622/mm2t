"""Local Google Desktop OAuth configuration. Never accepts a secret in argv or the environment."""
import argparse
import getpass
import os
import pathlib
import plistlib
import stat
import subprocess
import sys
import tempfile
import warnings

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = pathlib.Path("App/Config/GoogleOAuth.local.plist")
CLIENT_ID = "MM2TGoogleClientID"
CLIENT_SECRET = "MM2TGoogleClientSecret"


class ConfigurationError(Exception):
    """Only static, credential-free messages may cross this boundary."""


def configured(value):
    return (isinstance(value, str) and bool(value.strip())
            and not value.strip().startswith("REPLACE_") and "$(" not in value)


def require_ignored_config(root):
    ignored = subprocess.run(["git", "check-ignore", "-q", str(CONFIG)], cwd=root, capture_output=True, check=False)
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", str(CONFIG)], cwd=root, capture_output=True, check=False)
    if ignored.returncode != 0 or tracked.returncode != 1:
        raise ConfigurationError("The local OAuth configuration must be untracked and ignored by Git.")


def source_info(root):
    with (root / "App/Config/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not configured(info.get(CLIENT_ID)):
        raise ConfigurationError("Set the Google Desktop client ID in App/Config/Info.plist first.")
    return info


def write_private(path, fields):
    # Atomic replacement cannot follow a pre-existing destination symlink. The new
    # file is private from creation, including while it is being written.
    if path.is_symlink():
        raise ConfigurationError("Refusing a symbolic-link configuration path.")
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".google-oauth-")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(fields, stream)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_private(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) & 0o077):
            raise ConfigurationError("Local OAuth configuration must be owned by you with mode 0600.")
        fields = plistlib.load(stream)
    if not isinstance(fields, dict) or not configured(fields.get(CLIENT_SECRET)):
        raise ConfigurationError("Local OAuth configuration is missing a client secret.")
    return fields


def configure(root):
    if not sys.stdin.isatty():
        raise ConfigurationError("Run configure yourself in an interactive Terminal; hidden input is required.")
    require_ignored_config(root)
    info = source_info(root)
    print("This Desktop client value will be stored locally and included in your App bundle.")
    print("It is not confidential after distribution and does not replace PKCE or state validation.")
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        secret = getpass.getpass("Google Desktop client secret (hidden): ").strip()
    if not configured(secret):
        raise ConfigurationError("No valid value entered; configuration was not changed.")
    write_private(root / CONFIG, {CLIENT_ID: info[CLIENT_ID], CLIENT_SECRET: secret})
    print("Saved the ignored local configuration with mode 0600. No credential value was printed.")


def build(root, team, identity="Apple Development", runner=subprocess.run):
    require_ignored_config(root)
    fields = read_private(root / CONFIG)
    # Read the current source at build time, preserving concurrent icon changes.
    info = source_info(root)
    if fields.get(CLIENT_ID) != info[CLIENT_ID]:
        raise ConfigurationError("The Google client ID changed. Run configure again for the matching Desktop client.")
    info[CLIENT_SECRET] = fields[CLIENT_SECRET]
    directory = root / ".build/google-oauth"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(dir=directory, prefix="build-") as temporary:
        merged = pathlib.Path(temporary) / "Info.plist"
        write_private(merged, info)
        command = [
            "xcodebuild", "-project", "App/MM2T.xcodeproj", "-scheme", "mm2t",
            "-configuration", "Debug", "-derivedDataPath", ".build/xcode",
            "-disableAutomaticPackageResolution", "build", "-quiet",
            f"INFOPLIST_FILE={merged}", f"CODE_SIGN_IDENTITY={identity}",
            f"DEVELOPMENT_TEAM={team}",
        ]
        # Only the path is passed to Xcode, never a secret value or secret build setting.
        return runner(command, cwd=root, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("configure", help="Privately enter the existing Desktop client secret yourself")
    build_parser = commands.add_parser("build", help="Build locally; does not open, restart, install or upload the App")
    build_parser.add_argument("--team", required=True)
    build_parser.add_argument("--identity", default="Apple Development")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            configure(ROOT)
            return 0
        result = build(ROOT, args.team, args.identity)
        if result == 0:
            print("Built .build/xcode/Build/Products/Debug/mm2t.app. The running App was not restarted.")
        return result
    except ConfigurationError as error:
        print(str(error), file=sys.stderr)
    except Exception:
        # Never echo raw input, plist parser details, or an exception carrying credentials.
        print("Local OAuth configuration/build could not be read or prepared. Check the file and permissions locally.", file=sys.stderr)
    except (EOFError, KeyboardInterrupt):
        print("Cancelled; no credential value was printed.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
