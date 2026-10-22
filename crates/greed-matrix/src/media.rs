//! Files messages carry: what they are, fetched (and decrypted, in an
//! encrypted room) to where they can be opened, and sending your own.

use std::path::PathBuf;

use greed_chat::protocol::{Media, MediaParams, RoomParams, UploadParams};
use greed_chat::rpc::Failure;
use greed_chat::safe_file_name;
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::ruma::events::room::MediaSource;
use matrix_sdk::ruma::events::room::message::MessageType;
use matrix_sdk::ruma::{EventId, UInt};
use matrix_sdk_ui::timeline::{AttachmentConfig, MsgLikeKind, TimelineItemContent};
use serde_json::{Value, json};

use crate::Matrix;

/// How big a picture's thumbnail is asked for, in pixels.
const THUMBNAIL: u32 = 480;

/// What `msgtype` carries, if it's a file of some kind.
pub(crate) fn media_of(msgtype: &MessageType) -> Option<Media> {
    let number = |n: Option<UInt>| n.map(u64::from);
    let named = |filename: &Option<String>, body: &str| {
        filename.clone().unwrap_or_else(|| body.to_string())
    };
    let media = match msgtype {
        MessageType::Image(c) => {
            let info = c.info.as_deref();
            Media {
                name: named(&c.filename, &c.body),
                mime: info.and_then(|i| i.mimetype.clone()).unwrap_or_default(),
                size: number(info.and_then(|i| i.size)),
                width: number(info.and_then(|i| i.width)),
                height: number(info.and_then(|i| i.height)),
                // A picture is its own small picture when it has none.
                thumbnail: true,
            }
        }
        MessageType::Video(c) => {
            let info = c.info.as_deref();
            Media {
                name: named(&c.filename, &c.body),
                mime: info.and_then(|i| i.mimetype.clone()).unwrap_or_default(),
                size: number(info.and_then(|i| i.size)),
                width: number(info.and_then(|i| i.width)),
                height: number(info.and_then(|i| i.height)),
                thumbnail: info.is_some_and(|i| i.thumbnail_source.is_some()),
            }
        }
        MessageType::Audio(c) => {
            let info = c.info.as_deref();
            Media {
                name: named(&c.filename, &c.body),
                mime: info.and_then(|i| i.mimetype.clone()).unwrap_or_default(),
                size: number(info.and_then(|i| i.size)),
                ..Media::default()
            }
        }
        MessageType::File(c) => {
            let info = c.info.as_deref();
            Media {
                name: named(&c.filename, &c.body),
                mime: info.and_then(|i| i.mimetype.clone()).unwrap_or_default(),
                size: number(info.and_then(|i| i.size)),
                thumbnail: info.is_some_and(|i| i.thumbnail_source.is_some()),
                ..Media::default()
            }
        }
        _ => return None,
    };
    Some(media)
}

/// Where `msgtype`'s file is, and its own small picture if it has one.
fn sources(msgtype: &MessageType) -> Option<(MediaSource, Option<MediaSource>)> {
    match msgtype {
        MessageType::Image(c) => Some((
            c.source.clone(),
            c.info.as_ref().and_then(|i| i.thumbnail_source.clone()),
        )),
        MessageType::Video(c) => Some((
            c.source.clone(),
            c.info.as_ref().and_then(|i| i.thumbnail_source.clone()),
        )),
        MessageType::Audio(c) => Some((c.source.clone(), None)),
        MessageType::File(c) => Some((
            c.source.clone(),
            c.info.as_ref().and_then(|i| i.thumbnail_source.clone()),
        )),
        _ => None,
    }
}

impl Matrix {
    /// Fetches a message's file, or a small picture of it, into the
    /// account's store: `{path}`.
    pub(crate) async fn media_get(&self, params: &MediaParams) -> Result<Value, Failure> {
        let room = RoomParams {
            account: params.account.clone(),
            room: params.room.clone(),
            thread: None,
            on: false,
        };
        let timeline = self.timeline(&room).await?;
        let event = EventId::parse(&params.event).map_err(Failure::params)?;
        let item = timeline
            .item_by_event_id(&event)
            .await
            .ok_or_else(|| Failure::new("that message isn't in the room's timeline"))?;
        let no_file = || Failure::new("that message carries no file");
        let TimelineItemContent::MsgLike(like) = item.content() else {
            return Err(no_file());
        };
        let MsgLikeKind::Message(message) = &like.kind else {
            return Err(no_file());
        };
        let msgtype = message.msgtype();
        let (source, thumbnail) = sources(msgtype).ok_or_else(no_file)?;
        let name = media_of(msgtype).map(|m| m.name).unwrap_or_default();
        let request = match (params.thumbnail, thumbnail) {
            (false, _) => MediaRequestParameters {
                source,
                format: MediaFormat::File,
            },
            (true, Some(small)) => MediaRequestParameters {
                source: small,
                format: MediaFormat::File,
            },
            // The server makes one.
            (true, None) => MediaRequestParameters {
                source,
                format: MediaFormat::Thumbnail(MediaThumbnailSettings::new(
                    THUMBNAIL.into(),
                    THUMBNAIL.into(),
                )),
            },
        };
        let (client, store) = self
            .accounts
            .borrow()
            .get(&params.account)
            .map(|signed| (signed.client.clone(), signed.store.name.clone()))
            .ok_or_else(|| Failure::new(format!("no account {}", params.account)))?;
        let bytes = client
            .media()
            .get_media_content(&request, true)
            .await
            .map_err(|e| Failure::new(format!("can't fetch it: {e}")))?;
        let folder = self.data.join(store).join("media");
        std::fs::create_dir_all(&folder).map_err(|e| Failure::new(e.to_string()))?;
        let small = if params.thumbnail { "small-" } else { "" };
        let path = folder.join(format!(
            "{small}{}-{}",
            safe_file_name(event.as_str()),
            safe_file_name(&name)
        ));
        std::fs::write(&path, bytes).map_err(|e| Failure::new(format!("can't keep it: {e}")))?;
        Ok(json!({ "path": path }))
    }

    /// Sends the file at `params.path` to the room, or into a thread.
    pub(crate) async fn upload(&self, params: &UploadParams) -> Result<(), Failure> {
        let room = RoomParams {
            account: params.account.clone(),
            room: params.room.clone(),
            thread: params.thread.clone(),
            on: false,
        };
        let timeline = self.timeline(&room).await?;
        let path = PathBuf::from(&params.path);
        if !path.is_file() {
            return Err(Failure::new(format!("there's no file {}", params.path)));
        }
        let mime = mime_guess::from_path(&path).first_or_octet_stream();
        timeline
            .send_attachment(path, mime, AttachmentConfig::default())
            .await
            .map_err(|e| Failure::new(format!("can't send it: {e}")))
    }
}
