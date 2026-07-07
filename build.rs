use std::process::Command;

fn git_sha() -> String {
    match Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
    {
        Ok(out) if out.status.success() => {
            let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if sha.is_empty() {
                return "unknown".into();
            }

            let dirty = match Command::new("git").args(["status", "--porcelain"]).output() {
                Ok(worktree) => !worktree.stdout.is_empty() || !worktree.stderr.is_empty(),
                Err(_) => false,
            };

            if dirty {
                format!("{sha}-dirty")
            } else {
                sha
            }
        }
        _ => "unknown".to_string(),
    }
}

fn main() {
    // Re-run this build script if HEAD changes
    println!("cargo:rerun-if-changed=.git/HEAD");
    if let Ok(ref refs_head) = std::fs::read_to_string(".git/HEAD") {
        if let Some(ref_path) = refs_head.trim().strip_prefix("ref: ") {
            println!("cargo:rerun-if-changed=.git/{}", ref_path);
        }
    }

    let git_sha = git_sha();
    println!("cargo:rustc-env=GIT_SHA={}", git_sha);
}
