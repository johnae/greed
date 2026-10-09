/// Someone with an account.
#[derive(Debug, Clone, PartialEq)]
pub struct Usr {
    pub name: String,
    pub email: String,
}

impl Usr {
    pub fn new(name: &str, email: &str) -> Usr {
        Usr { name: name.to_string(), email: email.to_string() }
    }
}
