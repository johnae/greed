//! Spaces: the rooms a space holds, joined or not, for browsing and
//! joining them. Which space each of your rooms is in comes with `rooms`.

use greed_chat::protocol::{Listed, RoomParams};
use greed_chat::rpc::Failure;
use greed_chat::why;
use matrix_sdk::RoomState;
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::ruma::room::RoomType;
use matrix_sdk_ui::spaces::room_list::{SpaceRoomList, SpaceRoomListPaginationState};

use crate::Matrix;

/// The most pages of a space's rooms fetched.
const PAGES: usize = 10;

impl Matrix {
    /// The rooms space `params.room` holds, those you're in marked.
    pub(crate) async fn space(&self, params: &RoomParams) -> Result<Vec<Listed>, Failure> {
        let client = self.client_of(&params.account)?;
        let id = OwnedRoomId::try_from(params.room.as_str())
            .map_err(|_| Failure::new(format!("{} isn't a room", params.room)))?;
        let list = SpaceRoomList::new(client, id).await;
        for _ in 0..PAGES {
            list.paginate()
                .await
                .map_err(|e| Failure::new(format!("can't list the space's rooms: {}", why(&e))))?;
            if list.pagination_state() == (SpaceRoomListPaginationState::Idle { end_reached: true })
            {
                break;
            }
        }
        Ok(list
            .rooms()
            .await
            .into_iter()
            .map(|room| Listed {
                id: room.room_id.to_string(),
                name: room.display_name,
                topic: room.topic,
                members: Some(room.num_joined_members),
                address: room.canonical_alias.map(|alias| alias.to_string()),
                joined: room.state == Some(RoomState::Joined),
                space: room.room_type == Some(RoomType::Space),
                via: room.via.iter().map(ToString::to_string).collect(),
            })
            .collect())
    }
}
