mod attach;
mod client;
mod daemon;
mod holder;
mod hook_spool;
mod procs;
mod statusline;
mod util;

use octomux_proto::Paths;
use clap::{Parser, Subcommand};
use std::io::Read;

#[derive(Parser)]
#[command(name = "octomux", version, about = "Octomux: terminal multiplexer + coding agent manager")]
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
    /// Relay stdin/stdout to this host's daemon (for `ssh host ade stdio`).
    Stdio,
    /// Claude Code status line passthrough (reports usage limits to the daemon).
    #[command(hide = true)]
    Statusline,
    /// Send a raw control request, e.g. `ade ctl state.get` or `ade ctl session.create '{"project_id":"..."}'`.
    Ctl {
        method: String,
        #[arg(default_value = "{}")]
        params: String,
    },
    /// Print daemon status.
    Status,
    /// Install the daemon as a launchd agent (label dev.octomux.daemon, or dev.octomux.daemon.dev for the Dev
    /// variant; replaces the pre-rename dev.ade-dev.daemon).
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
            let Some(session_id) = octomux_proto::env_var_os("SESSION_ID").and_then(|v| v.into_string().ok()) else { return Ok(0) };
            let payload: serde_json::Value = serde_json::from_str(&input).unwrap_or(serde_json::Value::Null);
            // A `claude -p` an agent runs from a tool inherits the tab's session id: with our hooks installed
            // globally it would report into the tab. Its hooks have a second claude above it; drop them.
            let parent = unsafe { libc::getppid() };
            if procs::claude_ancestors(parent) >= 2 {
                return Ok(0);
            }
            let params = serde_json::json!({ "session_id": session_id, "event": event, "payload": payload });
            let sent = client::Control::connect(&paths).ok().is_some_and(|mut c| {
                c.set_timeout(Some(std::time::Duration::from_secs(2)));
                c.call("hook", params.clone()).is_ok()
            });
            // The daemon is restarting (an update, a crash): keep the event so it can catch up, else a turn
            // that ended meanwhile would look like it is still running.
            if !sent {
                hook_spool::append(&paths, &params);
            }
            Ok(0)
        }
        Cmd::Statusline => Ok(statusline::run(&paths)),
        Cmd::Stdio => client::stdio_bridge(&paths),
        Cmd::Ctl { method, params } => {
            let params: serde_json::Value = serde_json::from_str(&params)?;
            // Shutting down must never start a daemon (which would restore sessions).
            let mut c = if method == "daemon.shutdown" || method == "daemon.stop_all" { client::Control::connect(&paths)? } else { client::Control::connect_or_spawn(&paths)? };
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
            let mut plists = vec![client::launch_agent_plist_path()];
            if !octomux_proto::is_dev_variant() { plists.push(client::legacy_launch_agent_plist_path()); }
            for plist in plists {
                if !plist.exists() {
                    continue;
                }
                let _ = std::process::Command::new("launchctl").args(["bootout", &format!("gui/{uid}"), &plist.to_string_lossy()]).status();
                let _ = std::fs::remove_file(&plist);
                println!("removed {}", plist.display());
            }
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
  <dict><key>{home_var}</key><string>{home}</string>{variant}</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#,
        label = client::launch_label(),
        variant = if octomux_proto::is_dev_variant() { format!("<key>{}</key><string>dev</string>", octomux_proto::VARIANT_VAR) } else { String::new() },
        home_var = octomux_proto::HOME_VAR,
        exe = exe.display(),
        home = paths.home.display(),
        log = paths.logs_dir().join("daemon.log").display(),
    );
    let uid = unsafe { libc::getuid() };
    // Pre-rename agent: stop it first so the new daemon can take the socket (sessions survive a daemon restart).
    let legacy = client::legacy_launch_agent_plist_path();
    if legacy.exists() && !octomux_proto::is_dev_variant() {
        let _ = std::process::Command::new("launchctl").args(["bootout", &format!("gui/{uid}"), &legacy.to_string_lossy()]).output();
        let _ = std::fs::remove_file(&legacy);
    }
    let _ = std::process::Command::new("launchctl").args(["bootout", &format!("gui/{uid}"), &plist.to_string_lossy()]).output();
    std::fs::write(&plist, xml)?;
    let st = std::process::Command::new("launchctl").args(["bootstrap", &format!("gui/{uid}"), &plist.to_string_lossy()]).status()?;
    if !st.success() {
        anyhow::bail!("launchctl bootstrap failed");
    }
    println!("installed {}", plist.display());
    Ok(())
}
