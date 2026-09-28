//! `cherry-host project-info --json PATH…`: what Cherry needs to know about
//! a project folder on this machine when it opens that project from another
//! Mac (docs/specs/remote-devices.md, phase 3), in one round trip over its
//! SSH master: whether the folder exists, its git top level, common
//! directory and worktrees, and its `cherry.toml`. It is shipped with (and
//! versioned like) the cherry-host Cherry installs there, so the answer's
//! shape always matches the app that asks. It never starts, replaces or
//! talks to a host, and it changes nothing: it only reads, and runs `git`
//! read-only commands (`rev-parse`, `worktree list`).
use serde::Serialize;
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

/// The answer's format. Cherry refuses a version it does not know.
pub const FORMAT_VERSION: u32 = 1;
/// At most this many bytes of `cherry.toml` are sent; a larger file is
/// reported with its size and no text.
pub const CHERRY_TOML_LIMIT: u64 = 256 * 1024;
/// Paths asked about in one call.
pub const MAX_PATHS: usize = 64;
/// `git worktree list` output kept (a repository with thousands of
/// worktrees is cut, and says so).
pub const WORKTREE_LIST_LIMIT: usize = 1024 * 1024;

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct Report {
    pub version: u32,
    pub projects: Vec<ProjectInfo>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct ProjectInfo {
    /// The path as asked.
    pub path: String,
    /// Something is there.
    pub exists: bool,
    /// It is a directory (following links).
    pub is_directory: bool,
    /// Its git repository, when it is in one and `git` answered.
    pub git: Option<GitInfo>,
    /// Why `git` could not say (not installed, not a repository, …).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_error: Option<String>,
    /// `<path>/cherry.toml`, when there is one.
    pub cherry_toml: Option<CherryToml>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct GitInfo {
    /// `git rev-parse --show-toplevel`.
    pub top_level: String,
    /// `git rev-parse --path-format=absolute --git-common-dir`.
    pub common_dir: String,
    /// `git worktree list --porcelain -z`, as it printed it (NUL-separated
    /// fields, so any path survives).
    pub worktrees: String,
    /// The list was longer than `WORKTREE_LIST_LIMIT` and was cut.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub worktrees_truncated: bool,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct CherryToml {
    /// Its size in bytes.
    pub size: u64,
    /// Its contents; none when it is larger than `CHERRY_TOML_LIMIT` or not
    /// UTF-8.
    pub text: Option<String>,
    /// Why there is no text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// The report for `paths`, running the `git` that `CHERRY_GIT` names: the
/// app's script finds one that will not ask to install the command line
/// tools (on macOS, `/usr/bin/git` without them pops that prompt on the
/// Mac's screen). Unset or empty means no git: nothing from PATH is ever
/// tried, and each folder's `git_error` is `git not found`.
pub fn report(paths: &[PathBuf]) -> Report {
    report_for_git(paths, std::env::var("CHERRY_GIT").ok().as_deref())
}

/// `report` with `git` as `CHERRY_GIT` would give it.
pub fn report_for_git(paths: &[PathBuf], git: Option<&str>) -> Report {
    match git.filter(|git| !git.is_empty()) {
        Some(git) => report_with(paths, &|directory, arguments| {
            run_git(git, directory, arguments)
        }),
        None => report_with(paths, &|_, _| Err(GIT_NOT_FOUND.to_owned())),
    }
}

/// `git_error` when no git was given.
pub const GIT_NOT_FOUND: &str = "git not found";

/// A `git` invocation's standard output, or why it failed.
type GitRunner<'a> = dyn Fn(&Path, &[&str]) -> Result<Vec<u8>, String> + 'a;

pub fn report_with(paths: &[PathBuf], git: &GitRunner) -> Report {
    Report {
        version: FORMAT_VERSION,
        projects: paths
            .iter()
            .take(MAX_PATHS)
            .map(|path| project(path, git))
            .collect(),
    }
}

fn project(path: &Path, git: &GitRunner) -> ProjectInfo {
    let metadata = std::fs::metadata(path);
    let exists = metadata.is_ok() || std::fs::symlink_metadata(path).is_ok();
    let is_directory = metadata.map(|m| m.is_dir()).unwrap_or(false);
    let mut info = ProjectInfo {
        path: path.to_string_lossy().into_owned(),
        exists,
        is_directory,
        git: None,
        git_error: None,
        cherry_toml: None,
    };
    if !is_directory {
        return info;
    }
    match git_info(path, git) {
        Ok(found) => info.git = Some(found),
        Err(error) => info.git_error = Some(error),
    }
    info.cherry_toml = cherry_toml(&path.join("cherry.toml"));
    info
}

fn git_info(path: &Path, git: &GitRunner) -> Result<GitInfo, String> {
    let line = |output: Vec<u8>| {
        String::from_utf8_lossy(&output)
            .trim_end_matches(['\n', '\r'])
            .to_owned()
    };
    let top_level = line(git(path, &["rev-parse", "--show-toplevel"])?);
    let common_dir = line(git(
        path,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?);
    let mut worktrees = git(path, &["worktree", "list", "--porcelain", "-z"])?;
    let worktrees_truncated = worktrees.len() > WORKTREE_LIST_LIMIT;
    if worktrees_truncated {
        worktrees.truncate(WORKTREE_LIST_LIMIT);
        // Only whole records: up to the last record separator (two NULs).
        let end = worktrees
            .windows(2)
            .rposition(|pair| pair == [0, 0])
            .map_or(0, |index| index + 2);
        worktrees.truncate(end);
    }
    Ok(GitInfo {
        top_level,
        common_dir,
        worktrees: String::from_utf8_lossy(&worktrees).into_owned(),
        worktrees_truncated,
    })
}

/// `path`'s size and, when it is small enough and UTF-8, its text. None
/// when there is no such file.
pub fn cherry_toml(path: &Path) -> Option<CherryToml> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() {
        return Some(CherryToml {
            size: 0,
            text: None,
            error: Some("cherry.toml is not a file".into()),
        });
    }
    let size = metadata.len();
    if size > CHERRY_TOML_LIMIT {
        return Some(CherryToml {
            size,
            text: None,
            error: Some(format!(
                "cherry.toml is larger than {} KiB",
                CHERRY_TOML_LIMIT / 1024
            )),
        });
    }
    let mut bytes = Vec::new();
    // Read one byte past the limit: the file may have grown since.
    let read =
        File::open(path).and_then(|file| file.take(CHERRY_TOML_LIMIT + 1).read_to_end(&mut bytes));
    if let Err(error) = read {
        return Some(CherryToml {
            size,
            text: None,
            error: Some(format!("cherry.toml could not be read: {error}")),
        });
    }
    if bytes.len() as u64 > CHERRY_TOML_LIMIT {
        return Some(CherryToml {
            size: bytes.len() as u64,
            text: None,
            error: Some(format!(
                "cherry.toml is larger than {} KiB",
                CHERRY_TOML_LIMIT / 1024
            )),
        });
    }
    let size = bytes.len() as u64;
    match String::from_utf8(bytes) {
        Ok(text) => Some(CherryToml {
            size,
            text: Some(text),
            error: None,
        }),
        Err(_) => Some(CherryToml {
            size,
            text: None,
            error: Some("cherry.toml is not UTF-8".into()),
        }),
    }
}

/// Runs `git -C directory arguments…` with no terminal and no prompts.
fn run_git(git: &str, directory: &Path, arguments: &[&str]) -> Result<Vec<u8>, String> {
    let output = Command::new(git)
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .stdin(Stdio::null())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .map_err(|error| format!("git could not run: {error}"))?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if message.is_empty() {
        format!("git exited with {}", output.status)
    } else {
        message
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, process::Command};

    fn git(directory: &Path, arguments: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "git {arguments:?}");
    }

    fn json(report: &Report) -> serde_json::Value {
        serde_json::to_value(report).unwrap()
    }

    #[test]
    fn a_repository_reports_its_worktrees_and_cherry_toml() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let repository = root.join("app");
        fs::create_dir(&repository).unwrap();
        git(&repository, &["init", "-q", "-b", "main"]);
        git(&repository, &["commit", "-q", "--allow-empty", "-m", "x"]);
        let linked = root.join("wt/feature one");
        git(
            &repository,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "feature",
                linked.to_str().unwrap(),
            ],
        );
        fs::write(
            repository.join("cherry.toml"),
            "[commands.web]\ncommand = \"npm run dev\"\n",
        )
        .unwrap();

        let report = report_for_git(&[repository.clone(), linked.clone()], Some("git"));
        assert_eq!(report.version, FORMAT_VERSION);
        let main = &report.projects[0];
        assert!(main.exists && main.is_directory);
        let git = main.git.as_ref().expect("git info");
        assert_eq!(Path::new(&git.top_level), repository);
        assert_eq!(Path::new(&git.common_dir), repository.join(".git"));
        let fields: Vec<&str> = git.worktrees.split('\0').collect();
        assert!(fields.contains(&format!("worktree {}", repository.display()).as_str()));
        assert!(fields.contains(&format!("worktree {}", linked.display()).as_str()));
        assert!(fields.contains(&"branch refs/heads/feature"));
        assert!(!git.worktrees_truncated);
        let toml = main.cherry_toml.as_ref().unwrap();
        assert_eq!(
            toml.text.as_deref(),
            Some("[commands.web]\ncommand = \"npm run dev\"\n")
        );
        assert_eq!(toml.size, 39);
        // The linked worktree: its own top level, the same common dir, and
        // no cherry.toml of its own.
        let other = &report.projects[1];
        let other_git = other.git.as_ref().unwrap();
        assert_eq!(Path::new(&other_git.top_level), linked);
        assert_eq!(other_git.common_dir, git.common_dir);
        assert_eq!(other.cherry_toml, None);
        // As JSON.
        let value = json(&report);
        assert_eq!(value["version"], 1);
        assert_eq!(value["projects"][0]["exists"], true);
        assert!(value["projects"][0].get("git_error").is_none());
    }

    #[test]
    fn missing_folders_files_and_plain_folders_say_so() {
        let root = tempfile::tempdir().unwrap();
        let plain = root.path().join("plain");
        fs::create_dir(&plain).unwrap();
        let file = root.path().join("file");
        fs::write(&file, "x").unwrap();
        let report = report_with(
            &[root.path().join("nowhere"), file.clone(), plain.clone()],
            &|_, _| Err("fatal: not a git repository".into()),
        );
        let [missing, file, plain] = &report.projects[..] else {
            panic!("{report:?}")
        };
        assert!(!missing.exists && !missing.is_directory && missing.git.is_none());
        assert_eq!(missing.git_error, None);
        assert!(file.exists && !file.is_directory && file.git.is_none());
        assert!(plain.exists && plain.is_directory && plain.git.is_none());
        assert_eq!(
            plain.git_error.as_deref(),
            Some("fatal: not a git repository")
        );
        assert_eq!(plain.cherry_toml, None);
    }

    #[test]
    fn cherry_toml_is_capped_and_must_be_utf8() {
        let root = tempfile::tempdir().unwrap();
        let exact = root.path().join("exact.toml");
        fs::write(&exact, vec![b'#'; CHERRY_TOML_LIMIT as usize]).unwrap();
        let found = cherry_toml(&exact).unwrap();
        assert_eq!(found.size, CHERRY_TOML_LIMIT);
        assert_eq!(
            found.text.map(|text| text.len()),
            Some(CHERRY_TOML_LIMIT as usize)
        );

        let large = root.path().join("large.toml");
        fs::write(&large, vec![b'#'; CHERRY_TOML_LIMIT as usize + 1]).unwrap();
        let found = cherry_toml(&large).unwrap();
        assert_eq!(found.size, CHERRY_TOML_LIMIT + 1);
        assert_eq!(found.text, None);
        assert!(found.error.unwrap().contains("256 KiB"));

        let binary = root.path().join("binary.toml");
        fs::write(&binary, [0xff, 0xfe, 0x00]).unwrap();
        let found = cherry_toml(&binary).unwrap();
        assert_eq!(found.text, None);
        assert_eq!(found.error.as_deref(), Some("cherry.toml is not UTF-8"));

        let directory = root.path().join("dir.toml");
        fs::create_dir(&directory).unwrap();
        assert_eq!(
            cherry_toml(&directory).unwrap().error.as_deref(),
            Some("cherry.toml is not a file")
        );
        assert_eq!(cherry_toml(&root.path().join("none.toml")), None);
    }

    #[test]
    fn a_long_worktree_list_is_cut_at_a_record() {
        let root = tempfile::tempdir().unwrap();
        let record = "worktree /x\0HEAD 0123\0branch refs/heads/b\0\0";
        let list = record.repeat(WORKTREE_LIST_LIMIT / record.len() + 10);
        let report = report_with(&[root.path().to_path_buf()], &|_, arguments| {
            Ok(if arguments[0] == "worktree" {
                list.clone().into_bytes()
            } else {
                b"/x\n".to_vec()
            })
        });
        let git = report.projects[0].git.as_ref().unwrap();
        assert!(git.worktrees_truncated);
        assert!(git.worktrees.len() <= WORKTREE_LIST_LIMIT);
        assert!(git.worktrees.ends_with("\0\0"));
        assert_eq!(git.worktrees.len() % record.len(), 0);
        assert_eq!(git.top_level, "/x");
    }

    #[test]
    fn without_cherry_git_no_git_runs() {
        let root = tempfile::tempdir().unwrap();
        let repository = root.path().canonicalize().unwrap();
        git(&repository, &["init", "-q", "-b", "main"]);
        fs::write(repository.join("cherry.toml"), "# x\n").unwrap();
        // A PATH whose `git` records being run: never tried.
        let bin = root.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let marker = root.path().join("ran");
        let fake = bin.join("git");
        fs::write(
            &fake,
            format!("#!/bin/sh\ntouch '{}'\nexit 1\n", marker.display()),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        for git in [None, Some("")] {
            let report = report_for_git(std::slice::from_ref(&repository), git);
            let project = &report.projects[0];
            assert!(project.git.is_none());
            assert_eq!(project.git_error.as_deref(), Some(GIT_NOT_FOUND));
            // cherry.toml is still read.
            assert_eq!(
                project.cherry_toml.as_ref().unwrap().text.as_deref(),
                Some("# x\n")
            );
        }
        assert!(!marker.exists());
        // With CHERRY_GIT, that git runs.
        let found = report_for_git(std::slice::from_ref(&repository), Some("git"));
        assert!(found.projects[0].git.is_some(), "{found:?}");
    }

    #[test]
    fn at_most_max_paths_are_answered() {
        let paths: Vec<PathBuf> = (0..MAX_PATHS + 5)
            .map(|index| PathBuf::from(format!("/nonexistent-cherry-{index}")))
            .collect();
        let report = report_with(&paths, &|_, _| unreachable!());
        assert_eq!(report.projects.len(), MAX_PATHS);
    }
}
