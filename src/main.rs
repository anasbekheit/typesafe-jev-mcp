mod jev;
mod secret;
mod tool;

use rmcp::transport::stdio;
use rmcp::ServiceExt;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("--version") | Some("-V") => {
            println!("{} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
            return;
        }
        Some("--help") | Some("-h") => {
            eprintln!(
                "{} {}: stdio MCP server for TypeSafe Jev.\nSet TYPESAFE_API_KEY or TYPESAFE_API_KEY_COMMAND (https://console.typesafe.ai/).",
                env!("CARGO_PKG_NAME"),
                env!("CARGO_PKG_VERSION")
            );
            return;
        }
        Some(other) => {
            eprintln!("typesafe-jev-mcp: unknown argument {other}");
            std::process::exit(2);
        }
        None => {}
    }

    if let Err(problem) = run().await {
        eprintln!("typesafe-jev-mcp: {problem}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let key = secret::Secret::resolve()?;
    let server = tool::Jev::new(jev::Client::new(key)?);
    let running = server.serve(stdio()).await.map_err(|e| e.to_string())?;
    running.waiting().await.map_err(|e| e.to_string())?;
    Ok(())
}
