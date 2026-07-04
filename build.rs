use std::process::Command;

fn main() {
    // Re-run this build script if HEAD changes
    println!("cargo:rerun-if-changed=.git/HEAD");
    if let Ok(ref refs_head) = std::fs::read_to_string(".git/HEAD") {
        if let Some(ref_path) = refs_head.trim().strip_prefix("ref: ") {
            println!("cargo:rerun-if-changed=.git/{}", ref_path);
        }
    }

    let git_sha = match Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    };
    println!("cargo:rustc-env=GIT_SHA={}", git_sha);
}
