"""Read what a Fritzing version needs from its own source, so the build follows upstream by itself.

usage:
  python fritzing_versions.py resolve <fritzing-app clone> [ref]   prints REF (commit) and VERSION
  python fritzing_versions.py deps <fritzing-app checkout>         prints Qt range and dependency versions

ref: empty or "stable" = the newest release in upstream's release list (appdata.xml on the default
branch). Upstream does not always create a branch or tag for a release; then the build uses the last
commit that changed the release list.

Each dependency version comes from the .pri files. Versions in KNOWN have a SHA-256 or commit; for
other versions the value is empty and the build downloads them without verification (with a warning).
"""
import re
import shlex
import subprocess
import sys
from pathlib import Path

APPDATA = "org.fritzing.Fritzing.appdata.xml"

KNOWN = {
    "boost": {"85": {"tar.gz": "be0d91732d5b0cc6fbb275c7939974457e79b54d6f07ce2e3dfdd68bef883b0b",
                     "7z": "16d16b9658753117c1434e5450c5eac194957f4b6d0b390b9d07900d37c115a4"}},
    "libgit2": {"1.7.1": "a2bde63741977ca0f4ef7db2f609df320be67a08"},
    "quazip": {"1.4": "566fa496649b8cb09018b497575bb3bf2977965f"},
    "svgpp": {"1.3.1": "fda1fd889548289178261d7aa02dd5d647247f94"},
    "clipper": {"6.4.2": "a14320d82194807c4480ce59c98aa71cd4175a5156645c4e2b3edd330b930627"},
    "ngspice": {"42": {"tar.gz": "737fe3846ab2333a250dfadf1ed6ebe1860af1d8a5ff5e7803c772cc4256e50a",
                       "dll": "efdc6315a6adc4de957e408aac4db0b1bf63eaf74da5fcf48d1c911df92ab174"}},
}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def newest_release(appdata_xml):
    m = re.search(r'<release\s+version="([^"]+)"', appdata_xml)
    if not m:
        sys.exit("no <release version=...> found in " + APPDATA)
    return m.group(1)


def commit_of(repo, ref):
    for candidate in (f"origin/{ref}", f"refs/tags/{ref}", ref):
        try:
            return git(repo, "rev-parse", "--verify", "--quiet", candidate + "^{commit}")
        except subprocess.CalledProcessError:
            pass
    sys.exit(f"fritzing-app has no branch, tag or commit '{ref}'")


def resolve(repo, ref):
    if ref in ("", "stable"):
        version = newest_release(git(repo, "show", f"origin/HEAD:{APPDATA}"))
        has_ref = git(repo, "ls-remote", "--heads", "--tags", "origin", version)
        commit = commit_of(repo, version) if has_ref else \
            git(repo, "log", "-1", "--format=%H", "origin/HEAD", "--", APPDATA)
    else:
        commit = commit_of(repo, ref)
        version = ref if re.fullmatch(r"\d+(\.\d+)+", ref) else f"{ref}-{commit[:7]}"
    return {"REF": commit, "VERSION": re.sub(r"[^\w.-]", "-", version)}


def find(text, pattern, what):
    m = re.search(pattern, text, re.M)
    if not m:
        sys.exit(f"cannot find the {what} version in fritzing-app")
    return m.group(1)


def deps(repo):
    repo = Path(repo)
    pro = (repo / "phoenix.pro").read_text(encoding="utf-8")
    pri = {p.stem: p.read_text(encoding="utf-8") for p in (repo / "pri").glob("*.pri")}

    boosts = find(pri["boostdetect"], r"^\s*BOOSTS\s*=\s*(.+)$", "Boost").split()
    boost = str(max(int(b) for b in boosts))
    quazip = find(pri["quazipdetect"], r"^QUAZIP_VERSION\s*=\s*(\S+)", "QuaZip")
    quazip_dir = find(pri["quazipdetect"], r"^QUAZIP_PATH\s*=.*\.\./\.\./(\S+)$", "QuaZip folder")
    quazip_dir = quazip_dir.replace("$$QT_VERSION", "@QT@").replace("$$QUAZIP_VERSION", quazip).replace(")", "")
    v = {
        "QT_LEAST": find(pro, r"^QT_LEAST\s*=\s*(\S+)", "minimum Qt"),
        "QT_MOST": find(pro, r"^QT_MOST\s*=\s*(\S+)", "maximum Qt"),
        "BOOST": boost,
        "LIBGIT2": find(pri["libgit2detect"], r"^LIBGIT_VERSION\s*=\s*(\S+)", "libgit2"),
        "QUAZIP": quazip,
        "QUAZIP_DIR": quazip_dir,
        "SVGPP": find(pri["svgppdetect"], r"svgpp-([\d.]+)", "svgpp"),
        "CLIPPER": find(pri["clipper1detect"], r"Clipper1-([\d.]+)", "Clipper"),
        "NGSPICE": find(pri["spicedetect"], r"ngspice-(\d+)", "ngspice"),
    }
    k = KNOWN
    v["BOOST_SHA_TARGZ"] = k["boost"].get(boost, {}).get("tar.gz", "")
    v["BOOST_SHA_7Z"] = k["boost"].get(boost, {}).get("7z", "")
    v["LIBGIT2_COMMIT"] = k["libgit2"].get(v["LIBGIT2"], "")
    v["QUAZIP_COMMIT"] = k["quazip"].get(quazip, "")
    v["SVGPP_COMMIT"] = k["svgpp"].get(v["SVGPP"], "")
    v["CLIPPER_SHA"] = k["clipper"].get(v["CLIPPER"], "")
    v["NGSPICE_SHA_TARGZ"] = k["ngspice"].get(v["NGSPICE"], {}).get("tar.gz", "")
    v["NGSPICE_SHA_DLL"] = k["ngspice"].get(v["NGSPICE"], {}).get("dll", "")
    return v


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("resolve", "deps"):
        sys.exit(__doc__)
    out = resolve(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "") if sys.argv[1] == "resolve" \
        else deps(sys.argv[2])
    for key, value in out.items():
        print(f"{key}={shlex.quote(value)}")
