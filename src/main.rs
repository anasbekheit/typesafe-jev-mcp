mod jev;
mod secret;
mod tool;

use rmcp::transport::stdio;
use rmcp::ServiceExt;

#[tokio::main(flavor = "current_thread")]
async fn main() {
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
