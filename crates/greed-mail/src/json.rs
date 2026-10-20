//! Reading what the editor sends: Luau has one kind of table, so an empty
//! list comes as `{}`.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// A list, for `#[serde(deserialize_with = "list")]`: an empty object is
/// an empty list.
pub fn list<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    match Value::deserialize(deserializer)? {
        Value::Object(empty) if empty.is_empty() => Ok(Vec::new()),
        value => serde_json::from_value(value).map_err(serde::de::Error::custom),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    struct Holding {
        #[serde(deserialize_with = "list")]
        items: Vec<String>,
    }

    fn items(json: &str) -> Result<Vec<String>, serde_json::Error> {
        serde_json::from_str::<Holding>(json).map(|h| h.items)
    }

    #[test]
    fn an_empty_table_is_an_empty_list_however_its_written() {
        assert_eq!(items(r#"{"items": {}}"#).unwrap(), Vec::<String>::new());
        assert_eq!(items(r#"{"items": []}"#).unwrap(), Vec::<String>::new());
        assert_eq!(items(r#"{"items": ["a"]}"#).unwrap(), ["a"]);
        assert!(items(r#"{"items": {"a": 1}}"#).is_err(), "a real map isn't");
    }
}
