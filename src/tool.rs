use std::collections::BTreeMap;
use std::sync::Arc;

use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{Implementation, ServerCapabilities, ServerConfig};
use rmcp::{tool, tool_handler, tool_router, Json, ServerHandler};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;

use crate::jev::{Client, Question, Response, DEFAULT_MODEL};

const INSTRUCTIONS: &str = "\
The evaluate tool runs Jev, a TypeSafe System One model that returns typed judgments and probabilities, not generated text.
- Question types: noul (probability a yes/no condition holds), choice (one option from a criteria map), score (probability-weighted position on ordered criteria levels).
- Ask one narrow judgment per question. Question ids are NOT sent to the model, so instructions must carry the full meaning.
- Put everything the judgment needs in state; prefer a JSON object with named fields, and reference nested fields with backticked paths like `ticket.messages[0].text`.
- State is what you observed, not your verdict about it. Keep the uncertainty and the counterevidence; a conclusion asserted in state biases the answer toward it, and the confidence that comes back is then agreement with yourself.
- Write instructions that name the condition to test, not the conclusion you expect.
- Batch independent questions over the same state into one call; they run in parallel and cannot see each other's answers.
- Include a no-match option in a choice when nothing may fit. Score levels must describe concrete situations.
- A noul near 0.5 means uncertain, not medium intensity. Noul answers carry no confidence: the probability is the answer.
- Score answers are 0-indexed, so N levels score 0 to N-1. Read the response legend and probabilities alongside the score.
- State and questions share a 64k token ceiling, and state alone is capped at 32k. Condense long state or split the questions across calls.
- jev-latest and jev-preview move when TypeSafe ship a release. Once you have tuned a threshold against labelled examples, pass the versioned id it was tuned against.
Docs: https://docs.typesafe.ai/api";

#[derive(Deserialize, JsonSchema)]
pub struct Input {
    #[schemars(
        description = "content to judge: plain text, or a JSON object or array with named fields; observed evidence, not your verdict about it"
    )]
    state: Value,
    #[schemars(
        description = "map of question id to question; answers come back under the same ids, which are not sent to the model"
    )]
    questions: BTreeMap<String, Question>,
    #[serde(default)]
    #[schemars(
        description = "model to use; defaults to jev-latest. Pass a versioned id such as jev-1.13.0 to pin a tuned threshold"
    )]
    model: Option<String>,
}

#[derive(Clone)]
pub struct Jev {
    client: Arc<Client>,
    tool_router: ToolRouter<Self>,
}

#[tool_router(router = tool_router)]
impl Jev {
    pub fn new(client: Client) -> Self {
        Self {
            client: Arc::new(client),
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        name = "evaluate",
        description = "Jev is a fast structured-decision model: unstructured state in, typed answers (noul, choice, score) with calibrated probabilities out. Use it for classification, routing, scoring, extraction, branching, guardrails and map-reduce over large data, wherever hand-written logic is too brittle. Not for prose or code: the answer space must be enumerable up front. Pass raw evidence as state, not your read of it."
    )]
    async fn evaluate(
        &self,
        Parameters(input): Parameters<Input>,
    ) -> Result<Json<Response>, String> {
        validate(&input.questions)?;
        self.client
            .evaluate(
                input.model.as_deref().unwrap_or(DEFAULT_MODEL),
                &input.state,
                &input.questions,
            )
            .await
            .map(Json)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Jev {
    fn get_info(&self) -> ServerConfig {
        let mut info = ServerConfig::default();
        let mut identity = Implementation::default();
        identity.name = "jev".into();
        identity.version = env!("CARGO_PKG_VERSION").into();
        info.server_info = identity;
        info.instructions = Some(INSTRUCTIONS.into());
        info.capabilities = ServerCapabilities::builder().enable_tools().build();
        info
    }
}

fn validate(questions: &BTreeMap<String, Question>) -> Result<(), String> {
    if questions.is_empty() {
        return Err("questions must not be empty".into());
    }
    for (id, question) in questions {
        let problem = match question {
            Question::Choice { criteria, .. } => match entries(criteria) {
                None => Some(
                    "must be an object mapping each option to a description or null".to_string(),
                ),
                Some(n) if n == 0 || n > 255 => {
                    Some(format!("must have 1 to 255 options, got {n}"))
                }
                Some(_) => None,
            },
            Question::Score { criteria, .. } => match levels(criteria) {
                None => {
                    Some("must be an array of level descriptions, ordered low to high".to_string())
                }
                Some(n) if n == 0 || n > 10 => Some(format!("must have 1 to 10 levels, got {n}")),
                Some(_) => None,
            },
            Question::Noul {
                criteria: Some(criteria),
                ..
            } if entries(criteria).is_none() => Some(
                "must be an object with \"true\" and \"false\" descriptions, or omitted"
                    .to_string(),
            ),
            Question::Noul { .. } => None,
        };
        if let Some(problem) = problem {
            return Err(format!("questions[{id:?}].criteria: {problem}"));
        }
    }
    Ok(())
}

fn entries(criteria: &Value) -> Option<usize> {
    criteria.as_object().map(|options| options.len())
}

fn levels(criteria: &Value) -> Option<usize> {
    criteria.as_array().map(|levels| levels.len())
}
