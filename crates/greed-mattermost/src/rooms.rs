//! An account's teams and channels as the client lists them, and the
//! people they name.

use std::collections::{HashMap, HashSet};

use greed_chat::protocol::{DirectoryParams, JoinParams, Listed, Room, RoomKind, RoomParams};
use greed_chat::rpc::Failure;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::{Api, Channel, Member, Team, User};

/// How many channel memberships come a page.
const MEMBERS: usize = 200;

impl Mattermost {
    /// The api and user id of account `id`.
    pub(crate) fn signed(&self, id: &str) -> Result<(Api, String), Failure> {
        self.accounts
            .borrow()
            .get(id)
            .map(|signed| (signed.api.clone(), signed.user.id.clone()))
            .ok_or_else(|| Failure::new(format!("no account {id}")))
    }

    /// Account `id`'s teams, as spaces, and all its channels, direct
    /// messages too.
    pub(crate) async fn rooms(&self, id: &str) -> Result<Vec<Room>, Failure> {
        let (api, me) = self.signed(id)?;
        let failed = |e: crate::api::Error| Failure::new(format!("can't list channels: {e}"));
        let teams: Vec<Team> = api.get("api/v4/users/me/teams").await.map_err(failed)?;
        let channels: Vec<Channel> = api
            .get(&format!("api/v4/users/{me}/channels"))
            .await
            .map_err(failed)?;
        let mut members: Vec<Member> = Vec::new();
        for page in 0.. {
            let more: Vec<Member> = api
                .get(&format!(
                    "api/v4/users/{me}/channel_members?page={page}&per_page={MEMBERS}"
                ))
                .await
                .map_err(failed)?;
            let last = more.len() < MEMBERS;
            members.extend(more);
            if last {
                break;
            }
        }
        let members: HashMap<&str, &Member> = members
            .iter()
            .map(|member| (member.channel_id.as_str(), member))
            .collect();
        let others: Vec<String> = channels
            .iter()
            .filter(|channel| channel.kind == "D")
            .filter_map(|channel| other_in(channel, &me))
            .collect();
        self.people(id, &api, &others).await;
        let statuses = statuses(&api, &others).await;
        let mut rooms: Vec<Room> = teams
            .iter()
            .map(|team| Room {
                id: team.id.clone(),
                account: id.to_string(),
                name: team.display_name.clone(),
                kind: RoomKind::Space,
                ..Room::default()
            })
            .collect();
        for channel in &channels {
            let member = members.get(channel.id.as_str()).copied();
            rooms.push(self.room_of(id, &me, channel, member, &statuses));
        }
        Ok(rooms)
    }

    fn room_of(
        &self,
        account: &str,
        me: &str,
        channel: &Channel,
        member: Option<&Member>,
        statuses: &HashMap<String, String>,
    ) -> Room {
        let kind = match channel.kind.as_str() {
            "D" => RoomKind::Direct,
            "G" => RoomKind::Group,
            _ => RoomKind::Room,
        };
        let name = self.channel_name(account, me, channel);
        let read = member.map_or(channel.total_msg_count, |member| member.msg_count);
        Room {
            id: channel.id.clone(),
            account: account.to_string(),
            name,
            kind,
            topic: Some(channel.header.clone()).filter(|header| !header.is_empty()),
            parent: Some(channel.team_id.clone()).filter(|team| !team.is_empty()),
            unread: channel.total_msg_count.saturating_sub(read),
            mentions: member.map_or(0, |member| member.mention_count),
            muted: member.is_some_and(|member| member.notify_props["mark_unread"] == "mention"),
            active: Some(channel.last_post_at).filter(|at| *at > 0),
            presence: other_in(channel, me)
                .filter(|_| kind == RoomKind::Direct)
                .and_then(|other| statuses.get(&other).cloned()),
            ..Room::default()
        }
    }

    /// What account `account` calls `channel`: in a direct message, the
    /// other person's name.
    pub(crate) fn channel_name(&self, account: &str, me: &str, channel: &Channel) -> String {
        match other_in(channel, me) {
            Some(other) if channel.kind == "D" => self.name_of(account, &other),
            _ => channel.display_name.clone(),
        }
    }

    /// Fetches the users among `ids` that account `id` doesn't know yet.
    pub(crate) async fn people(&self, id: &str, api: &Api, ids: &[String]) {
        let missing: Vec<&String> = {
            let people = self.people.borrow();
            ids.iter()
                .filter(|user| !people.contains_key(&format!("{id} {user}")))
                .collect::<HashSet<_>>()
                .into_iter()
                .collect()
        };
        if missing.is_empty() {
            return;
        }
        let Ok(users) = api
            .post::<Vec<User>>("api/v4/users/ids", &serde_json::json!(missing))
            .await
        else {
            return;
        };
        let mut people = self.people.borrow_mut();
        for user in users {
            people.insert(format!("{id} {}", user.id), user);
        }
    }

    /// Joins a channel by its id: `{room}`.
    pub(crate) async fn join(&self, params: &JoinParams) -> Result<Value, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let room = params.room.trim();
        let _: Value = api
            .post(
                &format!("api/v4/channels/{room}/members"),
                &json!({ "user_id": me }),
            )
            .await
            .map_err(|e| Failure::new(format!("can't join it: {e}")))?;
        Ok(json!({ "room": room }))
    }

    /// Leaves a channel.
    pub(crate) async fn leave(&self, params: &RoomParams) -> Result<(), Failure> {
        let (api, me) = self.signed(&params.account)?;
        api.delete(&format!("api/v4/channels/{}/members/{me}", params.room))
            .await
            .map_err(|e| Failure::new(format!("can't leave it: {e}")))
    }

    /// The public channels of your teams whose names or purposes have
    /// `params.query`, but those you're in.
    pub(crate) async fn directory(&self, params: &DirectoryParams) -> Result<Vec<Listed>, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let teams: Vec<Team> = api
            .get("api/v4/users/me/teams")
            .await
            .map_err(|e| Failure::new(format!("can't list channels: {e}")))?;
        let query = params.query.trim().to_lowercase();
        let mut listed = Vec::new();
        for team in teams {
            for channel in team_channels(&api, &me, &team).await? {
                let wanted = query.is_empty()
                    || channel.name.to_lowercase().contains(&query)
                    || channel
                        .topic
                        .as_ref()
                        .is_some_and(|topic| topic.to_lowercase().contains(&query));
                if wanted && !channel.joined {
                    listed.push(channel);
                }
            }
        }
        Ok(listed)
    }

    /// The public channels of team `params.room`, those you're in marked.
    pub(crate) async fn space(&self, params: &RoomParams) -> Result<Vec<Listed>, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let team: Team = api
            .get(&format!("api/v4/teams/{}", params.room))
            .await
            .map_err(|e| Failure::new(format!("can't find the team: {e}")))?;
        team_channels(&api, &me, &team).await
    }

    /// The name account `id` shows for user `user`.
    pub(crate) fn name_of(&self, id: &str, user: &str) -> String {
        self.people
            .borrow()
            .get(&format!("{id} {user}"))
            .map_or_else(|| user.to_string(), User::name)
    }
}

/// The other person in a direct channel, whose name is both users' ids.
pub(crate) fn other_in(channel: &Channel, me: &str) -> Option<String> {
    let (a, b) = channel.name.split_once("__")?;
    Some(if a == me { b } else { a }.to_string())
}

/// Whether each of `users` is online, away, dnd or offline, by id; empty
/// when the server won't say.
async fn statuses(api: &Api, users: &[String]) -> HashMap<String, String> {
    #[derive(serde::Deserialize)]
    struct Status {
        user_id: String,
        status: String,
    }
    if users.is_empty() {
        return HashMap::new();
    }
    let said: Vec<Status> = api
        .post("api/v4/users/status/ids", &serde_json::json!(users))
        .await
        .unwrap_or_default();
    said.into_iter()
        .map(|status| (status.user_id, status.status))
        .collect()
}

/// Team `team`'s public channels, marked where `me` is in them.
async fn team_channels(api: &Api, me: &str, team: &Team) -> Result<Vec<Listed>, Failure> {
    let failed = |e: crate::api::Error| Failure::new(format!("can't list channels: {e}"));
    let mine: HashSet<String> = api
        .get::<Vec<Channel>>(&format!("api/v4/users/{me}/teams/{}/channels", team.id))
        .await
        .map_err(failed)?
        .into_iter()
        .map(|channel| channel.id)
        .collect();
    let channels: Vec<Value> = api
        .get(&format!(
            "api/v4/teams/{}/channels?page=0&per_page={MEMBERS}",
            team.id
        ))
        .await
        .map_err(failed)?;
    Ok(channels
        .iter()
        .map(|channel| {
            let field = |name: &str| channel[name].as_str().unwrap_or_default().to_string();
            let (id, purpose) = (field("id"), field("purpose"));
            Listed {
                joined: mine.contains(&id),
                id,
                name: field("display_name"),
                topic: Some(purpose).filter(|purpose| !purpose.is_empty()),
                members: None,
                address: Some(team.display_name.clone()),
                ..Listed::default()
            }
        })
        .collect())
}
