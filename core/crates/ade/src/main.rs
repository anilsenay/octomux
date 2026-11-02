mod attach;
mod client;
mod daemon;
mod holder;
mod util;

use ade_proto::Paths;
use clap::{Parser, Subcommand};
use std::io::Read;

#[derive(Parser)]
#[command(name = "ade", version, about = "ADE: terminal multiplexer + coding agent manager")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the daemon in the foreground.
    Daemon,
    /// Internal: run a session holder.
    #[command(hide = true)]
    Holder {
        #[arg(long)]
        id: String,
        #[arg(long, default_value = "")]
        cwd: String,
        #[arg(long, default_value_t = 120)]
        cols: u16,
        #[arg(long, default_value_t = 40)]
        rows: u16,
        #[arg(long = "env")]
        env: Vec<String>,
        #[arg(last = true)]
        argv: Vec<String>,
    },
    /// Attach the current terminal to a session.
    Attach { id: String },
    /// Internal: agent hook entry point (reads the hook JSON on stdin).
    #[command(hide = true)]
    Hook { event: String },
    /// Send a raw control request, e.g. `ade ctl state.get` or `ade ctl session.create '{"project_id":"..."}'`.
    Ctl {
        method: String,
        #[arg(default_value = "{}")]
        params: String,
    },
    /// Print daemon status.
    Status,
    /// Install the daemon as a launchd agent (label dev.ade-dev.daemon).
    InstallAgent,
    /// Remove the launchd agent.
    UninstallAgent,
}

fn main() {
    let cli = Cli::parse();
    let paths = Paths::from_env();
    let code = match run(cli, paths) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ade: {e:#}");
            1
        }
    };
    std::process::exit(code);
}

fn run(cli: Cli, paths: Paths) -> anyhow::Result<i32> {
    match cli.cmd {
        Cmd::Daemon => {
            daemon::run(paths)?;
            Ok(0)
        }
        Cmd::Holder { id, cwd, cols, rows, env, argv } => {
            let env = env.into_iter().filter_map(|kv| kv.split_once('=').map(|(k, v)| (k.to_string(), v.to_string()))).collect();
            holder::run(paths, holder::HolderArgs { id, cwd, cols, rows, env, argv })?;
            Ok(0)
        }
        Cmd::Attach { id } => attach::run(paths, id),
        Cmd::Hook { event } => {
            // Never block or fail the agent: best effort, silent, bounded.
            let mut input = String::new();
            let _ = std::io::stdin().take(1 << 20).read_to_string(&mut input);
            let Ok(session_id) = std::env::var("ADE_SESSION_ID") else { return Ok(0) };
            let payload: serde_json::Value = serde_json::from_str(&input).unwrap_or(serde_json::Value::Null);
            if let Ok(mut c) = client::Control::connect(&paths) {
                c.set_timeout(Some(std::time::Duration::from_secs(2)));
                let _ = c.call("hook", serde_json::json!({ "session_id": session_id, "event": event, "payload": payload }));
            }
            Ok(0)
        }
        Cmd::Ctl { method, params } => {
            let params: serde_json::Value = serde_json::from_str(&params)?;
            let mut c = client::Control::connect_or_spawn(&paths)?;
            let v = c.call(&method, params)?;
            println!("{}", serde_json::to_string_pretty(&v)?);
            Ok(0)
        }
        Cmd::Status => match client::Control::connect(&paths) {
            Ok(mut c) => {
                let v = c.call("hello", serde_json::json!({}))?;
                println!("daemon running: {v}");
                Ok(0)
            }
            Err(_) => {
                println!("daemon not running (home: {})", paths.home.display());
                Ok(1)
            }
        },
        Cmd::InstallAgent => {
            install_launch_agent(&paths)?;
            Ok(0)
        }
        Cmd::UninstallAgent => {
            let uid = unsafe { libc::getuid() };
            let plist = client::launch_agent_plist_path();
            let _ = std::process::Command::new("launchctl").args(["bootout", &format!("gui/{uid}"), &plist.to_string_lossy()]).status();
            let _ = std::fs::remove_file(&plist);
            println!("removed {}", plist.display());
            Ok(0)
        }
    }
}

fn install_launch_agent(paths: &Paths) -> anyhow::Result<()> {
    let exe = std::env::current_exe()?;
    let plist = client::launch_agent_plist_path();
    std::fs::create_dir_all(plist.parent().unwrap())?;
    util::ensure_dir_0700(&paths.logs_dir())?;
    let xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array><string>{exe}</string><string>daemon</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>ADE_HOME</key><string>{home}</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#,
        label = client::LAUNCH_LABEL,
        exe = exe.display(),
        home = paths.home.display(),
        log = paths.logs_dir().join("daemon.log").display(),
    );
    let uid = unsafe { libc::getuid() };
    let _ = std::process::Command::new("launchctl").args(["bootout", &format!("gui/{uid}"), &plist.to_string_lossy()]).output();
    std::fs::write(&plist, xml)?;
    let st = std::process::Command::new("launchctl").args(["bootstrap", &format!("gui/{uid}"), &plist.to_string_lossy()]).status()?;
    if !st.success() {
        anyhow::bail!("launchctl bootstrap failed");
    }
    println!("installed {}", plist.display());
    Ok(())
}
