//! An account's teams and channels as the client lists them, and the
//! people they name.

use std::collections::{HashMap, HashSet};

use greed_chat::protocol::{Room, RoomKind};
use greed_chat::rpc::Failure;

use crate::Mattermost;
use crate::api::{Api, Channel, Member, Team, User};

impl Mattermost {
    /// The api and user id of account `id`.
    pub(crate) fn signed(&self, id: &str) -> Result<(Api, String), Failure> {
        self.accounts
            .borrow()
            .get(id)
            .map(|signed| (signed.api.clone(), signed.user.id.clone()))
            .ok_or_else(|| Failure::new(format!("no account {id}")))
    }

    /// Account `id`'s teams, as spaces, and their channels.
    pub(crate) async fn rooms(&self, id: &str) -> Result<Vec<Room>, Failure> {
        let (api, me) = self.signed(id)?;
        let failed = |e: crate::api::Error| Failure::new(format!("can't list channels: {e}"));
        let teams: Vec<Team> = api.get("api/v4/users/me/teams").await.map_err(failed)?;
        let mut rooms = Vec::new();
        let mut seen = HashSet::new();
        for team in &teams {
            rooms.push(Room {
                id: team.id.clone(),
                account: id.to_string(),
                name: team.display_name.clone(),
                kind: RoomKind::Space,
                ..Room::default()
            });
            let channels: Vec<Channel> = api
                .get(&format!("api/v4/users/me/teams/{}/channels", team.id))
                .await
                .map_err(failed)?;
            let members: Vec<Member> = api
                .get(&format!(
                    "api/v4/users/me/teams/{}/channels/members",
                    team.id
                ))
                .await
                .map_err(failed)?;
            let members: HashMap<&str, &Member> = members
                .iter()
                .map(|member| (member.channel_id.as_str(), member))
                .collect();
            // Direct and group channels belong to no team, and come with
            // every team's.
            let others: Vec<String> = channels
                .iter()
                .filter(|channel| channel.kind == "D")
                .filter_map(|channel| other_in(channel, &me))
                .collect();
            self.people(id, &api, &others).await;
            for channel in channels {
                if !seen.insert(channel.id.clone()) {
                    continue;
                }
                let member = members.get(channel.id.as_str()).copied();
                rooms.push(self.room_of(id, &me, &channel, member));
            }
        }
        Ok(rooms)
    }

    fn room_of(&self, account: &str, me: &str, channel: &Channel, member: Option<&Member>) -> Room {
        let kind = match channel.kind.as_str() {
            "D" => RoomKind::Direct,
            "G" => RoomKind::Group,
            _ => RoomKind::Room,
        };
        let name = match other_in(channel, me) {
            Some(other) if kind == RoomKind::Direct => self.name_of(account, &other),
            _ => channel.display_name.clone(),
        };
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
            ..Room::default()
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

    /// The name account `id` shows for user `user`.
    pub(crate) fn name_of(&self, id: &str, user: &str) -> String {
        self.people
            .borrow()
            .get(&format!("{id} {user}"))
            .map_or_else(|| user.to_string(), User::name)
    }
}

/// The other person in a direct channel, whose name is both users' ids.
fn other_in(channel: &Channel, me: &str) -> Option<String> {
    let (a, b) = channel.name.split_once("__")?;
    Some(if a == me { b } else { a }.to_string())
}
