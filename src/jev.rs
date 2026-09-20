use std::collections::BTreeMap;
use std::time::Duration;

use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, RETRY_AFTER};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::secret::Secret;

const ENDPOINT: &str = "https://api.typesafe.ai/v1/systemone";
pub const DEFAULT_MODEL: &str = "jev-latest";
const MAX_BODY: usize = 1 << 20;
const DEADLINE: Duration = Duration::from_secs(60);
const ATTEMPTS: u32 = 4;

#[derive(Debug, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Question {
    Noul {
        #[schemars(
            description = "the yes/no condition to test, with its full meaning; name the condition, not the conclusion you expect"
        )]
        instructions: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[schemars(description = "optional object with \"true\" and \"false\" descriptions")]
        criteria: Option<Value>,
    },
    Choice {
        #[schemars(description = "the decision to make, with its full meaning")]
        instructions: Value,
        #[schemars(
            description = "object mapping each option to a description or null; 1 to 255 options"
        )]
        criteria: Value,
    },
    Score {
        #[schemars(description = "what to rate, with its full meaning")]
        instructions: Value,
        #[schemars(
            description = "array of level descriptions ordered low to high; 1 to 10 levels"
        )]
        criteria: Value,
    },
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Answer {
    Noul {
        noul: f64,
    },
    Choice {
        choice: String,
        confidence: f64,
        probabilities: BTreeMap<String, f64>,
    },
    Score {
        score: f64,
        confidence: f64,
        legend: BTreeMap<String, String>,
        probabilities: BTreeMap<String, f64>,
    },
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Response {
    pub model: String,
    pub answers: BTreeMap<String, Answer>,
    pub usage: Usage,
}

#[derive(Serialize)]
struct Request<'a> {
    model: &'a str,
    state: &'a Value,
    questions: &'a BTreeMap<String, Question>,
}

struct Failure {
    message: String,
    retryable: bool,
    retry_after: Option<Duration>,
}

impl Failure {
    fn fatal(message: String) -> Self {
        Self {
            message,
            retryable: false,
            retry_after: None,
        }
    }
}

pub struct Client {
    http: reqwest::Client,
    auth: reqwest::header::HeaderValue,
}

impl Client {
    pub fn new(key: Secret) -> Result<Self, String> {
        let mut auth = reqwest::header::HeaderValue::from_str(&key.bearer()).map_err(|_| {
            "the API key contains characters that cannot be sent in a header".to_string()
        })?;
        auth.set_sensitive(true);
        let http = reqwest::Client::builder()
            .user_agent(concat!("typesafe-jev-mcp/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| format!("building the HTTP client: {e}"))?;
        Ok(Self { http, auth })
    }

    pub async fn evaluate(
        &self,
        model: &str,
        state: &Value,
        questions: &BTreeMap<String, Question>,
    ) -> Result<Response, String> {
        let body = serde_json::to_vec(&Request {
            model,
            state,
            questions,
        })
        .map_err(|e| format!("encoding the request: {e}"))?;
        tokio::time::timeout(DEADLINE, self.send_with_retries(body))
            .await
            .map_err(|_| format!("jev did not answer within {}s", DEADLINE.as_secs()))?
    }

    async fn send_with_retries(&self, body: Vec<u8>) -> Result<Response, String> {
        let mut delay = Duration::from_secs(1);
        let mut attempt = 1;
        loop {
            match self.send(&body).await {
                Ok(response) => return Ok(response),
                Err(failure) if failure.retryable && attempt < ATTEMPTS => {
                    tokio::time::sleep(failure.retry_after.unwrap_or(delay)).await;
                    delay *= 2;
                    attempt += 1;
                }
                Err(failure) => return Err(failure.message),
            }
        }
    }

    async fn send(&self, body: &[u8]) -> Result<Response, Failure> {
        let response = self
            .http
            .post(ENDPOINT)
            .header(AUTHORIZATION, self.auth.clone())
            .header(CONTENT_TYPE, "application/json")
            .body(body.to_vec())
            .send()
            .await
            .map_err(|e| Failure {
                message: format!("reaching jev: {e}"),
                retryable: e.is_timeout() || e.is_connect(),
                retry_after: None,
            })?;

        let status = response.status().as_u16();
        let request_id =
            header(&response, "x-typesafe-request-id").unwrap_or_else(|| "unknown".into());
        let retry_after = header(&response, RETRY_AFTER.as_str())
            .and_then(|v| v.parse().ok())
            .map(Duration::from_secs);

        let bytes = response
            .bytes()
            .await
            .map_err(|e| Failure::fatal(format!("reading the jev response: {e}")))?;
        if bytes.len() > MAX_BODY {
            return Err(Failure::fatal(format!(
                "the jev response exceeds {MAX_BODY} bytes [request {request_id}]"
            )));
        }

        if (200..300).contains(&status) {
            return serde_json::from_slice(&bytes).map_err(|e| {
                Failure::fatal(format!(
                    "jev returned JSON this tool could not read: {e} [request {request_id}]"
                ))
            });
        }

        Err(Failure {
            message: format!(
                "jev returned {status}: {} [request {request_id}]",
                describe(&bytes)
            ),
            retryable: status == 429 || status == 529,
            retry_after,
        })
    }
}

fn header(response: &reqwest::Response, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)?
        .to_str()
        .ok()
        .map(str::to_string)
}

fn describe(body: &[u8]) -> String {
    let Ok(parsed) = serde_json::from_slice::<Value>(body) else {
        return String::from_utf8_lossy(body).trim().to_string();
    };
    let Some(detail) = parsed.get("detail") else {
        return parsed.to_string();
    };
    match detail {
        Value::String(message) => message.clone(),
        Value::Array(problems) => problems.iter().map(problem).collect::<Vec<_>>().join("; "),
        Value::Object(fields) => {
            let kind = fields
                .get("error_type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if kind == "max_tokens_exceeded" {
                return "state and questions exceed the 64k token ceiling, and state alone is capped at 32k: condense the state or split the questions across calls".into();
            }
            fields
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or(kind)
                .to_string()
        }
        other => other.to_string(),
    }
}

fn problem(entry: &Value) -> String {
    let location = entry
        .get("loc")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(".")
        })
        .unwrap_or_default();
    let message = entry
        .get("msg")
        .and_then(Value::as_str)
        .unwrap_or("is invalid");
    format!("{location}: {message}")
}
