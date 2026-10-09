use crate::usr::Usr;

/// Accounts, kept in memory.
#[derive(Default)]
pub struct Store {
    usrs: Vec<Usr>,
}

impl Store {
    pub fn add(&mut self, usr: Usr) {
        self.usrs.push(usr);
    }

    pub fn find(&self, name: &str) -> Option<&Usr> {
        self.usrs.iter().find(|u| u.name == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_by_name() {
        let mut store = Store::default();
        store.add(Usr::new("ada", "ada@example.com"));
        assert_eq!(store.find("ada").map(|u| u.email.as_str()), Some("ada@example.com"));
    }
}
