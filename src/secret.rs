use std::fmt;
use std::process::Command;

pub struct Secret(String);

impl Secret {
    pub fn resolve() -> Result<Self, String> {
        if let Ok(key) = std::env::var("TYPESAFE_API_KEY") {
            if !key.is_empty() {
                return Ok(Self(key));
            }
        }
        if let Ok(command) = std::env::var("TYPESAFE_API_KEY_COMMAND") {
            return Self::from_command(&command);
        }
        Err("set TYPESAFE_API_KEY, or TYPESAFE_API_KEY_COMMAND to a command that prints it (https://console.typesafe.ai/)".into())
    }

    fn from_command(command: &str) -> Result<Self, String> {
        let (shell, flag) = if cfg!(windows) {
            ("cmd", "/C")
        } else {
            ("sh", "-c")
        };
        let output = Command::new(shell)
            .arg(flag)
            .arg(command)
            .output()
            .map_err(|e| format!("running TYPESAFE_API_KEY_COMMAND: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "TYPESAFE_API_KEY_COMMAND exited with {}",
                output.status
            ));
        }
        let key = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if key.is_empty() {
            return Err("TYPESAFE_API_KEY_COMMAND printed nothing".into());
        }
        Ok(Self(key))
    }

    pub fn bearer(&self) -> String {
        format!("Bearer {}", self.0)
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[redacted]")
    }
}
