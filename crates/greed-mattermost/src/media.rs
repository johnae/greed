//! Files posts carry, fetched to where they can be opened, and sending
//! your own.

use std::path::Path;

use greed_chat::protocol::{MediaParams, Preview, UploadParams};
use greed_chat::rpc::Failure;
use greed_chat::safe_file_name;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::Post;

impl Mattermost {
    /// Fetches a post's file, or its small picture, into the data folder:
    /// `{path}`.
    pub(crate) async fn media_get(&self, params: &MediaParams) -> Result<Value, Failure> {
        let (api, _) = self.signed(&params.account)?;
        let post: Post = api
            .get(&format!("api/v4/posts/{}", params.event))
            .await
            .map_err(|e| Failure::new(format!("can't fetch it: {e}")))?;
        let file = post
            .metadata
            .files
            .first()
            .ok_or_else(|| Failure::new("that message carries no file"))?;
        let path = if params.thumbnail {
            format!("api/v4/files/{}/thumbnail", file.id)
        } else {
            format!("api/v4/files/{}", file.id)
        };
        let bytes = api
            .bytes(&path)
            .await
            .map_err(|e| Failure::new(format!("can't fetch it: {e}")))?;
        let folder = self.data.join("media");
        std::fs::create_dir_all(&folder).map_err(|e| Failure::new(e.to_string()))?;
        let small = if params.thumbnail { "small-" } else { "" };
        let kept = folder.join(format!("{small}{}-{}", file.id, safe_file_name(&file.name)));
        std::fs::write(&kept, bytes).map_err(|e| Failure::new(format!("can't keep it: {e}")))?;
        Ok(json!({ "path": kept }))
    }

    /// Sends the file at `params.path` to the channel, or into a thread.
    pub(crate) async fn upload(&self, params: &UploadParams) -> Result<(), Failure> {
        let (api, _) = self.signed(&params.account)?;
        let path = Path::new(&params.path);
        let bytes = std::fs::read(path)
            .map_err(|e| Failure::new(format!("can't read {}: {e}", params.path)))?;
        let name = path
            .file_name()
            .map_or_else(|| "file".into(), |n| n.to_string_lossy().into_owned());
        let mime = mime_guess::from_path(path).first_or_octet_stream();
        let id = api
            .upload(&params.room, &name, mime.as_ref(), bytes)
            .await
            .map_err(|e| Failure::new(format!("can't send it: {e}")))?;
        let body = json!({
            "channel_id": params.room,
            "message": "",
            "root_id": params.thread.clone().unwrap_or_default(),
            "file_ids": [id],
        });
        let post: Post = api
            .post("api/v4/posts", &body)
            .await
            .map_err(|e| Failure::new(format!("can't send it: {e}")))?;
        self.posted(&params.account, &post).await;
        Ok(())
    }
}

/// The preview of the first link in `post`, from the page the server read
/// (where it has link previews on).
pub(crate) fn preview(post: &Post) -> Option<Preview> {
    post.metadata
        .embeds
        .iter()
        .filter(|embed| embed["type"] == "opengraph")
        .find_map(|embed| {
            Preview::from_page(
                embed["url"].as_str().unwrap_or_default(),
                &embed["data"],
                ["title", "description", "site_name"],
            )
        })
}
