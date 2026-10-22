//! Slash commands (`/away`, an integration's `/jira`), and the buttons and
//! menus integrations put in their posts' attachments, with the text
//! those attachments carry.

use greed_chat::protocol::{Action, Choice, Command, PressParams, RoomParams, SendParams};
use greed_chat::rpc::Failure;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::{Api, Post};

/// A command as the server lists it.
#[derive(Deserialize)]
struct Listed {
    trigger: String,
    #[serde(default)]
    auto_complete: bool,
    #[serde(default)]
    auto_complete_hint: String,
    #[serde(default)]
    auto_complete_desc: String,
}

/// What running a command answers.
#[derive(Deserialize)]
struct Ran {
    #[serde(default)]
    response_type: String,
    #[serde(default)]
    text: String,
}

impl Mattermost {
    /// The team `room` is in, or for a direct message the first of yours:
    /// commands belong to teams.
    async fn team_of(api: &Api, room: &str) -> Result<String, Failure> {
        let fail = |e: crate::api::Error| Failure::new(format!("can't find the team: {e}"));
        let channel: Value = api
            .get(&format!("api/v4/channels/{room}"))
            .await
            .map_err(fail)?;
        if let Some(team) = channel["team_id"].as_str().filter(|team| !team.is_empty()) {
            return Ok(team.to_string());
        }
        let teams: Vec<Value> = api.get("api/v4/users/me/teams").await.map_err(fail)?;
        teams
            .first()
            .and_then(|team| team["id"].as_str())
            .map(str::to_string)
            .ok_or_else(|| Failure::new("you're in no team, which commands need"))
    }

    /// Runs `send.text`, a command line starting with `/`. What it answers
    /// only you comes back as `text`, besides showing in the room.
    pub(crate) async fn run_command(&self, send: &SendParams) -> Result<Value, Failure> {
        let (api, _) = self.signed(&send.account)?;
        let team = Self::team_of(&api, &send.room).await?;
        let root = send.thread.clone().unwrap_or_default();
        let body = json!({
            "channel_id": send.room,
            "team_id": team,
            "command": send.text,
            "root_id": root,
            "parent_id": root,
        });
        let ran: Ran = api
            .post("api/v4/commands/execute", &body)
            .await
            .map_err(|e| Failure::new(e.to_string()))?;
        let said = (ran.response_type != "in_channel" && !ran.text.is_empty()).then_some(ran.text);
        Ok(json!({ "text": said }))
    }

    /// The commands there are where `params.room` is, as typed after `/`.
    pub(crate) async fn commands(&self, params: &RoomParams) -> Result<Vec<Command>, Failure> {
        let (api, _) = self.signed(&params.account)?;
        let team = Self::team_of(&api, &params.room).await?;
        let listed: Vec<Listed> = api
            .get(&format!("api/v4/teams/{team}/commands/autocomplete"))
            .await
            .map_err(|e| Failure::new(format!("can't list the commands: {e}")))?;
        let mut commands: Vec<Command> = listed
            .into_iter()
            .filter(|listed| listed.auto_complete)
            .map(|listed| Command {
                trigger: listed.trigger,
                hint: listed.auto_complete_hint,
                description: listed.auto_complete_desc,
            })
            .collect();
        commands.sort_by(|a, b| a.trigger.cmp(&b.trigger));
        Ok(commands)
    }

    /// Presses a post's button, or picks from its menu; what the
    /// integration changes comes as the post changing.
    pub(crate) async fn press(&self, params: &PressParams) -> Result<(), Failure> {
        let (api, _) = self.signed(&params.account)?;
        // The cookie the server wants back is only in the post as it's
        // fetched.
        let post: Post = api
            .get(&format!("api/v4/posts/{}", params.event))
            .await
            .map_err(|e| Failure::new(format!("can't find the message: {e}")))?;
        let cookie = attachment_actions(&post)
            .find(|action| action["id"] == params.action.as_str())
            .and_then(|action| action["cookie"].as_str())
            .unwrap_or_default()
            .to_string();
        let body = json!({ "selected_option": params.option, "cookie": cookie });
        let _: Value = api
            .post(
                &format!("api/v4/posts/{}/actions/{}", params.event, params.action),
                &body,
            )
            .await
            .map_err(|e| Failure::new(format!("the integration didn't take it: {e}")))?;
        Ok(())
    }
}

/// The elements of `value` if it's an array, else none.
fn each(value: &Value) -> impl Iterator<Item = &Value> {
    value.as_array().into_iter().flatten()
}

fn attachments(post: &Post) -> impl Iterator<Item = &Value> {
    each(&post.props["attachments"])
}

fn attachment_actions(post: &Post) -> impl Iterator<Item = &Value> {
    attachments(post).flat_map(|attachment| each(&attachment["actions"]))
}

/// The buttons and menus in `post`.
pub(crate) fn actions(post: &Post) -> Vec<Action> {
    let field = |value: &Value, name: &str| value[name].as_str().unwrap_or_default().to_string();
    attachment_actions(post)
        .filter(|action| action["id"].is_string())
        .map(|action| Action {
            id: field(action, "id"),
            name: field(action, "name"),
            options: each(&action["options"])
                .map(|option| Choice {
                    text: field(option, "text"),
                    value: field(option, "value"),
                })
                .collect(),
        })
        .collect()
}

/// What `post`'s attachments say, as Markdown: each one's lead, title,
/// text and fields.
pub(crate) fn attachments_text(post: &Post) -> String {
    let mut parts: Vec<String> = Vec::new();
    for attachment in attachments(post) {
        let text = |name: &str| {
            attachment[name]
                .as_str()
                .map(str::trim)
                .filter(|text| !text.is_empty())
        };
        parts.extend(text("pretext").map(str::to_string));
        match (text("title"), text("title_link")) {
            (Some(title), Some(link)) => parts.push(format!("**[{title}]({link})**")),
            (Some(title), None) => parts.push(format!("**{title}**")),
            _ => {}
        }
        parts.extend(text("text").map(str::to_string));
        for field in each(&attachment["fields"]) {
            let title = field["title"].as_str().unwrap_or_default();
            let value = match &field["value"] {
                Value::String(value) => value.clone(),
                Value::Null => String::new(),
                other => other.to_string(),
            };
            if !title.is_empty() || !value.is_empty() {
                parts.push(format!("**{title}**: {value}"));
            }
        }
        parts.extend(text("footer").map(|footer| format!("_{footer}_")));
    }
    parts.join("\n\n")
}
