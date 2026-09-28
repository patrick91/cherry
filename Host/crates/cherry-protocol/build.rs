//! Sets `CHERRY_BUILD_ID`, which every cherry and cherry-host built from this
//! workspace reports (`cherry_protocol::BUILD`): the value of the variable of
//! that name at build time when it is set (Scripts/install-local-app passes
//! the app's CFBundleVersion, `<YYYYMMDDHHMMSS>.<revision>`), otherwise
//! `dev-<commit time>.<revision>` for the checked-out commit, otherwise (no
//! git) `dev-<package version>`. Only an explicit build id carries a build
//! time that orders it (`build_stamp`): a development build is never newer
//! or older than another, so it never takes over a daemon it finds.
use std::{path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-env-changed=CHERRY_BUILD_ID");
    let given = std::env::var("CHERRY_BUILD_ID")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty() && value.chars().all(|c| c.is_ascii_graphic()));
    let build = match given {
        Some(build) => build,
        None => format!(
            "dev-{}",
            from_git().unwrap_or_else(|| std::env::var("CARGO_PKG_VERSION").unwrap())
        ),
    };
    println!("cargo:rustc-env=CHERRY_BUILD_ID={build}");
}

fn git(arguments: &[&str]) -> Option<String> {
    let manifest = std::env::var_os("CARGO_MANIFEST_DIR")?;
    let output = Command::new("git")
        .arg("-C")
        .arg(manifest)
        .args(arguments)
        .env("TZ", "UTC")
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let text = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (!text.is_empty()).then_some(text)
}

fn from_git() -> Option<String> {
    // Built again when the checked-out commit changes.
    for dir in [
        git(&["rev-parse", "--absolute-git-dir"]),
        git(&["rev-parse", "--path-format=absolute", "--git-common-dir"]),
    ]
    .into_iter()
    .flatten()
    {
        let dir = PathBuf::from(dir);
        println!("cargo:rerun-if-changed={}", dir.join("HEAD").display());
        println!(
            "cargo:rerun-if-changed={}",
            dir.join("packed-refs").display()
        );
        if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
            println!("cargo:rerun-if-changed={}", dir.join(reference).display());
        }
    }
    let revision = git(&["rev-parse", "--short=7", "HEAD"])?;
    let stamp = git(&[
        "log",
        "-1",
        "--format=%cd",
        "--date=format-local:%Y%m%d%H%M%S",
    ])?;
    Some(format!("{stamp}.{revision}"))
}
