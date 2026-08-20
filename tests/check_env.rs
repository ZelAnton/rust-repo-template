//! Black-box regression coverage for the environment preflight scripts.

use std::path::PathBuf;
use std::process::Command;

fn repository_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn run_harness(program: &str, script: &str) {
    let script = repository_root().join(script);
    let output = match Command::new(program).arg(&script).output() {
        Ok(output) => output,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            eprintln!(
                "skipping {} because {program} is unavailable",
                script.display()
            );
            return;
        }
        Err(error) => panic!("failed to run {}: {error}", script.display()),
    };

    assert!(
        output.status.success(),
        "{} failed\nstdout:\n{}\nstderr:\n{}",
        script.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn powershell_check_env_scenarios() {
    run_harness("pwsh", "tests/check-env/check-env.Tests.ps1");
}

#[test]
#[cfg(not(windows))]
fn posix_check_env_scenarios() {
    run_harness("bash", "tests/check-env/check-env.test.sh");
}
